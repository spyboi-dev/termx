// SPDX-License-Identifier: GPL-2.0-or-later
#import "AdbClient.h"
#import "AdbKey.h"
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>
#import <errno.h>

// ADB wire protocol (system/core/adb/protocol.txt).
#define A_CNXN 0x4e584e43u
#define A_AUTH 0x48545541u
#define A_OPEN 0x4e45504fu
#define A_OKAY 0x59414b4fu
#define A_CLSE 0x45534c43u
#define A_WRTE 0x45545257u
#define A_SYNC 0x434e5953u

#define ADB_VERSION 0x01000000u
#define ADB_MAX_PAYLOAD 4096u

typedef struct {
    uint32_t command;
    uint32_t arg0;
    uint32_t arg1;
    uint32_t data_length;
    uint32_t data_checksum;
    uint32_t magic;
} adb_message;

static uint32_t le32(uint32_t v) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return v;
#else
    return __builtin_bswap32(v);
#endif
}

static uint32_t adbChecksum(const void* data, size_t len) {
    const uint8_t* p = data;
    uint32_t sum = 0;
    for (size_t i = 0; i < len; i++) sum += p[i];
    return sum;
}

@interface AdbClient () {
    int _fd;
    uint32_t _localId;
    uint32_t _remoteId;
    uint32_t _maxPayload;
    BOOL _open;
}
@end

@implementation AdbClient

- (instancetype)initWithFD:(int)fd {
    if ((self = [super init])) {
        _fd = fd;
        _localId = 1;
        _maxPayload = ADB_MAX_PAYLOAD;
    }
    return self;
}

- (void)close {
    if (_open) {
        [self sendMessage:A_CLSE arg0:_remoteId arg1:_localId data:nil length:0];
        _open = NO;
    }
}

- (void)dealloc { [self close]; }

// --- raw socket IO: exact reads/writes, EINTR-tolerant ---

static BOOL readExact(int fd, void* buf, size_t len) {
    uint8_t* p = buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) return NO;
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

