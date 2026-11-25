// TXLocalhostProxy - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXLocalhostProxy.h"
#import "TXLog.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

// The guest bridge's well-known vsock port (see
// rootfs-build/tx-vsock-bridge.c). One listener handles every
// forwarded port: the proxy sends the target TCP port in the first
// two bytes of each vsock stream.
#define TX_LOCALHOST_BRIDGE_VSOCK_PORT 5999

// How long a vsock connect may take, and how often to retry when the
// bridge is not listening yet (it starts with the guest via systemd,
// so the first connection after boot can race it). Three attempts
// half a second apart is enough for the bridge to come up without
// making a refused connection wait noticeably.
#define TX_LOCALHOST_VSOCK_TIMEOUT_MS 2000
#define TX_LOCALHOST_VSOCK_RETRIES 3
#define TX_LOCALHOST_VSOCK_RETRY_DELAY_MS 500

// How often the proxy asks the bridge for the guest's listening
// ports (the auto-mirror). One second is fast enough that a newly
// started agent is reachable almost at once, and the poll is a
// single short vsock stream, so it costs nothing measurable.
#define TX_LOCALHOST_POLL_INTERVAL_SEC 1.0

// The ports forwarded when the user has not configured any. The
// common localhost haunts: dev servers (3000, 5000, 8000, 8080),
// Jupyter (8888), T3 Code pairing (3773), OpenCode (4096). The
// user adds any other port from the About screen.
#define TX_LOCALHOST_DEFAULT_PORTS 3000, 3773, 4096, 5000, 8000, 8080, 8888

static NSString * const kTXLocalhostPortsDefaultsKey = @"termx.localhostPorts";

@interface TXLocalhostProxy () {
    dispatch_queue_t _queue;
    const kernarium_runtime_api *_api;
    // One listener per port: the fd and its accept dispatch source.
    NSMutableDictionary<NSNumber *, NSNumber *> *_listenFDs;
    NSMutableDictionary<NSNumber *, dispatch_source_t> *_acceptSources;
    // The guest's listening ports as last polled (the auto-mirror).
    NSSet<NSNumber *> *_autoPorts;
    // The 1 s poll timer, live only while the proxy runs.
    dispatch_source_t _pollTimer;
    BOOL _running;
}
@end

@implementation TXLocalhostProxy

+ (NSArray<NSNumber *> *)configuredPorts {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kTXLocalhostPortsDefaultsKey];
    if (saved.count == 0) {
        static const uint16_t defaults[] = { TX_LOCALHOST_DEFAULT_PORTS };
        NSMutableArray<NSNumber *> *ports = [NSMutableArray array];
        for (size_t i = 0; i < sizeof(defaults) / sizeof(defaults[0]); i++) {
            [ports addObject:@(defaults[i])];
        }
        return [ports copy];
    }
    // Sorted, unique, in range; anything else is dropped.
    NSMutableOrderedSet<NSNumber *> *ports = [NSMutableOrderedSet orderedSet];
    for (id value in saved) {
        long port = [value longValue];
        if (port >= 1 && port <= 65535) [ports addObject:@(port)];
    }
    return [[ports array] sortedArrayUsingSelector:@selector(compare:)];
}

+ (void)setConfiguredPorts:(NSArray<NSNumber *> *)ports {
    NSMutableOrderedSet<NSNumber *> *clean = [NSMutableOrderedSet orderedSet];
    for (NSNumber *port in ports) {
        long p = [port longValue];
        if (p >= 1 && p <= 65535) [clean addObject:@(p)];
    }
    NSArray *sorted = [[clean array] sortedArrayUsingSelector:@selector(compare:)];
    [[NSUserDefaults standardUserDefaults] setObject:sorted forKey:kTXLocalhostPortsDefaultsKey];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("app.termx.ios.localhost-proxy", DISPATCH_QUEUE_SERIAL);
        _listenFDs = [NSMutableDictionary dictionary];
        _acceptSources = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)running {
    __block BOOL running = NO;
    dispatch_sync(_queue, ^{ running = _running; });
    return running;
}

- (NSArray<NSNumber *> *)ports {
    __block NSArray<NSNumber *> *ports = @[];
    dispatch_sync(_queue, ^{
        ports = [[_listenFDs allKeys] sortedArrayUsingSelector:@selector(compare:)];
    });
    return ports;
}

- (NSArray<NSNumber *> *)autoPorts {
    __block NSArray<NSNumber *> *ports = @[];
    dispatch_sync(_queue, ^{
        ports = [[_autoPorts allObjects] sortedArrayUsingSelector:@selector(compare:)];
    });
    return ports;
}

