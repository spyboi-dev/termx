// TXCrashLog - see the header. Only async-signal-safe calls run in
// the signal handler: write(), open(), read(), lseek(), close(),
// time(). The uncaught-exception handler is not signal context, so
// snprintf and ObjC are fine there; the runtime aborts right after
// it returns, which the SIGABRT handler also records.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXCrashLog.h"
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <time.h>
#import <stdio.h>
#import <limits.h>

static int TXCrashLogFd = -1;
static volatile sig_atomic_t TXCrashLogInHandler = 0;
// Paths fixed at install time as plain C strings, so the signal
// handler needs no ObjC and no allocation. CRASH.txt lives at the
// top of Documents; engine.log is Documents/Engine/engine.log.
static char TXCrashLogCrashPath[1024];
static char TXCrashLogEnginePath[1024];

static void TXCrashLogWriteRaw(const char *bytes, size_t len) {
    if (TXCrashLogFd < 0 || !bytes || len == 0) return;
    // One fd, O_APPEND: appends stay whole against the engine log's
    // own appends from the other thread.
    const char *p = bytes;
    size_t left = len;
    while (left > 0) {
        ssize_t w = write(TXCrashLogFd, p, left);
        if (w <= 0) return;
        p += w;
        left -= (size_t)w;
    }
}

// Append a decimal number to the buffer. Returns the new position.
static size_t TXCrashLogAppendNumber(char *buf, size_t pos, size_t cap, long long value) {
    char tmp[24];
    size_t digits = 0;
    long long v = value;
    if (v == 0) {
        tmp[digits++] = '0';
    } else {
        while (v > 0 && digits < sizeof(tmp)) {
            tmp[digits++] = (char)('0' + (v % 10));
            v /= 10;
        }
    }
    while (digits > 0 && pos + 1 < cap) buf[pos++] = tmp[--digits];
    return pos;
}

// Write a timestamped marker line ("[HH:MM:SS] <text>\n") to the
// engine-log fd. Normal context only (uses localtime_r/snprintf).
static void TXCrashLogWriteMarker(const char *text) {
    if (TXCrashLogFd < 0 || !text) return;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char line[128];
    int len = snprintf(line, sizeof(line), "[%02d:%02d:%02d] %s\n",
                       tmv.tm_hour, tmv.tm_min, tmv.tm_sec, text);
    if (len > 0) TXCrashLogWriteRaw(line, (size_t)len);
}

