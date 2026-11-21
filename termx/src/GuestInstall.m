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
@end

// Guest image: Debian trixie arm64, built 2026-11-20 (see rootfs-build/).
// The .ext4.gz must be published at kRootfsURL before first use from the app;
// the app refuses an image whose hash does not match.
//
// NOTE: these four constants are the FULL image. The slim minimal image
// (release rootfs-20261121-slim) is being published separately; when it
// lands, only these four lines change to point at it. Nothing else in
// this file hardcodes an image size or hash.
NSString* const kRootfsURL =
    @"https://github.com/spyboi-dev/termx/releases/download/rootfs-20261120/termx-debian-trixie-arm64.ext4.gz";
NSString* const kRootfsName = @"termx-debian-trixie-arm64.ext4";
NSString* const kRootfsGzSHA256 = @"7bc05dcf82a48d7b1f04413c2d3a8c3cafa5ea4450cc2284b82725e7aba79676";
NSString* const kRootfsSHA256 = @"a11e2dd31cce3ab20630b48ff288586b9cc6691a7cf1992ff7d0193b00ba2f14";
const long long kRootfsSize = 1728053248; // extracted image size in bytes (1,648 MiB)

// Background session: one identifier for the process lifetime, so a
// download survives the phone locking, the app suspending, and the app
// being killed, and the system can wake the app when it finishes.
static NSString* const kDownloadSessionIdentifier = @"app.termx.ios.rootfs-download";

// The .gz download is ~368 MB and the extracted image ~1.6 GB. The
// install needs both alive at once, plus headroom for the OS, so refuse
// to start (or to extract) when the phone is too full, with the numbers
// in the error, instead of dying halfway through with ENOSPC.
static const unsigned long long kFreeSpaceNeededBeforeDownload = 3ULL << 30; // 3 GiB
static const unsigned long long kFreeSpaceNeededBeforeExtract = 2ULL << 30;  // 2 GiB
// Log a line every 10% of the download and every 256 MiB of the
// extract/verify steps, so the next crash leaves the exact phase and
// byte count in engine.log.
static const uint64_t kLogEveryBytes = 256ULL << 20;

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

// SHA-256 of a file, streaming in 1 MB chunks: memory stays flat no
// matter how big the file is. Logs a milestone every 256 MiB with the
// label, so a kill during the 1.6 GB verify leaves its position.
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
@property (nonatomic) BOOL completionCalled;
@end

static TXRootfsDownload* s_activeDownload = nil;

@implementation TXRootfsDownload

+ (instancetype)active {
    if (!s_activeDownload) {
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
    }
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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
    // throw away 368 MB of good download and start from zero.
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
        TXLogEngine(@"Resuming the download from saved resume data (%@)", TXFormatBytes(resumeData.length));
        self.task = [self.session downloadTaskWithResumeData:resumeData];
        if (!self.task) {
            TXLogEngine(@"Resume data was unusable — starting a fresh download");
            [fm removeItemAtPath:TXResumeDataPath() error:nil];
        }
    }
    if (!self.task) {
        NSURL* url = [NSURL URLWithString:kRootfsURL];
        TXLogEngine(@"Downloading guest image from %@", kRootfsURL);
        self.task = [self.session downloadTaskWithURL:url];
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

// Streaming gunzip of src (.gz) to dst, in 1 MB chunks: memory stays
// flat while 368 MB becomes 1.6 GB. Logs every 256 MiB written, so a
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
    uint8_t buffer[1 << 20];
    int n;
    BOOL ok = YES;
    uint64_t done = 0, lastLogged = 0;
    while ((n = gzread(gz, buffer, (unsigned)sizeof(buffer))) > 0) {
        if (fwrite(buffer, 1, (size_t)n, out) != (size_t)n) { ok = NO; break; }
        done += (uint64_t)n;
        if (done - lastLogged >= kLogEveryBytes) {
            TXLogEngine(@"Extracting: %@ of %@", TXFormatBytes(done), TXFormatBytes((unsigned long long)kRootfsSize));
            lastLogged = done;
        }
    }
    if (n < 0) ok = NO;
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
    if (download.task && download.task.state == NSURLSessionTaskStateRunning) {
        TXLogEngine(@"Install attached to the download already in flight");
        download.progress = progress;
        download.completion = completion;
        download.completionCalled = NO;
        [download reportProgress:0.0 step:@"Downloading Debian image…"];
        return;
    }
    // No live task: the background session may still hold one (the
    // app was killed and relaunched). Ask the session; a found task
    // is the same download, re-attached, not a new one.
    download.rootfsPath = rootfsPath;
    download.progress = progress;
    download.completion = completion;
    [download.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask*>* dataTasks,
                                                      NSArray<NSURLSessionUploadTask*>* uploadTasks,
                                                      NSArray<NSURLSessionDownloadTask*>* downloadTasks) {
        (void)dataTasks; (void)uploadTasks;
        if (downloadTasks.count > 0) {
            NSURLSessionDownloadTask* existing = downloadTasks.firstObject;
            TXLogEngine(@"Re-attached to a background download task already running");
            download.task = existing;
            download.received = existing.countOfBytesReceived;
            download.expected = existing.countOfBytesExpectedToReceive;
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
