// TXJITManager - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXJITManager.h"
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <sys/socket.h>

NSString *const TXJITManagerStatusDidChangeNotification = @"TXJITManagerStatusDidChange";

typedef NS_ENUM(NSInteger, TXJITStatus) {
    TXJITStatusSearching,
    TXJITStatusNotFound,
    TXJITStatusConnecting,
    TXJITStatusUnauthenticated,
    TXJITStatusConnected,
    TXJITStatusEnabling,
    TXJITStatusUnreachable,
};

// --- TXJIT framing (plain C) ---
// BEGIN_FRAMING
// Protobuf varint: 7 bits per byte, LSB first, high bit set while
// more bytes follow.
static size_t TXJITAppendVarint(uint8_t *buf, uint64_t value) {
    size_t n = 0;
    while (value >= 0x80) {
        buf[n++] = (uint8_t)((value & 0x7F) | 0x80);
        value >>= 7;
    }
    buf[n++] = (uint8_t)value;
    return n;
}

// The EnableJIT protobuf message: field 1 bundleID (string),
// field 2 pid (uint64 varint). Returns a malloc'd buffer; *outLen
// is its length. Caller frees. Mirrors SwiptClient.enableJIT.
static uint8_t *TXJITBuildEnableJITMessage(const char *bundleID, uint64_t pid, size_t *outLen) {
    size_t idLen = strlen(bundleID);
    size_t cap = 1 + 10 + idLen + 1 + 10;
    uint8_t *buf = malloc(cap);
    if (!buf) { *outLen = 0; return NULL; }
    size_t off = 0;
    buf[off++] = 0x0A;
    off += TXJITAppendVarint(buf + off, (uint64_t)idLen);
    memcpy(buf + off, bundleID, idLen);
    off += idLen;
    buf[off++] = 0x10;
    off += TXJITAppendVarint(buf + off, pid);
    *outLen = off;
    return buf;
}

// Wrap a protobuf message in a gRPC-web frame: one 0x00 flag byte,
// the 4-byte big-endian message length, then the message. Returns
// a malloc'd buffer; *outLen is its length. Caller frees.
static uint8_t *TXJITBuildGRPCFrame(const uint8_t *message, size_t messageLen, size_t *outLen) {
    size_t total = 5 + messageLen;
    uint8_t *buf = malloc(total);
    if (!buf) { *outLen = 0; return NULL; }
    buf[0] = 0;
    buf[1] = (uint8_t)((messageLen >> 24) & 0xFF);
    buf[2] = (uint8_t)((messageLen >> 16) & 0xFF);
    buf[3] = (uint8_t)((messageLen >> 8) & 0xFF);
    buf[4] = (uint8_t)(messageLen & 0xFF);
    memcpy(buf + 5, message, messageLen);
    *outLen = total;
    return buf;
}
// END_FRAMING

@interface TXJITManager () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (nonatomic, strong) NSNetServiceBrowser *browser;
@property (nonatomic, strong) NSMutableArray<NSNetService *> *candidates;
@property (nonatomic, strong) NSNetService *resolvingService;
@property (nonatomic, strong) NSTimer *resolveTimer;
@property (nonatomic, strong) NSURL *serverURL;
@property (nonatomic, copy) NSString *serverName;
@property (nonatomic, assign) NSUInteger candidateIndex;
@property (nonatomic, assign) uint64_t generation;
@property (nonatomic, assign) BOOL connectInFlight;
@property (nonatomic, assign) BOOL enableInFlight;
@property (nonatomic, assign) BOOL jitEnabledValue;
@property (nonatomic, assign) BOOL jitActiveValue;
@property (nonatomic, assign) BOOL requiresTokenValue;
@property (nonatomic, copy) NSString *tokenValue;
@property (nonatomic, assign) TXJITStatus statusValue;
@end

@implementation TXJITManager