// Write Documents/CRASH.txt (overwritten on each crash): the title
// line, then the last ~2 KB of the engine log, starting at a line
// boundary. Signal-safe: open/read/lseek/write/close only, stack
// buffers only. Best effort throughout: any failure just leaves a
// shorter CRASH.txt.
static void TXCrashLogWriteCrashFile(const char *title, size_t titleLen) {
    if (TXCrashLogCrashPath[0] == '\0') return;
    int fd = open(TXCrashLogCrashPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    const char *p = title;
    size_t left = titleLen;
    while (left > 0) {
        ssize_t w = write(fd, p, left);
        if (w <= 0) break;
        p += w;
        left -= (size_t)w;
    }
    const char *header = "Last engine log lines:\n";
    size_t hleft = strlen(header);
    p = header;
    while (hleft > 0) {
        ssize_t w = write(fd, p, hleft);
        if (w <= 0) break;
        p += w;
        hleft -= (size_t)w;
    }
    if (TXCrashLogEnginePath[0] != '\0') {
        int efd = open(TXCrashLogEnginePath, O_RDONLY);
        if (efd >= 0) {
            off_t end = lseek(efd, 0, SEEK_END);
            if (end > 0) {
                off_t want = end > 2048 ? 2048 : end;
                off_t start = end - want;
                if (lseek(efd, start, SEEK_SET) == start) {
                    char buf[2048];
                    size_t got = 0;
                    while (got < (size_t)want) {
                        ssize_t n = read(efd, buf + got, (size_t)want - got);
                        if (n <= 0) break;
                        got += (size_t)n;
                    }
                    size_t off = 0;
                    if (start > 0) {
                        // Skip a partial first line.
                        while (off < got && buf[off] != '\n') off++;
                        if (off < got) off++;
                    }
                    p = buf + off;
                    left = got - off;
                    while (left > 0) {
                        ssize_t w = write(fd, p, left);
                        if (w <= 0) break;
                        p += w;
                        left -= (size_t)w;
                    }
                }
            }
            close(efd);
        }
    }
    close(fd);
}

static void TXCrashLogSignalHandler(int signo) {
    if (TXCrashLogInHandler) {
        // Already dying in the handler: do not recurse, just die
        // the normal way.
        signal(signo, SIG_DFL);
        raise(signo);
        return;
    }
    TXCrashLogInHandler = 1;
    const char *name = "UNKNOWN";
    switch (signo) {
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGABRT: name = "SIGABRT"; break;
        case SIGBUS: name = "SIGBUS"; break;
        case SIGILL: name = "SIGILL"; break;
    }
    // "CRASH <name> t=<epoch seconds>\n", built by hand.
    char buf[128];
    size_t pos = 0;
    const char *prefix = "CRASH ";
    while (*prefix && pos + 1 < sizeof(buf)) buf[pos++] = *prefix++;
    while (*name && pos + 1 < sizeof(buf)) buf[pos++] = *name++;
    const char *mid = " t=";
    while (*mid && pos + 1 < sizeof(buf)) buf[pos++] = *mid++;
    pos = TXCrashLogAppendNumber(buf, pos, sizeof(buf), (long long)time(NULL));
    if (pos + 1 < sizeof(buf)) buf[pos++] = '\n';
    TXCrashLogWriteRaw(buf, pos);
    TXCrashLogWriteCrashFile(buf, pos);
    // Let the crash proceed normally so iOS still writes its report.
    signal(signo, SIG_DFL);
    raise(signo);
}

static void TXCrashLogUncaughtException(NSException *exception) {
    if (TXCrashLogFd < 0) return;
    const char *name = "?";
    const char *reason = "?";
    if (exception.name) name = exception.name.UTF8String ?: "?";
    if (exception.reason) reason = exception.reason.UTF8String ?: "?";
    char buf[512];
    int len = snprintf(buf, sizeof(buf), "CRASH uncaught exception %s: %s t=%lld\n",
                       name, reason, (long long)time(NULL));
    if (len > 0) {
        size_t n = (size_t)len < sizeof(buf) ? (size_t)len : sizeof(buf) - 1;
        TXCrashLogWriteRaw(buf, n);
        TXCrashLogWriteCrashFile(buf, n);
    }
}

// Previous-run check (normal context, Foundation is fine). Reads
// the last 64 KB of the engine log: a CRASH line already explains
// the run's end. Otherwise, anything after the last CLEAN SHUTDOWN
// marker means the process did work after its last clean shutdown
// and then ended without one (jetsam / SIGKILL leave no trace), so
// append the unclean-end line. A log that ends exactly at a marker
// is clean; a missing or empty log is a first launch, not a crash.
static void TXCrashLogCheckPreviousRun(NSString *logPath) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:logPath];
    if (!fh) return;
    unsigned long long size = [fh seekToEndOfFile];
    if (size == 0) { [fh closeFile]; return; }
    unsigned long long window = size > 65536 ? 65536 : size;
    [fh seekToFileOffset:size - window];
    NSData *tailData = [fh readDataToEndOfFile];
    [fh closeFile];
    NSString *text = [[NSString alloc] initWithData:tailData encoding:NSUTF8StringEncoding];
    if (!text.length) return;
    if ([text containsString:@"CRASH "]) return;
    NSString *rest = text;
    NSRange marker = [text rangeOfString:@"CLEAN SHUTDOWN" options:NSBackwardsSearch];
    if (marker.location != NSNotFound) {
        NSUInteger after = NSMaxRange(marker);
        rest = after < text.length ? [text substringFromIndex:after] : @"";
    }
    NSString *trimmed = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return;
    TXCrashLogWriteMarker("Previous run ended without shutdown (likely killed by iOS, e.g. jetsam; no signal handler runs for SIGKILL)");
}

void TXCrashLogInstall(NSString *logPath) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    if (!logPath.length) return;
    NSString *dir = [logPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open(logPath.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    TXCrashLogFd = fd;
    // Paths for the signal handler (plain C strings, bounded).
    snprintf(TXCrashLogEnginePath, sizeof(TXCrashLogEnginePath), "%s", logPath.UTF8String ?: "");
    NSString *documents = [[dir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"CRASH.txt"];
    snprintf(TXCrashLogCrashPath, sizeof(TXCrashLogCrashPath), "%s", documents.UTF8String ?: "");
    NSSetUncaughtExceptionHandler(&TXCrashLogUncaughtException);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = &TXCrashLogSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
}

void TXCrashLogInstallEarly(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = docs.firstObject;
    if (!docDir.length) return;
    NSString *logPath = [[docDir stringByAppendingPathComponent:@"Engine"] stringByAppendingPathComponent:@"engine.log"];
    TXCrashLogInstall(logPath);
    TXCrashLogCheckPreviousRun(logPath);
    TXCrashLogWriteMarker("--- App launch ---");
}

void TXCrashLogMarkCleanShutdown(void) {
    TXCrashLogWriteMarker("CLEAN SHUTDOWN");
}

void TXCrashLogMarkForeground(void) {
    TXCrashLogWriteMarker("--- Foreground ---");
}
