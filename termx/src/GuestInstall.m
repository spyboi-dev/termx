// SPDX-License-Identifier: GPL-2.0-or-later
#import "GuestInstall.h"
#import "TXLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h> // UIApplicationDidReceiveMemoryWarningNotification
#import <mach/mach.h>
#import <zlib.h>

// Private helper defined below its first use.
@interface GuestInstall ()
+ (BOOL)gunzipFile:(NSString*)src to:(NSString*)dst error:(NSString**)error;
// The body of installGuestTo:, on a background queue (the installed
// check can SHA-256 a 1 GiB image; never on the main thread).
+ (void)installGuestToOnQueue:(NSString*)rootfsPath
                     progress:(void (^)(double, NSString*, int64_t, int64_t))progress
                   completion:(void (^)(BOOL, NSString*))completion;
@end

// Guest image: Debian trixie arm64 MINIMAL (slim), built 2026-11-21
// (see rootfs-build/build-rootfs-slim.sh). Boots to a shell with working
// apt and networking; users apt-install what they need. The .ext4.gz must
// be published at kRootfsURL before first use from the app; the app
// refuses an image whose hash does not match.
//
// NOTE: these four constants are the SLIM image (release
// rootfs-20261121-slim). The local filename kRootfsName is deliberately
// UNCHANGED from the old full image: the slim image replaces the full
// one at the same path, so a phone holding the full image sees a
// size/hash mismatch, treats it as "reinstall", and swaps cleanly.
// The persistent data disk (termx-data.ext4) is a separate file and is
// never touched by the image switch.
NSString* const kRootfsURL =
    @"https://github.com/spyboi-dev/termx/releases/download/rootfs-20261121-slim/termx-debian-trixie-arm64-slim.ext4.gz";
NSString* const kRootfsName = @"termx-debian-trixie-arm64.ext4";
NSString* const kRootfsGzSHA256 = @"26924f8b8e52c5ec095a767499dc20567a4b267551fb6dc3e0029724e5db549b";
NSString* const kRootfsSHA256 = @"2d2565701f685733ddc8cfdc6645dc0522e6ff38e6a38b0343f2ed19f0813f0c";
const long long kRootfsSize = 1073741824; // extracted image size in bytes (exactly 1 GiB)

// Background session: one identifier for the process lifetime, so a
// download survives the phone locking, the app suspending, and the app
// being killed, and the system can wake the app when it finishes.
static NSString* const kDownloadSessionIdentifier = @"app.termx.ios.rootfs-download";

// The .gz download is ~116 MB and the extracted image exactly 1 GiB. The
// install needs both alive at once, plus headroom for the OS, so refuse
// to start (or to extract) when the phone is too full, with the numbers
// in the error, instead of dying halfway through with ENOSPC.
static const unsigned long long kFreeSpaceNeededBeforeDownload = 1ULL << 30; // 1 GiB
static const unsigned long long kFreeSpaceNeededBeforeExtract = 3ULL << 29;  // 1.5 GiB
// Log a line every 10% of the download and every 256 MiB of the
// extract/verify steps, so the next crash leaves the exact phase and
// byte count in engine.log.
static const uint64_t kLogEveryBytes = 256ULL << 20;

// Gunzip chunk: heap-allocated, never on the stack. The old code kept
// a 1 MiB array on the stack, but this runs on a GCD worker thread
// whose stack is 512 KiB on iOS: the first gzread touched the stack
// guard page and died with SIGBUS on every Install that reached
// extraction (the 09:33 and 07:57 runs). 256 KiB streams just as fast.
static const size_t kGunzipChunkBytes = 256 << 10;

static unsigned long long TXFreeSpaceAtPath(NSString* path) {
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:path error:nil];
    return [attrs[NSFileSystemFreeSize] unsignedLongLongValue];
}

static NSString* TXGuestDir(void) {
    NSArray* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [docs.firstObject stringByAppendingPathComponent:@"guest"];
}