- (void)startWithAPI:(const kernarium_runtime_api *)api {
    if (!api || !api->connect_vsock) {
        TXLogEngine(@"Localhost proxy: no runtime vsock API, not starting");
        return;
    }
    NSArray<NSNumber *> *ports = [TXLocalhostProxy configuredPorts];
    dispatch_async(_queue, ^{
        [self stopLocked];
        _api = api;
        _autoPorts = [NSSet set];
        for (NSNumber *port in ports) {
            [self startListenerLocked:[port intValue]];
        }
        _running = YES;
        TXLogEngine(@"Localhost proxy: listening on 127.0.0.1 for ports %@",
                    [ports componentsJoinedByString:@", "]);
        [self startPollLocked];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        [self stopLocked];
        TXLogEngine(@"Localhost proxy: stopped");
    });
}

// --- listeners (called on _queue) ---

- (void)startListenerLocked:(int)port {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        TXLogEngine(@"Localhost proxy: socket for port %d failed: %s", port, strerror(errno));
        return;
    }
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        TXLogEngine(@"Localhost proxy: bind 127.0.0.1:%d failed: %s", port, strerror(errno));
        close(fd);
        return;
    }
    if (listen(fd, 64) != 0) {
        TXLogEngine(@"Localhost proxy: listen 127.0.0.1:%d failed: %s", port, strerror(errno));
        close(fd);
        return;
    }
    // Non-blocking accept: the dispatch source fires when a
    // connection is waiting, and accept never blocks the queue.
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    _listenFDs[@(port)] = @(fd);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                                      (uintptr_t)fd, 0, _queue);
    __weak TXLocalhostProxy *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        [weakSelf acceptLocked:port];
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(fd);
    });
    dispatch_resume(source);
    _acceptSources[@(port)] = source;
}

- (void)acceptLocked:(int)port {
    NSNumber *key = @(port);
    NSNumber *fdNumber = _listenFDs[key];
    if (!fdNumber) return;
    int listenFD = [fdNumber intValue];
    for (;;) {
        int conn = accept(listenFD, NULL, NULL);
        if (conn < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            if (errno == EINTR) continue;
            TXLogEngine(@"Localhost proxy: accept on %d failed: %s", port, strerror(errno));
            return;
        }
        // Hand the connection to a background queue: the vsock
        // connect can block, and the shuttle runs until the
        // connection closes.
        const kernarium_runtime_api *api = _api;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self handleConnection:conn forPort:port api:api];
        });
    }
}

- (void)stopLocked {
    if (_pollTimer) {
        dispatch_source_cancel(_pollTimer);
        _pollTimer = nil;
    }
    for (dispatch_source_t source in _acceptSources.allValues) {
        dispatch_source_cancel(source);
    }
    [_acceptSources removeAllObjects];
    [_listenFDs removeAllObjects];
    _autoPorts = [NSSet set];
    _api = NULL;
    _running = NO;
}

// Close one listener: cancel its accept source (which closes the
// fd in its cancel handler) and drop it from the tables.
- (void)stopListenerLocked:(int)port {
    NSNumber *key = @(port);
    dispatch_source_t source = _acceptSources[key];
    if (source) {
        dispatch_source_cancel(source);
        [_acceptSources removeObjectForKey:key];
    }
    [_listenFDs removeObjectForKey:key];
}

// --- auto-mirror poll (called on _queue) ---

// Start the 1 s poll: each tick asks the bridge for the guest's
// listening ports and reconciles the listeners. The fetch runs on
// a background queue (the vsock connect can block); the reconcile
// runs back on _queue.
- (void)startPollLocked {
    if (_pollTimer) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0, 0, _queue);
    if (!timer) return;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(TX_LOCALHOST_POLL_INTERVAL_SEC * NSEC_PER_SEC)),
                              (uint64_t)(TX_LOCALHOST_POLL_INTERVAL_SEC * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak TXLocalhostProxy *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf pollTick];
    });
    dispatch_resume(timer);
    _pollTimer = timer;
}

- (void)pollTick {
    // Runs on _queue. Capture the api; the fetch is blocking, so
    // it goes to a background queue, and the result comes back here.
    const kernarium_runtime_api *api = _api;
    if (!api || !api->connect_vsock || !_running) return;
    __weak TXLocalhostProxy *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        TXLocalhostProxy *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSArray<NSNumber *> *guestPorts = [strongSelf fetchGuestPortsWithAPI:api];
        if (!guestPorts) return; // Bridge not answering yet; retry next tick.
        dispatch_async(strongSelf->_queue, ^{
            [strongSelf reconcileWithGuestPorts:guestPorts];
        });
    });
}

