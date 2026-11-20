// TXLog - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXLog.h"

static dispatch_queue_t TXLogQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.spyboy.termx.log", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

NSString *TXLogEngineLogPath(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = docs.firstObject ?: @"";
    return [[docDir stringByAppendingPathComponent:@"Engine"] stringByAppendingPathComponent:@"engine.log"];
}

NSString *TXLogGuestLogPath(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = docs.firstObject ?: @"";
    return [[docDir stringByAppendingPathComponent:@"Engine"] stringByAppendingPathComponent:@"guest.log"];
}

// Keep a log file from growing forever: once it passes 512 KB,
// keep only the last 256 KB, starting at a line boundary.
// Byte-based, so a chunk of non-UTF-8 console output cannot defeat
// it. Runs on TXLogQueue only.
static void TXLogCapFileToTail(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length <= 512 * 1024) return;
    NSUInteger keepFrom = data.length - 256 * 1024;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    while (keepFrom < data.length && bytes[keepFrom] != '\n') keepFrom++;
    if (keepFrom < data.length) keepFrom++; // skip the newline itself
    NSData *tail = [data subdataWithRange:NSMakeRange(keepFrom, data.length - keepFrom)];
    [tail writeToFile:path atomically:YES];
}

// The file write itself: queue-confined. Creates the directory,
// appends the data, caps the file. Failure-tolerant by design.
static void TXLogAppendToFile(NSString *path, NSData *data) {
    if (!path.length || !data.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [data writeToFile:path atomically:NO];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:data];
    unsigned long long size = [fh offsetInFile];
    [fh closeFile];
    if (size > 512 * 1024) TXLogCapFileToTail(path);
}

void TXLogEngine(NSString *format, ...) {
    if (!format.length) return;
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!line.length) return;
    dispatch_async(TXLogQueue(), ^{
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
        NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
        TXLogAppendToFile(TXLogEngineLogPath(), data);
    });
}

void TXLogConsoleData(NSData *data) {
    if (!data.length) return;
    NSData *copy = [data copy];
    dispatch_async(TXLogQueue(), ^{
        TXLogAppendToFile(TXLogGuestLogPath(), copy);
    });
}

NSString *TXLogFullText(void) {
    NSString *engine = [NSString stringWithContentsOfFile:TXLogEngineLogPath()
                                                   encoding:NSUTF8StringEncoding error:nil];
    NSString *guest = [NSString stringWithContentsOfFile:TXLogGuestLogPath()
                                                  encoding:NSUTF8StringEncoding error:nil];
    if (!engine.length && !guest.length) return @"(no log yet — start the guest and lines will appear here)";
    NSMutableString *out = [NSMutableString string];
    if (engine.length) [out appendString:engine];
    if (guest.length) {
        if (out.length) [out appendString:@"\n--- Guest console ---\n"];
        [out appendString:guest];
    }
    return out;
}

NSString *TXFormatBytes(unsigned long long bytes) {
    if (bytes >= (1ULL << 30)) {
        return [NSString stringWithFormat:@"%.1f GiB", (double)bytes / (double)(1ULL << 30)];
    }
    if (bytes >= (1ULL << 20)) {
        return [NSString stringWithFormat:@"%.0f MiB", (double)bytes / (double)(1ULL << 20)];
    }
    if (bytes >= (1ULL << 10)) {
        return [NSString stringWithFormat:@"%.0f KiB", (double)bytes / (double)(1ULL << 10)];
    }
    return [NSString stringWithFormat:@"%llu B", bytes];
}