static NSString* TXResumeDataPath(void) {
    return [TXGuestDir() stringByAppendingPathComponent:@"rootfs-download.resume"];
}

// Resume data is a plist the system wrote when a download was
// interrupted. It can go stale: the daemon temp file it names may
// be purged between runs, or the blob can be truncated. And
// downloadTaskWithResumeData: THROWS NSInvalidArgumentException on
// malformed data instead of returning nil — an unguarded call is an
// instant crash on every Install tap until the file is deleted.
// That is the regression: the previous build never wrote resume
// data, so it never hit this; this build writes it on every failure
// and cancel, so the very next Install can die in under a second.
// Validate first (lenient: a plist dictionary with a remote URL),
// and still catch, so a bad blob can only ever cost a fresh
// download, never a crash. The remote URL must also match the image
// this build downloads: a resume blob from the old full image (a
// different release URL) is stale by definition — resuming it would
// keep downloading the wrong image, which then fails the hash check.
// Such a blob is discarded and the download starts fresh.
static BOOL TXResumeDataIsUsable(NSData* data) {
    if (!data.length) return NO;
    NSError* error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:&error];
    if (![plist isKindOfClass:[NSDictionary class]]) return NO;
    NSString* remoteURL = plist[@"NSURLSessionResumeInfoRemoteURL"];
    if (![remoteURL isKindOfClass:[NSString class]] || !remoteURL.length) return NO;
    if (![remoteURL isEqualToString:kRootfsURL]) return NO;
    return YES;
}

// SHA-256 of a file, streaming in 1 MB chunks: memory stays flat no
// matter how big the file is. Logs a milestone every 256 MiB with the
// label, so a kill during the 1 GiB verify leaves its position.
static NSString* SHA256OfFile(NSString* path, NSString* label, NSError** outError) {
    NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        if (outError) *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        return nil;
    }
    unsigned long long total = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint64_t done = 0, lastLogged = 0;
    while (YES) {
        NSData* chunk = [handle readDataOfLength:1 << 20];
        if (chunk.length == 0) break;
        CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        done += chunk.length;
        if (done - lastLogged >= kLogEveryBytes || done >= total) {
            TXLogEngine(@"%@: %@ of %@", label, TXFormatBytes(done), TXFormatBytes(total));
            lastLogged = done;
        }
    }
    [handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static BOOL FileHasHash(NSString* path, NSString* expected, NSString* label) {
    NSError* error = nil;
    NSString* hash = SHA256OfFile(path, label, &error);
    return hash && [hash isEqualToString:expected];
}

// The install pipeline (hash, gunzip, verify) runs here, one at a
// time: two Install taps racing two gunzips at the same destination
// would truncate each other's output. The old global-queue dispatch
// allowed exactly that (the 07:57 log shows two pipelines
// interleaved). All callers dispatch_async onto this queue, never
// sync, so no caller can deadlock on it.
static dispatch_queue_t TXInstallPipelineQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("app.termx.ios.install-pipeline", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// TXRootfsDownload: one background download, owned for the process
// lifetime. It is the NSURLSessionDownloadDelegate, so progress,
// completion, resume data and the background wake-up all arrive here
// even when the app was killed and relaunched in the background: the
// pipeline (move, hash, extract, verify) runs without any UI attached,
// and the next foreground launch finds the guest installed.
@interface TXRootfsDownload : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession* session;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask* task;
@property (nonatomic, copy) NSString* rootfsPath;
@property (nonatomic, copy) NSString* gzPath;
@property (nonatomic, copy, nullable) void (^progress)(double, NSString*, int64_t, int64_t);
@property (nonatomic, copy, nullable) void (^completion)(BOOL, NSString*);
@property (nonatomic, copy, nullable) void (^backgroundCompletion)(void);
@property (nonatomic) int64_t received;
@property (nonatomic) int64_t expected;
@property (nonatomic) NSInteger lastLoggedPercent; // -1 until the first 10%
@property (nonatomic) BOOL cancelledByUser;
@property (nonatomic) NSInteger staleCancellationsPending; // cancels of tasks for the old image; their error callbacks are swallowed
@property (nonatomic) BOOL completionCalled;
@property (nonatomic) UIBackgroundTaskIdentifier pipelineBackgroundTask; // UIBackgroundTaskInvalid when none
@end

static TXRootfsDownload* s_activeDownload = nil;

@implementation TXRootfsDownload

+ (instancetype)active {
    // Thread-safe: installGuestTo: now starts on a background queue,
    // and the background-wake path calls this from the main thread,
    // so two threads can race the old nil check and create two
    // sessions with the same identifier (the second invalidates the
    // first, and its tasks die with it).
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_activeDownload = [[TXRootfsDownload alloc] init];
        NSURLSessionConfiguration* config =
            [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:kDownloadSessionIdentifier];
        config.allowsCellularAccess = YES;
        config.sessionSendsLaunchEvents = YES;
        s_activeDownload.session = [NSURLSession sessionWithConfiguration:config
                                                                 delegate:s_activeDownload
                                                            delegateQueue:nil];
        [[NSNotificationCenter defaultCenter] addObserver:s_activeDownload
                                                 selector:@selector(memoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    });
    return s_activeDownload;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)memoryWarning:(NSNotification*)note {
    (void)note;
    TXLogEngine(@"MEMORY WARNING during install: received %@ of %@, footprint %@",
                TXFormatBytes((unsigned long long)MAX(0, self.received)),
                TXFormatBytes((unsigned long long)MAX(0, self.expected)),
                TXFormatBytes(TXCurrentFootprintBytes()));
}

- (void)reportProgress:(double)f step:(NSString*)step {
    if (!self.progress) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progress) self.progress(f, step, self.received, self.expected);
    });
}

