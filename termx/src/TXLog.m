// TXLog - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXLog.h"
#import <mach/mach.h>
#import <errno.h>
#import <fcntl.h>
#import <pthread.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>

// The runtime's stdout/stderr reader: one thread, blocking reads,
// lines forwarded to TXLogEngine with a "runtime: " prefix. Runs
// for the process lifetime; a line longer than the buffer is
// truncated, never grown.
static void* TXLogRuntimeReader(void* arg) {
    int fd = (int)(intptr_t)arg;
    char chunk[4096];
    char line[4096];
    size_t lineLen = 0;
    for (;;) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n < 0) {
            if (errno == EINTR) continue;
            // A failed read must not spin: wait, then try again.
            [NSThread sleepForTimeInterval:1.0];
            continue;
        }
        if (n == 0) {
            // All write ends closed (cannot happen while fds 1/2 are
            // the pipe): wait, then try again.
            [NSThread sleepForTimeInterval:1.0];
            continue;
        }
        for (ssize_t i = 0; i < n; i++) {
            char c = chunk[i];
            if (c == '\n') {
                line[lineLen] = '\0';
                if (lineLen > 0) {
                    @autoreleasepool {
                        NSString* text = [[NSString alloc] initWithBytes:line
                                                                    length:lineLen
                                                                  encoding:NSUTF8StringEncoding];
                        if (text) TXLogEngine(@"runtime: %@", text);
                        else TXLogEngine(@"runtime: <non-UTF8 output>");
                    }
                }
                lineLen = 0;
            } else if (c != '\r') {
                if (lineLen < sizeof(line) - 1) line[lineLen++] = (char)c;
            }
        }
    }
    return NULL;
}

void TXLogCaptureRuntimeOutput(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // A reader that stops reading must never stall the runtime:
        // SIGPIPE is ignored, and the write end is non-blocking, so
        // a full pipe drops lines instead of blocking the boot
        // thread that is writing the failure.
        signal(SIGPIPE, SIG_IGN);
        int fds[2];
        if (pipe(fds) != 0) return;
        // pipe() returns the lowest free fds: if stdout/stderr were
        // closed at launch it can hand back 1 or 2 themselves, and
        // dup2 would then destroy the read end. Move both ends above
        // fd 2 first.
        int r = fds[0], w = fds[1];
        if (r <= STDERR_FILENO) {
            int n = fcntl(r, F_DUPFD_CLOEXEC, 3);
            if (n < 0) return;
            close(r);
            r = n;
        }
        if (w <= STDERR_FILENO) {
            int n = fcntl(w, F_DUPFD_CLOEXEC, 3);
            if (n < 0) return;
            close(w);
            w = n;
        }
        int flags = fcntl(w, F_GETFL, 0);
        if (flags >= 0) (void)fcntl(w, F_SETFL, flags | O_NONBLOCK);
        (void)dup2(w, STDOUT_FILENO);
        (void)dup2(w, STDERR_FILENO);
        (void)close(w);
        pthread_t thread;
        if (pthread_create(&thread, NULL, TXLogRuntimeReader, (void*)(intptr_t)r) == 0) {
            pthread_detach(thread);
        }
    });
}

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
// it. Runs on TXLogQueue only. The rewrite is in place, never by
// rename: TXCrashLog holds an open fd to this path, and an atomic
// write (temp file + rename) swaps the inode out from under it, so
// the crash handler's next write goes to the old unlinked inode and
// is lost. Truncating and writing through the same path keeps the
// inode, so the crash fd stays valid.
static void TXLogCapFileToTail(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length <= 512 * 1024) return;
    NSUInteger keepFrom = data.length - 256 * 1024;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    while (keepFrom < data.length && bytes[keepFrom] != '\n') keepFrom++;
    if (keepFrom < data.length) keepFrom++; // skip the newline itself
    NSData *tail = [data subdataWithRange:NSMakeRange(keepFrom, data.length - keepFrom)];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    [fh truncateFileAtOffset:0];
    [fh writeData:tail];
    [fh closeFile];
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

void TXLogFlush(void) {
    dispatch_sync(TXLogQueue(), ^{});
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

unsigned long long TXCurrentFootprintBytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (unsigned long long)info.phys_footprint;
    }
    return 0;
}