// Ask the bridge for the guest's listening ports (a port-0 control
// request). Returns the sorted port list, or nil when the bridge
// does not answer (guest still booting, bridge not up yet, or an
// older image without the list request). Blocking; call off _queue.
- (NSArray<NSNumber *> *)fetchGuestPortsWithAPI:(const kernarium_runtime_api *)api {
    int vsockFD = -1;
    for (int attempt = 0; attempt < TX_LOCALHOST_VSOCK_RETRIES; attempt++) {
        vsockFD = api->connect_vsock(TX_LOCALHOST_BRIDGE_VSOCK_PORT,
                                     TX_LOCALHOST_VSOCK_TIMEOUT_MS);
        if (vsockFD >= 0) break;
        if (vsockFD == -ECONNREFUSED && attempt + 1 < TX_LOCALHOST_VSOCK_RETRIES) {
            struct timespec ts = {0, TX_LOCALHOST_VSOCK_RETRY_DELAY_MS * 1000 * 1000};
            nanosleep(&ts, NULL);
            continue;
        }
        break;
    }
    if (vsockFD < 0) return nil;
    // Port 0, big-endian, then read the reply: 2-byte count, then
    // 2 bytes per port, all big-endian.
    unsigned char req[2] = {0, 0};
    if (!TXWriteAll(vsockFD, req, sizeof(req))) {
        close(vsockFD);
        return nil;
    }
    unsigned char hdr[2];
    if (!TXReadExact(vsockFD, hdr, sizeof(hdr))) {
        close(vsockFD);
        return nil;
    }
    uint16_t count = (uint16_t)((hdr[0] << 8) | hdr[1]);
    NSMutableArray<NSNumber *> *ports = [NSMutableArray arrayWithCapacity:count];
    for (uint16_t i = 0; i < count; i++) {
        unsigned char pb[2];
        if (!TXReadExact(vsockFD, pb, sizeof(pb))) {
            close(vsockFD);
            return nil;
        }
        uint16_t port = (uint16_t)((pb[0] << 8) | pb[1]);
        if (port >= 1) [ports addObject:@(port)];
    }
    close(vsockFD);
    return [ports sortedArrayUsingSelector:@selector(compare:)];
}

// Reconcile the listeners with the guest's current listening ports
// (on _queue). The forwarded set is the configured ports plus the
// guest's ports: start a listener for each new port, close the
// listener for each port that is neither configured nor listening
// in the guest any more. A configured port is never closed by a
// poll, even when nothing listens on it in the guest yet.
- (void)reconcileWithGuestPorts:(NSArray<NSNumber *> *)guestPorts {
    if (!_running) return;
    NSSet<NSNumber *> *guestSet = [NSSet setWithArray:guestPorts];
    if ([guestSet isEqualToSet:_autoPorts]) return;
    _autoPorts = guestSet;
    NSMutableSet<NSNumber *> *wanted = [NSMutableSet setWithArray:[TXLocalhostProxy configuredPorts]];
    [wanted unionSet:guestSet];
    for (NSNumber *port in wanted) {
        if (!_listenFDs[port]) {
            [self startListenerLocked:[port intValue]];
        }
    }
    for (NSNumber *port in [_listenFDs allKeys]) {
        if (![wanted containsObject:port]) {
            [self stopListenerLocked:[port intValue]];
        }
    }
}

// --- one proxied connection (background queue) ---

// Write all bytes, retrying on EINTR and partial writes.
static BOOL TXWriteAll(int fd, const void *buf, size_t len) {
    const unsigned char *p = buf;
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        p += (size_t)w;
        len -= (size_t)w;
    }
    return YES;
}