- (void)finish:(BOOL)ok error:(NSString*)error {
    if (self.completionCalled) return;
    self.completionCalled = YES;
    if (self.pipelineBackgroundTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.pipelineBackgroundTask];
        self.pipelineBackgroundTask = UIBackgroundTaskInvalid;
    }
    void (^completion)(BOOL, NSString*) = self.completion;
    self.task = nil;
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ok, error);
        });
    }
}

// The pipeline after the archive is on disk: hash it, extract it,
// hash the image, chmod it read-only. Runs on a background queue;
// every step logs, so a kill here leaves the exact phase.
- (void)runPipelineFromGz {
    NSString* gzPath = self.gzPath;
    NSString* rootfsPath = self.rootfsPath;
    NSFileManager* fm = [NSFileManager defaultManager];
    // The pipeline (hash 116 MB, gunzip to 1 GiB, hash 1 GiB) takes
    // longer than a background wake's budget. Without an assertion
    // the system kills the app mid-pipeline, leaving a partial image
    // and a fresh resume blob — the exact state that crashed the next
    // Install. The assertion is ended in finish:, the single funnel
    // every pipeline exit goes through.
    self.pipelineBackgroundTask =
        [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            TXLogEngine(@"Background time expired during install pipeline — the archive is kept, Install will reuse it");
        }];
    dispatch_async(TXInstallPipelineQueue(), ^{
        [self reportProgress:0.6 step:@"Verifying the download…"];
        if (!FileHasHash(gzPath, kRootfsGzSHA256, @"Verifying download")) {
            TXLogEngine(@"Download hash mismatch — archive discarded");
            [fm removeItemAtPath:gzPath error:nil];
            [self finish:NO error:@"download hash mismatch — the file may be corrupt, try again"];
            return;
        }
        TXLogEngine(@"Download hash OK");
        unsigned long long free = TXFreeSpaceAtPath(gzPath);
        if (free < kFreeSpaceNeededBeforeExtract) {
            TXLogEngine(@"Not enough free space to extract: %@ free, need %@",
                        TXFormatBytes(free), TXFormatBytes(kFreeSpaceNeededBeforeExtract));
            // Keep the verified archive: the user frees space and the
            // next Install reuses it instead of downloading again.
            [self finish:NO error:[NSString stringWithFormat:
                @"not enough free space — the install needs %@ free, this phone has %@",
                TXFormatBytes(kFreeSpaceNeededBeforeExtract), TXFormatBytes(free)]];
            return;
        }
        [self reportProgress:0.7 step:@"Extracting the image…"];
        // Pin the phase to disk before the long extract: the log is
        // async, and the progress line travels via the main queue, so
        // wait for the main queue to apply it and for the log queue
        // to write it. A crash a millisecond later must leave the
        // true phase, not the last line the queues happened to flush.
        dispatch_sync(dispatch_get_main_queue(), ^{ TXLogFlush(); });
        NSString* extractError = nil;
        if (![GuestInstall gunzipFile:gzPath to:rootfsPath error:&extractError]) {
            TXLogEngine(@"Extract failed: %@", extractError ?: @"?");
            [self finish:NO error:extractError];
            return;
        }
        [fm removeItemAtPath:gzPath error:nil];
        [fm removeItemAtPath:TXResumeDataPath() error:nil];
        [self reportProgress:0.95 step:@"Verifying the image…"];
        NSString* verifyError = nil;
        if (![GuestInstall guestInstalledAt:rootfsPath error:&verifyError]) {
            TXLogEngine(@"Image verification failed: %@", verifyError ?: @"?");
            [fm removeItemAtPath:rootfsPath error:nil];
            [self finish:NO error:verifyError ?: @"image verification failed"];
            return;
        }
        // The runtime requires a read-only image: no write bits at all.
        NSDictionary* attrs = @{NSFilePosixPermissions : @(0444)};
        [fm setAttributes:attrs ofItemAtPath:rootfsPath error:nil];
        TXLogEngine(@"Install complete: guest image verified");
        [self reportProgress:1.0 step:@"Guest ready"];
        [self finish:YES error:nil];
    });
}