+ (instancetype)shared {
    static TXJITManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[TXJITManager alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _jitEnabledValue = [defaults objectForKey:@"termx.jitEnabled"]
        ? [defaults boolForKey:@"termx.jitEnabled"] : YES;
    _tokenValue = [defaults stringForKey:@"termx.swiptToken"] ?: @"";
    _candidates = [NSMutableArray array];
    _statusValue = TXJITStatusSearching;
    [self startDiscovery];
    return self;
}

#pragma mark - Public API

- (BOOL)jitEnabled { return _jitEnabledValue; }
- (BOOL)jitActive { return _jitActiveValue; }
- (BOOL)requiresToken { return _requiresTokenValue; }
- (NSString *)swiptToken { return _tokenValue; }

- (NSString *)statusText {
    if (_jitActiveValue) return @"Enabled";
    switch (_statusValue) {
        case TXJITStatusSearching: return @"Searching…";
        case TXJITStatusNotFound: return @"Not Found";
        case TXJITStatusConnecting: return @"Connecting…";
        case TXJITStatusUnauthenticated:
            return _tokenValue.length > 0 ? @"Incorrect Token" : @"Token Required";
        case TXJITStatusConnected: return @"Connected";
        case TXJITStatusEnabling: return @"Enabling…";
        case TXJITStatusUnreachable: return @"Not Connected";
    }
}

- (void)setJITEnabled:(BOOL)enabled {
    _jitEnabledValue = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"termx.jitEnabled"];
    if (enabled) {
        // A fresh enable for this launch: the server must confirm
        // EnableJIT again (it is per-launch, not persistent).
        _jitActiveValue = NO;
        [self refresh];
    }
    [self notifyStatusChange];
}

- (void)setSwiptToken:(NSString *)token {
    _tokenValue = [token copy] ?: @"";
    [[NSUserDefaults standardUserDefaults] setObject:_tokenValue forKey:@"termx.swiptToken"];
    // A new token may unlock a server that asked for one: retry.
    _jitActiveValue = NO;
    [self refresh];
}

- (void)refresh {
    [self startDiscovery];
    if (self.serverURL && _jitEnabledValue && !_jitActiveValue && !self.enableInFlight) {
        [self setStatus:TXJITStatusConnected];
        [self scheduleEnable];
    } else if (!self.serverURL) {
        [self maybeConnect];
    }
}

#pragma mark - Discovery

- (void)startDiscovery {
    if (self.browser) return;
    self.browser = [[NSNetServiceBrowser alloc] init];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_swipt._tcp." inDomain:@"local."];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service
                moreComing:(BOOL)moreComing {
    (void)browser;
    // A TXT record with a "udid" key is for a different device
    // (Swipterm filters the same way); ignore it. If the TXT
    // record is not available yet, keep the candidate and re-check
    // after resolving.
    NSDictionary *txt = [NSNetService dictionaryFromTXTRecordData:service.TXTRecordData];
    if ([self txtStringForKey:@"udid" inRecord:txt]) return;
    BOOL already = NO;
    for (NSNetService *existing in self.candidates) {
        if ([existing.name isEqualToString:service.name]) { already = YES; break; }
    }
    if (!already) {
        [self.candidates addObject:service];
        [self.candidates sortUsingComparator:^NSComparisonResult(NSNetService *a, NSNetService *b) {
            return [a.name compare:b.name];
        }];
    }
    if (!moreComing) [self maybeConnect];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
         didRemoveService:(NSNetService *)service
                moreComing:(BOOL)moreComing {
    (void)browser; (void)moreComing;
    [self.candidates removeObject:service];
    if ([service.name isEqualToString:self.serverName ?: @""]) {
        self.serverURL = nil;
        self.serverName = nil;
        _jitActiveValue = NO;
        [self notifyStatusChange];
        [self maybeConnect];
    }
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
              didNotSearch:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    (void)browser; (void)errorDict;
    [self setStatus:TXJITStatusUnreachable];
    // Discovery failed (local network denied, or no network): try
    // again after a pause instead of spinning.
    self.browser = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self startDiscovery]; });
}

