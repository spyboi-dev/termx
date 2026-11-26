// TXLoopbackProbe - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXLoopbackProbe.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <poll.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

static NSString *const kTXLoopbackAddress = @"10.7.0.1";
static const uint16_t kTXLoopbackPort = 62078;

@implementation TXLoopbackProbeResult

- (instancetype)initWithReachable:(BOOL)reachable
                     milliseconds:(double)milliseconds
                           detail:(NSString *)detail
                        interface:(NSString *)interfaceName
                     localAddress:(NSString *)localAddress {
    self = [super init];
    if (self) {
        _reachable = reachable;
        _milliseconds = milliseconds;
        _detail = [detail copy];
        _interfaceName = [interfaceName copy];
        _localAddress = [localAddress copy];
        _routedViaVPN = interfaceName != nil
            && ([interfaceName hasPrefix:@"utun"]
                || [interfaceName hasPrefix:@"ipsec"]
                || [interfaceName hasPrefix:@"ppp"]);
        _routedViaLocalDevVPN = _routedViaVPN
            && localAddress != nil && [localAddress hasPrefix:@"10.7."];
    }
    return self;
}

@end

@implementation TXLoopbackProbe

+ (struct sockaddr_in)targetAddress {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTXLoopbackPort);
    inet_pton(AF_INET, [kTXLoopbackAddress UTF8String], &addr.sin_addr);
    return addr;
}

// The interface holding `address`, from the interface list.
+ (NSString *)interfaceNameForAddress:(in_addr_t)address {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || !list) return nil;
    NSString *name = nil;
    for (struct ifaddrs *entry = list; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET) continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)entry->ifa_addr;
        if (sin->sin_addr.s_addr == address) {
            name = [NSString stringWithUTF8String:entry->ifa_name];
            break;
        }
    }
    freeifaddrs(list);
    return name;
}

// The interface and local address traffic to 10.7.0.1 would leave
// by, from an unsent UDP connect (no packets leave the device).
+ (void)routeWithInterface:(NSString **)interface
              localAddress:(NSString **)localAddress {
    struct sockaddr_in target = [self targetAddress];
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) return;
    if (connect(fd, (struct sockaddr *)&target, sizeof(target)) != 0) {
        close(fd);
        return;
    }
    struct sockaddr_in local;
    socklen_t len = sizeof(local);
    if (getsockname(fd, (struct sockaddr *)&local, &len) == 0) {
        char text[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &local.sin_addr, text, sizeof(text))) {
            if (localAddress) *localAddress = [NSString stringWithUTF8String:text];
            if (interface) *interface = [self interfaceNameForAddress:local.sin_addr.s_addr] ?: @"?";
        }
    }
    close(fd);
}

+ (TXLoopbackProbeResult *)checkWithTimeout:(NSTimeInterval)timeout {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    TXLoopbackProbeResult *(^done)(BOOL, NSString *, NSString *, NSString *) =
        ^(BOOL ok, NSString *detail, NSString *interface, NSString *address) {
        return [[TXLoopbackProbeResult alloc]
            initWithReachable:ok
                 milliseconds:(CFAbsoluteTimeGetCurrent() - start) * 1000
                       detail:detail
                    interface:interface
                 localAddress:address];
    };
    NSString *interface = nil;
    NSString *address = nil;
    [self routeWithInterface:&interface localAddress:&address];
    if (!interface) return done(NO, @"no route", nil, nil);
    BOOL viaVPN = [interface hasPrefix:@"utun"] || [interface hasPrefix:@"ipsec"] || [interface hasPrefix:@"ppp"];
    if (!viaVPN) {
        return done(NO, [NSString stringWithFormat:@"routed via %@, not a VPN", interface], interface, address);
    }
    if (![address hasPrefix:@"10.7."]) {
        return done(NO, [NSString stringWithFormat:@"routed via %@ %@: another VPN, not LocalDevVPN",
                         interface, address ?: @"?"], interface, address);
    }
    struct sockaddr_in target = [self targetAddress];
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        return done(NO, [NSString stringWithFormat:@"socket: %s", strerror(errno)], interface, address);
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int connected = connect(fd, (struct sockaddr *)&target, sizeof(target));
    if (connected != 0 && errno != EINPROGRESS) {
        NSString *detail = [NSString stringWithFormat:@"%s via %@",
                            strerror(errno), interface];
        close(fd);
        return done(NO, detail, interface, address);
    }
    if (connected != 0) {
        NSTimeInterval remaining = start + timeout - CFAbsoluteTimeGetCurrent();
        struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
        int ready = poll(&pfd, 1, (int)MAX(1, remaining * 1000));
        if (ready <= 0) {
            NSString *detail = ready == 0
                ? [NSString stringWithFormat:@"timed out via %@", interface]
                : [NSString stringWithFormat:@"%s", strerror(errno)];
            close(fd);
            return done(NO, detail, interface, address);
        }
        int err = 0;
        socklen_t errLen = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen);
        if (err != 0) {
            NSString *detail = [NSString stringWithFormat:@"%s via %@",
                                strerror(err), interface];
            close(fd);
            return done(NO, detail, interface, address);
        }
    }
    close(fd);
    return done(YES, [NSString stringWithFormat:@"connected via %@ %@", interface, address ?: @"?"],
                interface, address);
}

+ (void)checkWithTimeout:(NSTimeInterval)timeout
              completion:(void (^)(TXLoopbackProbeResult *result))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TXLoopbackProbeResult *result = [self checkWithTimeout:timeout];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

+ (void)waitUntilReachableWithin:(NSTimeInterval)within
                      completion:(void (^)(TXLoopbackProbeResult *result))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + within;
        TXLoopbackProbeResult *result = [self checkWithTimeout:0.4];
        while (!result.reachable && CFAbsoluteTimeGetCurrent() < deadline) {
            [NSThread sleepForTimeInterval:0.25];
            result = [self checkWithTimeout:0.4];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

+ (BOOL)vpnInterfaceUp {
    NSString *interface = nil;
    NSString *address = nil;
    [self routeWithInterface:&interface localAddress:&address];
    if (!interface || !address) return NO;
    BOOL viaVPN = [interface hasPrefix:@"utun"] || [interface hasPrefix:@"ipsec"] || [interface hasPrefix:@"ppp"];
    return viaVPN && [address hasPrefix:@"10.7."];
}

@end