- (void)startDownload {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* guestDir = [self.rootfsPath stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:guestDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* tmpDir = NSTemporaryDirectory();
    self.gzPath = [tmpDir stringByAppendingPathComponent:@"kterm-rootfs.ext4.gz"];
    [fm removeItemAtPath:self.rootfsPath error:nil];
    self.received = 0;
    self.expected = 0;
    self.lastLoggedPercent = -1;
    self.cancelledByUser = NO;
    self.completionCalled = NO;

    // An archive already on disk whose hash checks out is reused
    // instead of downloaded again: a kill during extraction used to
    // throw away 116 MB of good download and start from zero.
    if ([fm fileExistsAtPath:self.gzPath] &&
        FileHasHash(self.gzPath, kRootfsGzSHA256, @"Verifying download")) {
        TXLogEngine(@"Reusing the already-downloaded archive");
        [self runPipelineFromGz];
        return;
    }
    [fm removeItemAtPath:self.gzPath error:nil];

    unsigned long long free = TXFreeSpaceAtPath(self.rootfsPath);
    if (free < kFreeSpaceNeededBeforeDownload) {
        TXLogEngine(@"Not enough free space to install: %@ free, need %@",
                    TXFormatBytes(free), TXFormatBytes(kFreeSpaceNeededBeforeDownload));
        [self finish:NO error:[NSString stringWithFormat:
            @"not enough free space — the install needs %@ free, this phone has %@",
            TXFormatBytes(kFreeSpaceNeededBeforeDownload), TXFormatBytes(free)]];
        return;
    }

    NSData* resumeData = [NSData dataWithContentsOfFile:TXResumeDataPath()];
    if (resumeData.length > 0) {
        if (TXResumeDataIsUsable(resumeData)) {
            TXLogEngine(@"Resuming the download from saved resume data (%@)", TXFormatBytes(resumeData.length));
            @try {
                self.task = [self.session downloadTaskWithResumeData:resumeData];
            } @catch (NSException* exception) {
                // Stale resume data throws instead of returning nil.
                // Log it, drop the blob, and start fresh — never crash.
                TXLogEngine(@"Resume data threw %@: %@ — starting a fresh download",
                            exception.name ?: @"?", exception.reason ?: @"?");
                self.task = nil;
            }
        } else {
            TXLogEngine(@"Saved resume data failed validation — discarding it");
        }
        if (!self.task) {
            [fm removeItemAtPath:TXResumeDataPath() error:nil];
        }
    }
    if (!self.task) {
        NSURL* url = [NSURL URLWithString:kRootfsURL];
        TXLogEngine(@"Downloading guest image from %@", kRootfsURL);
        @try {
            self.task = [self.session downloadTaskWithURL:url];
        } @catch (NSException* exception) {
            TXLogEngine(@"Creating the download task threw %@: %@",
                        exception.name ?: @"?", exception.reason ?: @"?");
            [self finish:NO error:@"could not start the download — try again"];
            return;
        }
        if (!self.task) {
            TXLogEngine(@"Download task creation returned nil");
            [self finish:NO error:@"could not start the download — try again"];
            return;
        }
    }
    [self reportProgress:0.0 step:@"Downloading Debian image…"];
    [self.task resume];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession*)session
      downloadTask:(NSURLSessionDownloadTask*)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session; (void)downloadTask; (void)bytesWritten;
    self.received = totalBytesWritten;
    self.expected = totalBytesExpectedToWrite;
    if (totalBytesExpectedToWrite > 0) {
        double f = (double)totalBytesWritten / (double)totalBytesExpectedToWrite * 0.6;
        NSInteger pct = (NSInteger)((double)totalBytesWritten / (double)totalBytesExpectedToWrite * 100.0);
        if (pct >= self.lastLoggedPercent + 10) {
            self.lastLoggedPercent = (pct / 10) * 10;
            TXLogEngine(@"Download: %ld%% · %@ of %@ · footprint %@",
                        (long)pct,
                        TXFormatBytes((unsigned long long)totalBytesWritten),
                        TXFormatBytes((unsigned long long)totalBytesExpectedToWrite),
                        TXFormatBytes(TXCurrentFootprintBytes()));
        }
        [self reportProgress:f step:@"Downloading Debian image…"];
    }
}