- (void)netServiceBrowserDidStopSearch:(NSNetServiceBrowser *)browser {
    (void)browser;
}

#pragma mark - Connect

- (void)maybeConnect {
    if (self.connectInFlight || self.enableInFlight) return;
    if (self.candidates.count == 0) {
        self.serverURL = nil;
        self.serverName = nil;
        [self setStatus:TXJITStatusNotFound];
        return;
    }
    self.connectInFlight = YES;
    self.generation++;
    [self setStatus:TXJITStatusConnecting];
    [self resolveCandidateAtIndex:0];
}

- (void)resolveCandidateAtIndex:(NSUInteger)index {
    if (index >= self.candidates.count) {
        self.connectInFlight = NO;
        [self setStatus:TXJITStatusUnreachable];
        return;
    }
    [self resolveService:self.candidates[index]];
}

- (void)tryNextCandidate {
    [self resolveCandidateAtIndex:self.candidateIndex + 1];
}

- (void)resolveService:(NSNetService *)service {
    self.candidateIndex = [self.candidates indexOfObject:service];
    self.resolvingService = service;
    service.delegate = self;
    [service resolveWithTimeout:5.0];
    __weak TXJITManager *weakSelf = self;
    self.resolveTimer = [NSTimer scheduledTimerWithTimeInterval:5.5
                                                        repeats:NO
                                                          block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf resolveTimedOut];
    }];
}

- (void)resolveTimedOut {
    self.resolveTimer = nil;
    if (self.resolvingService) {
        [self.resolvingService stop];
        self.resolvingService = nil;
    }
    [self tryNextCandidate];
}

- (void)netServiceDidResolveAddress:(NSNetService *)service {
    if (service != self.resolvingService) return;
    [self.resolveTimer invalidate];
    self.resolveTimer = nil;
    self.resolvingService = nil;
    // Re-check the TXT record now that it is resolved.
    NSDictionary *txt = [NSNetService dictionaryFromTXTRecordData:service.TXTRecordData];
    if ([self txtStringForKey:@"udid" inRecord:txt]) {
        [self tryNextCandidate];
        return;
    }
    // The server runs on this device: only accept a resolved
    // address that is one of the device's local IPv4 addresses.
    NSString *ipv4 = [self ipv4AddressFromService:service];
    if (!ipv4 || ![[self localIPv4Addresses] containsObject:ipv4]) {
        [self tryNextCandidate];
        return;
    }
    self.requiresTokenValue = [[self txtStringForKey:@"auth" inRecord:txt] isEqualToString:@"1"];
    self.serverURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)service.port]];
    self.serverName = service.name;
    [self checkConnectionWithToken:NO];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    (void)service; (void)errorDict;
    if (service != self.resolvingService) return;
    [self.resolveTimer invalidate];
    self.resolveTimer = nil;
    self.resolvingService = nil;
    [self tryNextCandidate];
}

#pragma mark - gRPC-web

// Probe: GetInfo with an empty message. Success means the server is
// reachable; grpc-status 16 means it needs a token.
- (void)checkConnectionWithToken:(BOOL)withToken {
    NSURL *server = self.serverURL;
    NSString *token = (withToken && self.tokenValue.length > 0) ? self.tokenValue : nil;
    uint64_t gen = self.generation;
    __weak TXJITManager *weakSelf = self;
    [self grpcCallMethod:@"swipt.SystemService/GetInfo"
                  server:server
                   token:token
                 message:[NSData data]
              completion:^(NSInteger grpcStatus, NSString *grpcMessage, NSError *error) {
        (void)grpcMessage;
        dispatch_async(dispatch_get_main_queue(), ^{
            TXJITManager *strongSelf = weakSelf;
            if (!strongSelf || gen != strongSelf.generation) return;
            if (error) { [strongSelf tryNextCandidate]; return; }
            if (grpcStatus == 0) {
                strongSelf.connectInFlight = NO;
                [strongSelf setStatus:TXJITStatusConnected];
                [strongSelf scheduleEnable];
            } else if (grpcStatus == 16) {
                strongSelf.connectInFlight = NO;
                strongSelf.requiresTokenValue = YES;
                if (!withToken && strongSelf.tokenValue.length > 0) {
                    // A saved token exists but was not sent: retry
                    // with it before reporting unauthenticated.
                    [strongSelf checkConnectionWithToken:YES];
                } else {
                    [strongSelf setStatus:TXJITStatusUnauthenticated];
                }
            } else {
                [strongSelf tryNextCandidate];
            }
        });
    }];
}