static BOOL writeExact(int fd, const void* buf, size_t len) {
    const uint8_t* p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

- (BOOL)sendMessage:(uint32_t)cmd arg0:(uint32_t)arg0 arg1:(uint32_t)arg1
               data:(const void*)data length:(uint32_t)len {
    adb_message m;
    m.command = le32(cmd);
    m.arg0 = le32(arg0);
    m.arg1 = le32(arg1);
    m.data_length = le32(len);
    m.data_checksum = le32(data ? adbChecksum(data, len) : 0);
    m.magic = le32(cmd ^ 0xffffffffu);
    if (!writeExact(_fd, &m, sizeof(m))) return NO;
    if (len > 0 && !writeExact(_fd, data, len)) return NO;
    return YES;
}

// Reads one message; returns NO on EOF/error. Data (if any) in *outData.
- (BOOL)readMessage:(adb_message*)out data:(NSData**)outData {
    adb_message raw;
    if (!readExact(_fd, &raw, sizeof(raw))) return NO;
    adb_message m;
    m.command = le32(raw.command);
    m.arg0 = le32(raw.arg0);
    m.arg1 = le32(raw.arg1);
    m.data_length = le32(raw.data_length);
    m.data_checksum = le32(raw.data_checksum);
    m.magic = le32(raw.magic);
    if (m.magic != (m.command ^ 0xffffffffu)) return NO;
    NSData* data = nil;
    if (m.data_length > 0) {
        if (m.data_length > 16 * 1024 * 1024) return NO;
        NSMutableData* d = [NSMutableData dataWithLength:m.data_length];
        if (!readExact(_fd, d.mutableBytes, m.data_length)) return NO;
        if (adbChecksum(d.bytes, d.length) != m.data_checksum) return NO;
        data = d;
    }
    *out = m;
    if (outData) *outData = data;
    return YES;
}

- (BOOL)connectWithError:(NSString**)error {
    if (![self sendMessage:A_CNXN arg0:ADB_VERSION arg1:ADB_MAX_PAYLOAD
                      data:"host::" length:7]) {
        if (error) *error = @"adb: could not write CNXN";
        return NO;
    }
    for (int i = 0; i < 10; i++) {
        adb_message m;
        NSData* data = nil;
        if (![self readMessage:&m data:&data]) {
            if (error) *error = @"adb: no reply to CNXN";
            return NO;
        }
        if (m.command == A_CNXN) {
            _maxPayload = m.arg1 > 0 ? m.arg1 : ADB_MAX_PAYLOAD;
            return YES;
        }
        if (m.command == A_AUTH && m.arg0 == 1) {
            // Token challenge: sign it.
            NSData* sig = [AdbKey signToken:data];
            if (!sig) {
                if (error) *error = @"adb: could not sign the auth token";
                return NO;
            }
            if (![self sendMessage:A_AUTH arg0:2 arg1:0 data:sig.bytes length:(uint32_t)sig.length]) {
                if (error) *error = @"adb: could not send the signature";
                return NO;
            }
            continue;
        }
        if (m.command == A_AUTH && m.arg0 == 3) {
            // Device wants our public key.
            NSString* pub = [AdbKey publicKeyBase64];
            if (!pub) {
                if (error) *error = @"adb: no host public key";
                return NO;
            }
            NSData* d = [pub dataUsingEncoding:NSUTF8StringEncoding];
            if (![self sendMessage:A_AUTH arg0:3 arg1:0 data:d.bytes length:(uint32_t)d.length]) {
                if (error) *error = @"adb: could not send the public key";
                return NO;
            }
            continue;
        }
    }
    if (error) *error = @"adb: auth did not complete";
    return NO;
}

- (BOOL)openService:(NSString*)service error:(NSString**)error {
    NSData* d = [[service stringByAppendingString:@""] dataUsingEncoding:NSUTF8StringEncoding];
    // Service strings are NUL-terminated on the wire.
    NSMutableData* wire = [d mutableCopy];
    uint8_t zero = 0;
    [wire appendBytes:&zero length:1];
    if (![self sendMessage:A_OPEN arg0:_localId arg1:0 data:wire.bytes length:(uint32_t)wire.length]) {
        if (error) *error = @"adb: could not OPEN the service";
        return NO;
    }
    for (int i = 0; i < 20; i++) {
        adb_message m;
        NSData* data = nil;
        if (![self readMessage:&m data:&data]) {
            if (error) *error = @"adb: no reply to OPEN";
            return NO;
        }
        if (m.command == A_OKAY && m.arg1 == _localId) {
            _remoteId = m.arg0;
            _open = YES;
            return YES;
        }
        if (m.command == A_CLSE) {
            if (error) *error = @"adb: service refused (CLSE)";
            return NO;
        }
    }
    if (error) *error = @"adb: OPEN timed out";
    return NO;
}

- (BOOL)writeData:(NSData*)data error:(NSString**)error {
    // Split into transport-sized WRTEs.
    size_t off = 0;
    while (off < data.length) {
        size_t chunk = data.length - off;
        if (chunk > _maxPayload) chunk = _maxPayload;
        if (![self sendMessage:A_WRTE arg0:_remoteId arg1:_localId
                          data:(const uint8_t*)data.bytes + off length:(uint32_t)chunk]) {
            if (error) *error = @"adb: WRTE failed";
            return NO;
        }
        off += chunk;
        // Each WRTE is acked with an OKAY.
        adb_message m;
        NSData* d = nil;
        if (![self readMessage:&m data:&d] || m.command != A_OKAY) {
            if (error) *error = @"adb: WRTE was not acked";
            return NO;
        }
    }
    return YES;
}

// Reads WRTE payloads until the device closes or the deadline passes.
// Returns the collected bytes (may be partial on timeout).
- (NSData*)readOutputUntilCloseWithDeadline:(NSDate*)deadline {
    NSMutableData* out = [NSMutableData data];
    while (YES) {
        if ([deadline timeIntervalSinceNow] < 0) break;
        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        adb_message m;
        NSData* data = nil;
        if (![self readMessage:&m data:&data]) break;
        if (m.command == A_WRTE && m.arg0 == _remoteId) {
            if (data.length > 0) [out appendData:data];
            [self sendMessage:A_OKAY arg0:_remoteId arg1:_localId data:nil length:0];
        } else if (m.command == A_CLSE) {
            break;
        } else if (m.command == A_OKAY) {
            // Ack for our own WRTE; ignore.
        }
    }
    struct timeval tv = {30, 0};
    setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    return out;
}

- (NSString*)shell:(NSString*)command timeout:(NSTimeInterval)timeout error:(NSString**)error {
    NSString* service = [@"shell:" stringByAppendingString:command];
    if (![self openService:service error:error]) return nil;
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSData* out = [self readOutputUntilCloseWithDeadline:deadline];
    [self close];
    NSString* s = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    return s ? s : @"";
}

- (BOOL)pushFile:(NSString*)localPath to:(NSString*)remotePath mode:(int)mode
        progress:(void (^)(double))progress error:(NSString**)error {
    if (![self openService:@"sync:" error:error]) return NO;
    NSData* file = [NSData dataWithContentsOfFile:localPath];
    if (!file) {
        if (error) *error = @"adb: could not read the local file";
        [self close];
        return NO;
    }
    // SEND <path>,<mode-decimal> then DATA chunks, DONE, QUIT.
    NSString* sendArg = [NSString stringWithFormat:@"%@,%d", remotePath, mode];
    NSData* sendPayload = [sendArg dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData* sync = [NSMutableData data];
    uint32_t len = le32((uint32_t)sendPayload.length);
    [sync appendBytes:"SEND" length:4];
    [sync appendBytes:&len length:4];
    [sync appendData:sendPayload];
    if (![self writeData:sync error:error]) { [self close]; return NO; }
    size_t off = 0;
    while (off < file.length) {
        size_t chunk = file.length - off;
        if (chunk > 65536) chunk = 65536;
        NSMutableData* data = [NSMutableData data];
        uint32_t dl = le32((uint32_t)chunk);
        [data appendBytes:"DATA" length:4];
        [data appendBytes:&dl length:4];
        [data appendBytes:(const uint8_t*)file.bytes + off length:chunk];
        if (![self writeData:data error:error]) { [self close]; return NO; }
        off += chunk;
        if (progress) progress((double)off / (double)file.length);
    }
    NSMutableData* done = [NSMutableData data];
    uint32_t fsize = le32((uint32_t)file.length);
    [done appendBytes:"DONE" length:4];
    [done appendBytes:&fsize length:4];
    if (![self writeData:done error:error]) { [self close]; return NO; }
    // Read the sync reply: OKAY or FAIL.
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    NSData* out = [self readOutputUntilCloseWithDeadline:deadline];
    [self close];
    if (out.length >= 8 && memcmp(out.bytes, "OKAY", 4) == 0) return YES;
    if (out.length >= 8 && memcmp(out.bytes, "FAIL", 4) == 0) {
        NSString* msg = [[NSString alloc] initWithData:[out subdataWithRange:NSMakeRange(8, out.length - 8)]
                                               encoding:NSUTF8StringEncoding];
        if (error) *error = [@"adb push failed: " stringByAppendingString:(msg ?: @"?")];
        return NO;
    }
    if (error) *error = @"adb push: no OKAY from the guest";
    return NO;
}

@end