- (void)URLSession:(NSURLSession*)session
      downloadTask:(NSURLSessionDownloadTask*)downloadTask
didFinishDownloadingToURL:(NSURL*)location {
    (void)session; (void)downloadTask;
    TXLogEngine(@"Download finished: %@ received", TXFormatBytes((unsigned long long)self.received));
    NSError* moveError = nil;
    BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:location
                                                          toURL:[NSURL fileURLWithPath:self.gzPath]
                                                          error:&moveError];
    if (!moved) {
        TXLogEngine(@"Could not save the download: %@", moveError.localizedDescription ?: @"?");
        [self finish:NO error:@"could not save the download"];
        return;
    }
    [self runPipelineFromGz];
}

- (void)URLSession:(NSURLSession*)session
              task:(NSURLSessionTask*)task
didCompleteWithError:(NSError*)error {
    (void)session; (void)task;
    if (self.staleCancellationsPending > 0) {
        // This error is the expected echo of cancelling a task that
        // belonged to the old image (see installGuestToOnQueue):
        // swallow it, do not finish the new install with an error.
        self.staleCancellationsPending--;
        TXLogEngine(@"Swallowed the error callback of a cancelled stale download task");
        return;
    }
    if (!error) return; // success is handled by didFinishDownloadingToURL
    NSData* resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
    if (resumeData.length > 0) {
        [resumeData writeToFile:TXResumeDataPath() atomically:YES];
        TXLogEngine(@"Saved resume data (%@) — the next Install continues from %@",
                    TXFormatBytes(resumeData.length),
                    TXFormatBytes((unsigned long long)self.received));
    }
    if (self.cancelledByUser) {
        TXLogEngine(@"Download cancelled by the user at %@ of %@",
                    TXFormatBytes((unsigned long long)MAX(0, self.received)),
                    TXFormatBytes((unsigned long long)MAX(0, self.expected)));
        [self finish:NO error:@"cancelled"];
        return;
    }
    TXLogEngine(@"Download failed at %@ of %@: %@",
                TXFormatBytes((unsigned long long)MAX(0, self.received)),
                TXFormatBytes((unsigned long long)MAX(0, self.expected)),
                error.localizedDescription ?: @"?");
    [self finish:NO error:@"download failed — check Wi-Fi and try again"];
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession*)session {
    (void)session;
    void (^handler)(void) = self.backgroundCompletion;
    self.backgroundCompletion = nil;
    if (handler) {
        TXLogEngine(@"Background download events delivered");
        handler();
    }
}