- (void)scheduleEnable {
    if (!_jitEnabledValue || _jitActiveValue) return;
    if (self.statusValue != TXJITStatusConnected) return;
    if (self.enableInFlight || !self.serverURL) return;
    [self setStatus:TXJITStatusEnabling];
    self.enableInFlight = YES;
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    size_t msgLen = 0;
    uint8_t *msg = TXJITBuildEnableJITMessage(bundleID.UTF8String, (uint64_t)getpid(), &msgLen);
    NSData *message = msg ? [NSData dataWithBytes:msg length:msgLen] : [NSData data];
    free(msg);
    NSString *token = self.requiresTokenValue ? self.tokenValue : nil;
    NSURL *server = self.serverURL;
    uint64_t gen = self.generation;
    __weak TXJITManager *weakSelf = self;
    [self grpcCallMethod:@"swipt.DeviceService/EnableJIT"
                  server:server
                   token:token
                 message:message
              completion:^(NSInteger grpcStatus, NSString *grpcMessage, NSError *error) {
        (void)grpcMessage;
        dispatch_async(dispatch_get_main_queue(), ^{
            TXJITManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.enableInFlight = NO;
            if (gen != strongSelf.generation) return;
            if (error) {
                [strongSelf setStatus:TXJITStatusUnreachable];
                return;
            }
            if (grpcStatus == 0) {
                strongSelf.jitActiveValue = YES;
                [strongSelf setStatus:TXJITStatusConnected];
            } else if (grpcStatus == 16) {
                strongSelf.requiresTokenValue = YES;
                [strongSelf setStatus:TXJITStatusUnauthenticated];
            } else {
                [strongSelf setStatus:TXJITStatusUnreachable];
            }
        });
    }];
}