// Read exactly len bytes, retrying on EINTR. NO on EOF or error.
static BOOL TXReadExact(int fd, void *buf, size_t len) {
    unsigned char *p = buf;
    while (len > 0) {
        ssize_t r = read(fd, p, len);
        if (r < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (r == 0) return NO;
        p += (size_t)r;
        len -= (size_t)r;
    }
    return YES;
}

// Close a stream cleanly: discard whatever the peer already sent
// (a browser sends its request the moment it connects, and it may
// still be in flight when the vsock side fails), so the close
// sends FIN instead of RST. A close with unread received data
// sends RST, which the browser reports as "connection reset".
static void TXCloseCleanly(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    char buf[4096];
    for (int round = 0; round < 3; round++) {
        for (;;) {
            ssize_t r = read(fd, buf, sizeof(buf));
            if (r <= 0) break;
        }
        struct timespec ts = {0, 5 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
    close(fd);
}

// Shuttle bytes between two fds until both sides are done. A half
// close on one side shuts the write side of the other, so a service
// that closes after its reply still lets the reply through. Mirrors
// the bridge's shuttle (rootfs-build/tx-vsock-bridge.c).
static void TXShuttle(int a, int b) {
    char buf[16384];
    struct pollfd pfd[2];
    BOOL aOpen = YES, bOpen = YES;
    pfd[0].fd = a;
    pfd[1].fd = b;
    while (aOpen || bOpen) {
        pfd[0].events = aOpen ? POLLIN : 0;
        pfd[1].events = bOpen ? POLLIN : 0;
        if (!aOpen && !bOpen) break;
        int n = poll(pfd, 2, -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if ((pfd[0].revents & (POLLIN | POLLHUP | POLLERR)) && aOpen) {
            ssize_t r = read(a, buf, sizeof(buf));
            if (r > 0) {
                ssize_t off = 0;
                while (off < r) {
                    ssize_t w = write(b, buf + off, (size_t)(r - off));
                    if (w < 0) {
                        if (errno == EINTR) continue;
                        break;
                    }
                    off += w;
                }
                if (off < r) {
                    shutdown(a, SHUT_RD);
                    aOpen = NO;
                }
            } else if (r == 0) {
                shutdown(b, SHUT_WR);
                aOpen = NO;
            } else if (errno != EINTR) {
                shutdown(b, SHUT_WR);
                aOpen = NO;
            }
        }
        if ((pfd[1].revents & (POLLIN | POLLHUP | POLLERR)) && bOpen) {
            ssize_t r = read(b, buf, sizeof(buf));
            if (r > 0) {
                ssize_t off = 0;
                while (off < r) {
                    ssize_t w = write(a, buf + off, (size_t)(r - off));
                    if (w < 0) {
                        if (errno == EINTR) continue;
                        break;
                    }
                    off += w;
                }
                if (off < r) {
                    shutdown(b, SHUT_RD);
                    bOpen = NO;
                }
            } else if (r == 0) {
                shutdown(a, SHUT_WR);
                bOpen = NO;
            } else if (errno != EINTR) {
                shutdown(a, SHUT_WR);
                bOpen = NO;
            }
        }
    }
}

- (void)handleConnection:(int)tcpFD
                 forPort:(int)port
                     api:(const kernarium_runtime_api *)api {
    int vsockFD = -1;
    if (api && api->connect_vsock) {
        // The bridge starts with the guest via systemd, so the
        // first connection after boot can race it: retry a few
        // times on refused before giving up.
        for (int attempt = 0; attempt < TX_LOCALHOST_VSOCK_RETRIES; attempt++) {
            vsockFD = api->connect_vsock(TX_LOCALHOST_BRIDGE_VSOCK_PORT,
                                         TX_LOCALHOST_VSOCK_TIMEOUT_MS);
            if (vsockFD >= 0) break;
            if (vsockFD == -ECONNREFUSED && attempt + 1 < TX_LOCALHOST_VSOCK_RETRIES) {
                struct timespec ts = {0, TX_LOCALHOST_VSOCK_RETRY_DELAY_MS * 1000 * 1000};
                nanosleep(&ts, NULL);
                continue;
            }
            break;
        }
    }
    if (vsockFD < 0) {
        // No guest, or no bridge: the iPhone side closes cleanly,
        // so the browser sees an empty reply, not a reset.
        TXLogEngine(@"Localhost proxy: vsock to bridge failed for port %d: %s",
                    port, strerror(-vsockFD));
        TXCloseCleanly(tcpFD);
        return;
    }
    // The target port, big-endian, then shuttle both ways.
    unsigned char portBytes[2] = {
        (unsigned char)((port >> 8) & 0xff),
        (unsigned char)(port & 0xff),
    };
    size_t sent = 0;
    while (sent < sizeof(portBytes)) {
        ssize_t w = write(vsockFD, portBytes + sent, sizeof(portBytes) - sent);
        if (w < 0) {
            if (errno == EINTR) continue;
            close(vsockFD);
            TXCloseCleanly(tcpFD);
            return;
        }
        sent += (size_t)w;
    }
    TXShuttle(tcpFD, vsockFD);
    close(vsockFD);
    close(tcpFD);
}

@end