@end

@implementation GuestInstall

+ (BOOL)guestInstalledAt:(NSString*)rootfsPath error:(NSString**)error {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSDictionary* attrs = [fm attributesOfItemAtPath:rootfsPath error:nil];
    if (!attrs) {
        if (error) *error = @"guest image is not installed";
        return NO;
    }
    if (kRootfsSize > 0 && [attrs fileSize] != kRootfsSize) {
        if (error) *error = @"guest image has the wrong size — reinstall";
        return NO;
    }
    if (!FileHasHash(rootfsPath, kRootfsSHA256, @"Verifying image")) {
        if (error) *error = @"guest image hash mismatch — reinstall";
        return NO;
    }
    return YES;
}

// Streaming gunzip of src (.gz) to dst, in heap chunks: memory stays
// flat while 116 MB becomes 1 GiB. Logs every 256 MiB written, so a
// kill during extraction leaves its position. Returns NO with *error
// set on failure; the caller checks the hashes.
+ (BOOL)gunzipFile:(NSString*)src to:(NSString*)dst error:(NSString**)error {
    gzFile gz = gzopen(src.UTF8String, "rb");
    if (!gz) {
        if (error) *error = @"could not open the downloaded archive";
        return NO;
    }
    FILE* out = fopen(dst.UTF8String, "wb");
    if (!out) {
        gzclose(gz);
        if (error) *error = @"could not write the guest image";
        return NO;
    }
    // Heap, not stack: see kGunzipChunkBytes. A stack buffer here
    // overflowed the 512 KiB GCD worker thread stack and crashed
    // with SIGBUS on the first gzread.
    uint8_t* buffer = (uint8_t*)malloc(kGunzipChunkBytes);
    if (!buffer) {
        fclose(out);
        gzclose(gz);
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        if (error) *error = @"out of memory while extracting the image";
        return NO;
    }
    int n;
    BOOL ok = YES;
    uint64_t done = 0, lastLogged = 0;
    while ((n = gzread(gz, buffer, (unsigned)kGunzipChunkBytes)) > 0) {
        if (fwrite(buffer, 1, (size_t)n, out) != (size_t)n) { ok = NO; break; }
        done += (uint64_t)n;
        if (done - lastLogged >= kLogEveryBytes) {
            TXLogEngine(@"Extracting: %@ of %@", TXFormatBytes(done), TXFormatBytes((unsigned long long)kRootfsSize));
            lastLogged = done;
        }
    }
    if (n < 0) ok = NO;
    free(buffer);
    fclose(out);
    gzclose(gz);
    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        if (error) *error = @"the downloaded archive is corrupt";
    }
    return ok;
}

+ (void)installGuestTo:(NSString*)rootfsPath
              progress:(void (^)(double, NSString*, int64_t, int64_t))progress
            completion:(void (^)(BOOL, NSString*))completion {
    // The installed check below can SHA-256 a 1 GiB image: never on
    // the main thread. The whole start runs on a background queue;
    // progress/completion hop to the main queue themselves.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self installGuestToOnQueue:rootfsPath progress:progress completion:completion];
    });
}