// One gRPC-web POST. Mirrors SwiptClient.call: body is a 0x00 flag
// byte, the 4-byte big-endian message length, then the message.
// Success is grpc-status "0", read from the response header or
// from the trailer frame in the body. Status 16 is unauthenticated.
- (void)grpcCallMethod:(NSString *)method
                server:(NSURL *)server
                 token:(NSString *)token
               message:(NSData *)message
            completion:(void (^)(NSInteger grpcStatus, NSString *grpcMessage, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:
        [NSString stringWithFormat:@"%@/%@", server.absoluteString, method]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 8.0;
    [request setValue:@"application/grpc-web+proto" forHTTPHeaderField:@"Content-Type"];
    if (token.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
    }
    size_t frameLen = 0;
    uint8_t *frame = TXJITBuildGRPCFrame(message.bytes, message.length, &frameLen);
    request.HTTPBody = frame ? [NSData dataWithBytes:frame length:frameLen] : [NSData data];
    free(frame);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { completion(-1, nil, error); return; }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *grpcStatus = [self headerValue:@"grpc-status" inResponse:http];
        NSString *grpcMessage = [self headerValue:@"grpc-message" inResponse:http];
        // Trailer frames: flags 0x80, payload is "key: value" lines.
        if (data.length > 0) {
            const uint8_t *bytes = data.bytes;
            NSUInteger offset = 0;
            while (offset + 5 <= data.length) {
                uint8_t flags = bytes[offset];
                uint32_t flen = ((uint32_t)bytes[offset + 1] << 24)
                    | ((uint32_t)bytes[offset + 2] << 16)
                    | ((uint32_t)bytes[offset + 3] << 8)
                    | (uint32_t)bytes[offset + 4];
                NSUInteger payloadStart = offset + 5;
                NSUInteger available = data.length - payloadStart;
                NSUInteger payloadLen = MIN((NSUInteger)flen, available);
                if (flags & 0x80) {
                    NSString *trailer = [[NSString alloc]
                        initWithBytes:bytes + payloadStart
                               length:payloadLen
                             encoding:NSUTF8StringEncoding];
                    for (NSString *line in [trailer componentsSeparatedByCharactersInSet:
                        [NSCharacterSet newlineCharacterSet]]) {
                        NSRange colon = [line rangeOfString:@":"];
                        if (colon.location == NSNotFound) continue;
                        NSString *key = [[line substringToIndex:colon.location] lowercaseString];
                        NSString *value = [[line substringFromIndex:colon.location + 1]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if ([key isEqualToString:@"grpc-status"]) grpcStatus = value;
                        else if ([key isEqualToString:@"grpc-message"]) grpcMessage = value;
                    }
                }
                if (flen > available) break;
                offset = payloadStart + flen;
            }
        }
        if (!grpcStatus) {
            if (http.statusCode != 200) {
                NSError *err = [NSError errorWithDomain:NSURLErrorDomain
                                                     code:http.statusCode
                                                 userInfo:@{NSLocalizedDescriptionKey:
                    [NSHTTPURLResponse localizedStringForStatusCode:http.statusCode]}];
                completion(-1, nil, err);
                return;
            }
            completion(-1, nil, [NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorBadServerResponse
                                                 userInfo:nil]);
            return;
        }
        NSString *decoded = grpcMessage ? [grpcMessage stringByRemovingPercentEncoding] : nil;
        completion([grpcStatus integerValue], decoded ?: grpcMessage, nil);
    }];
    [task resume];
}

// Header lookup is case-insensitive (the server sends lowercase
// grpc-status; NSURLSession preserves the case it received).
- (NSString *)headerValue:(NSString *)name inResponse:(NSHTTPURLResponse *)response {
    for (NSString *key in response.allHeaderFields) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) {
            id value = response.allHeaderFields[key];
            if ([value isKindOfClass:[NSString class]]) return value;
        }
    }
    return nil;
}

#pragma mark - Helpers

- (void)setStatus:(TXJITStatus)status {
    _statusValue = status;
    [self notifyStatusChange];
}

- (void)notifyStatusChange {
    if ([NSThread isMainThread]) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TXJITManagerStatusDidChangeNotification object:self];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:TXJITManagerStatusDidChangeNotification object:self];
        });
    }
}

// TXT record values arrive as NSData; decode one key as UTF-8.
- (NSString *)txtStringForKey:(NSString *)key inRecord:(NSDictionary *)txt {
    id value = txt[key];
    if (![value isKindOfClass:[NSData class]]) return nil;
    return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
}

- (NSString *)ipv4AddressFromService:(NSNetService *)service {
    for (NSData *addrData in service.addresses) {
        const struct sockaddr *sa = (const struct sockaddr *)addrData.bytes;
        if (sa->sa_family == AF_INET) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
            char buf[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                return [NSString stringWithUTF8String:buf];
            }
        }
    }
    return nil;
}

// 127.0.0.1 plus every IPv4 address of this device.
- (NSSet<NSString *> *)localIPv4Addresses {
    NSMutableSet<NSString *> *set = [NSMutableSet setWithObject:@"127.0.0.1"];
    struct ifaddrs *head = NULL;
    if (getifaddrs(&head) == 0) {
        for (struct ifaddrs *p = head; p; p = p->ifa_next) {
            if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET) {
                struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
                char buf[INET_ADDRSTRLEN];
                if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                    [set addObject:[NSString stringWithUTF8String:buf]];
                }
            }
        }
        freeifaddrs(head);
    }
    return set;
}

@end