+ (void)installGuestToOnQueue:(NSString*)rootfsPath
                     progress:(void (^)(double, NSString*, int64_t, int64_t))progress
                   completion:(void (^)(BOOL, NSString*))completion {
    NSString* error = nil;
    if ([self guestInstalledAt:rootfsPath error:&error]) {
        TXLogEngine(@"Install skipped: guest image already verified");
        if (completion) completion(YES, nil);
        return;
    }
    TXRootfsDownload* download = [TXRootfsDownload active];
    // A download is already in flight (e.g. the app was relaunched
    // while the background session was running): attach the new
    // progress/completion blocks to it instead of starting a second.
    // But only if it is downloading THIS image: a task left over from
    // the old full image must be dropped, or it would keep fetching
    // 368 MB that then fails the slim hash check.
    if (download.task && download.task.state == NSURLSessionTaskStateRunning) {
        if (![download.task.originalRequest.URL.absoluteString isEqualToString:kRootfsURL]) {
            TXLogEngine(@"In-flight download is for the old image — cancelling it and starting fresh");
            download.staleCancellationsPending++;
            [download.task cancel];
            download.task = nil;
        } else {
            TXLogEngine(@"Install attached to the download already in flight");
            download.progress = progress;
            download.completion = completion;
            download.completionCalled = NO;
            [download reportProgress:0.0 step:@"Downloading Debian image…"];
            return;
        }
    }
    // No live task: the background session may still hold one (the
    // app was killed and relaunched). Ask the session; a found task
    // for THIS image is the same download, re-attached, not a new
    // one. Tasks for the old image are cancelled the same way.
    download.rootfsPath = rootfsPath;
    download.progress = progress;
    download.completion = completion;
    [download.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask*>* dataTasks,
                                                      NSArray<NSURLSessionUploadTask*>* uploadTasks,
                                                      NSArray<NSURLSessionDownloadTask*>* downloadTasks) {
        (void)dataTasks; (void)uploadTasks;
        NSURLSessionDownloadTask* matching = nil;
        for (NSURLSessionDownloadTask* t in downloadTasks) {
            if ([t.originalRequest.URL.absoluteString isEqualToString:kRootfsURL]) {
                if (!matching) matching = t;
                continue;
            }
            // Already being cancelled: counted once already, do not
            // count it twice or a later genuine error gets swallowed.
            if (t.state != NSURLSessionTaskStateCanceling) {
                download.staleCancellationsPending++;
                [t cancel];
            }
        }
        if (matching) {
            TXLogEngine(@"Re-attached to a background download task already running");
            download.task = matching;
            download.received = matching.countOfBytesReceived;
            download.expected = matching.countOfBytesExpectedToReceive;
            [download reportProgress:0.0 step:@"Downloading Debian image…"];
            return;
        }
        [download startDownload];
    }];
}

+ (void)cancelDownload {
    TXRootfsDownload* download = s_activeDownload;
    if (!download || !download.task) return;
    download.cancelledByUser = YES;
    TXLogEngine(@"Download cancel requested at %@ received",
                TXFormatBytes((unsigned long long)MAX(0, download.received)));
    [download.task cancelByProducingResumeData:^(NSData* resumeData) {
        if (resumeData.length > 0) {
            [resumeData writeToFile:TXResumeDataPath() atomically:YES];
            TXLogEngine(@"Saved resume data on cancel (%@)", TXFormatBytes(resumeData.length));
        }
    }];
}

+ (void)reconnectBackgroundSessionWithCompletionHandler:(void (^)(void))handler {
    TXRootfsDownload* download = [TXRootfsDownload active];
    download.backgroundCompletion = handler;
    // Re-creating the session with the same identifier re-attaches
    // the pending background tasks; their delegate callbacks (finish,
    // error, didFinishEvents) then arrive on this object.
    TXLogEngine(@"Reconnected the background download session");
}

@end
