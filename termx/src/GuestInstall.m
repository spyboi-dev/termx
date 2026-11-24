// SPDX-License-Identifier: GPL-2.0-or-later
#import "GuestInstall.h"
#import "TXConfig.h"
#import "TXLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h> // UIApplicationDidReceiveMemoryWarningNotification
#import <errno.h> // ENOSPC, for the disk-full download error
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
// One-time full-hash verify of the extracted image (pipeline only);
// the fingerprint helpers behind the cheap guestInstalledAt check.
+ (BOOL)guestImageHashValidAt:(NSString*)rootfsPath error:(NSString**)error;
+ (NSDictionary*)verifiedRootfsFingerprint;
+ (BOOL)verifiedFingerprintMatchesPath:(NSString*)path attrs:(NSDictionary*)attrs;
+ (void)recordVerifiedFingerprintForPath:(NSString*)path attrs:(NSDictionary*)attrs hash:(NSString*)hash;
// Cheap: the ext4 superblock magic (0xEF53 at offset 1080), so a
// read-only image with no fingerprint can still prove it is a real
// filesystem without a 1 GiB hash.
+ (BOOL)imageLooksLikeExt4At:(NSString*)path;
@end

// Guest image: Debian trixie arm64 MINIMAL (slim), built 2026-11-24
// (fix6; see rootfs-build/build-rootfs-slim.sh). Boots to a shell with working
// apt and networking; users apt-install what they need. The .ext4.gz must
// be published at kRootfsURL before first use from the app; the app
// refuses an image whose hash does not match.
//
// NOTE: these four constants are the SLIM image (release
// rootfs-20261124-slim-fix6). The local filename kRootfsName is deliberately
// UNCHANGED from the old full image: the slim image replaces the full
// one at the same path. A phone holding an older image does NOT fail:
// a version difference is an update, not corruption — the installed
// image boots as-is (see guestInstalledAt:) and the new one is
// offered as an Update. Only a genuinely damaged image (wrong size,
// not ext4, or a fresh download that fails its hash) asks for a
// reinstall. The persistent data disk (termx-data.ext4) is a separate
// file and is never touched by the image switch.
NSString* const kRootfsURL =
    @"https://github.com/spyboi-dev/termx/releases/download/rootfs-20261124-slim-fix6/termx-debian-trixie-arm64-slim.ext4.gz";
NSString* const kRootfsName = @"termx-debian-trixie-arm64.ext4";
NSString* const kRootfsGzSHA256 = @"417011127ba253532a8339cade70a7723d6135707b71a6a08cfeb7b25c430025";
NSString* const kRootfsSHA256 = @"995940f8690a338752730b89ff5bfedd28d4af320b89651b9fd9c872e7912a0a";
const long long kRootfsSize = 1073741824; // extracted image size in bytes (exactly 1 GiB)

// Background session: one identifier for the process lifetime, so a
// download survives the phone locking, the app suspending, and the app
// being killed, and the system can wake the app when it finishes.
static NSString* const kDownloadSessionIdentifier = @"app.termx.ios.rootfs-download";

// The .gz download is ~116 MB and the extracted image exactly 1 GiB. The
// install needs both alive at once, plus headroom for the OS, so refuse
// to start (or to extract) when the phone is too full, with the numbers
// in the error, instead of dying halfway through with ENOSPC.
// Thresholds in TXConfig.h.
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

// Free space on the volume holding path. attributesOfFileSystemForPath:
// returns nil when the path does not exist, and a nil value reads as 0 —
// which used to fail every Install: startDownload deletes the image
// file, then measured that deleted path and read 0 B free (the 10:21
// run: five taps, "0 B free, need 1.0 GiB" every time). Callers must pass
// a path that exists. And a measurement that cannot be taken must never
// block a good install: log it and fail OPEN (the OS still fails
// honestly with ENOSPC if the disk really is full).
static unsigned long long TXFreeSpaceAtPath(NSString* path) {
    NSError* error = nil;
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:path error:&error];
    NSNumber* freeSize = attrs[NSFileSystemFreeSize];
    if (!freeSize) {
        TXLogEngine(@"Free-space check failed for %@: %@ — proceeding without the check",
                    path, error.localizedDescription ?: @"no attributes returned");
        return ~0ULL;
    }
    return [freeSize unsignedLongLongValue];
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

// Disk-full, anywhere in the error chain: an NSURLSession failure
// can carry ENOSPC as an NSPOSIXErrorDomain code, or as
// NSFileWriteOutOfSpaceError in the Cocoa domain, on the error
// itself or on its underlying error. A full disk is not a Wi-Fi
// problem, and the old generic "check Wi-Fi" message sent the user
// to the wrong fix.
static BOOL TXErrorIsOutOfSpace(NSError* error) {
    for (NSError* e = error; e; e = e.userInfo[NSUnderlyingErrorKey]) {
        if (![e isKindOfClass:[NSError class]]) break;
        if ([e.domain isEqualToString:NSPOSIXErrorDomain] && e.code == ENOSPC) return YES;
        if ([e.domain isEqualToString:NSCocoaErrorDomain] && e.code == NSFileWriteOutOfSpaceError) return YES;
    }
    return NO;
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

// The swap lock: the image swap's renames (live -> .old, .new ->
// live, delete .old) and the interrupted-swap recovery
// (recoverInterruptedSwapAt:) both touch the live path and .old,
// and the startup screen polls guestInstalledAt twice a second —
// including while an install is in flight. Without this lock a poll
// landing in the millisecond window between the two renames could
// restore .old to the live path while the swap is still moving .new
// in, and the swap would fail spuriously. The lock is held only for
// the renames themselves (milliseconds; the gunzip and the hashes
// run outside it), so the poll never waits on slow work.
static NSLock* TXImageSwapLock(void) {
    static NSLock* lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

// Swap a verified .new image into the live path, atomically in the
// only sense a filesystem swap can be: the live image is moved aside
// to .old FIRST, then the verified .new is moved into the live path,
// then .old is deleted — and the verified archive is deleted with it.
// A kill at any point leaves either the old image (live, or in .old)
// or the new one, never nothing; the recovery in
// recoverInterruptedSwapAt: puts a stranded .old back. Returns nil
// on success, or a user-facing error string. On failure the old image
// is restored to the live path when one was set aside, so the guest
// still boots.
static NSString* TXSwapVerifiedImageIntoPlace(NSString* newPath, NSString* rootfsPath, NSString* gzPath) {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* oldPath = [rootfsPath stringByAppendingString:@".old"];
    [TXImageSwapLock() lock];
    BOOL liveExists = [fm fileExistsAtPath:rootfsPath];
    NSError* swapError = nil;
    if (liveExists) {
        // A stale .old from an earlier killed swap is superseded by
        // the live image about to be set aside: drop it first.
        [fm removeItemAtPath:oldPath error:nil];
        if (![fm moveItemAtPath:rootfsPath toPath:oldPath error:&swapError]) {
            [TXImageSwapLock() unlock];
            TXLogEngine(@"Image swap failed moving the old image aside: %@", swapError.localizedDescription ?: @"?");
            [fm removeItemAtPath:newPath error:nil];
            return @"could not install the new image — the old image is still in place";
        }
    } else if ([fm fileExistsAtPath:oldPath]) {
        // No live image, but the backup from an interrupted earlier
        // swap is here: the verified new image takes the live path
        // below and .old is dropped with it.
        TXLogEngine(@"Image swap: no live image — the previous swap was interrupted; the verified new image supersedes the .old backup");
    }
    if (![fm moveItemAtPath:newPath toPath:rootfsPath error:&swapError]) {
        TXLogEngine(@"Image swap failed moving the new image in: %@", swapError.localizedDescription ?: @"?");
        // The old image was set aside above: put it back, so the
        // guest still boots. If the restore itself fails, the .old
        // stays and the next installed check recovers it.
        if (liveExists) {
            NSError* restoreError = nil;
            if ([fm moveItemAtPath:oldPath toPath:rootfsPath error:&restoreError]) {
                TXLogEngine(@"Image swap: old image restored after the failed swap");
            } else {
                TXLogEngine(@"Image swap: could not restore the old image: %@", restoreError.localizedDescription ?: @"?");
            }
        }
        [TXImageSwapLock() unlock];
        [fm removeItemAtPath:newPath error:nil];
        return @"could not install the new image — the old image is still in place";
    }
    [fm removeItemAtPath:oldPath error:nil];
    [fm removeItemAtPath:gzPath error:nil];
    [TXImageSwapLock() unlock];
    return nil;
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
            TXLogEngine(@"Download failed its hash check — archive discarded");
            [fm removeItemAtPath:gzPath error:nil];
            [self finish:NO error:@"the download is damaged — try again"];
            return;
        }
        TXLogEngine(@"Download hash OK");
        // Extract to a side file, not the live image: the installed
        // image keeps booting until the new one is verified, and a
        // failed update leaves it untouched instead of deleting a
        // working image and failing halfway (the 2026-11-23 lesson:
        // an update must never brick a setup that already works).
        // A stale .new from a killed earlier pipeline is removed
        // first, before the free-space check below, so the check
        // counts the up-to-1 GiB it frees instead of failing on
        // space the stale file is sitting on.
        NSString* newPath = [rootfsPath stringByAppendingString:@".new"];
        [fm removeItemAtPath:newPath error:nil];
        // gzPath provably exists here: it was just hashed above (or the
        // download delegate just moved the file there), so this read is
        // real — and the helper fails open if the measurement ever fails.
        unsigned long long free = TXFreeSpaceAtPath(gzPath);
        if (free < TXConfigFreeSpaceNeededBeforeExtractBytes) {
            TXLogEngine(@"Not enough free space to extract: %@ free, need %@",
                        TXFormatBytes(free), TXFormatBytes(TXConfigFreeSpaceNeededBeforeExtractBytes));
            // Keep the verified archive: the user frees space and the
            // next Install reuses it instead of downloading again.
            [self finish:NO error:[NSString stringWithFormat:
                @"not enough free space — the install needs %@ free, this phone has %@",
                TXFormatBytes(TXConfigFreeSpaceNeededBeforeExtractBytes), TXFormatBytes(free)]];
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
        if (![GuestInstall gunzipFile:gzPath to:newPath error:&extractError]) {
            TXLogEngine(@"Extract failed: %@", extractError ?: @"?");
            [self finish:NO error:extractError];
            return;
        }
        // The archive is NOT deleted here any more: it stays until
        // the swap below succeeds, so a kill anywhere before that
        // leaves a verified archive the next Install reuses instead
        // of re-downloading 116 MB. It is deleted with the .old
        // after a successful swap.
        [fm removeItemAtPath:TXResumeDataPath() error:nil];
        [self reportProgress:0.95 step:@"Verifying the image…"];
        NSString* verifyError = nil;
        // The pipeline's own one-time verify, not guestInstalledAt:
        // the just-extracted file still carries write bits until the
        // chmod below, and guestInstalledAt treats that as unverified.
        if (![GuestInstall guestImageHashValidAt:newPath error:&verifyError]) {
            TXLogEngine(@"Image verification failed: %@ — the verified archive is kept, the next Install re-extracts it instead of downloading again", verifyError ?: @"?");
            [fm removeItemAtPath:newPath error:nil];
            [self finish:NO error:verifyError ?: @"image verification failed"];
            return;
        }
        // The runtime requires a read-only image: no write bits at all.
        NSDictionary* attrs = @{NSFilePosixPermissions : @(0444)};
        [fm setAttributes:attrs ofItemAtPath:newPath error:nil];
        // Swap only now that the new image is verified (see
        // TXSwapVerifiedImageIntoPlace): the live image is moved
        // aside to .old first, then the verified .new is moved into
        // the live path, then .old is deleted. The old code removed
        // the live image and then moved .new in: a kill between the
        // two left NO image at all, and since the .gz was already
        // deleted the only recovery was a full re-download. Now a
        // kill at any point leaves either the old image (live, or in
        // .old) or the new one — never nothing. The fingerprint was
        // recorded for the .new path by the verify above; re-record
        // it for the final path with the known-good hash, so the
        // cheap installed check answers from it from now on.
        NSString* swapError = TXSwapVerifiedImageIntoPlace(newPath, rootfsPath, gzPath);
        if (swapError) {
            [self finish:NO error:swapError];
            return;
        }
        NSDictionary* finalAttrs = [fm attributesOfItemAtPath:rootfsPath error:nil];
        if (finalAttrs) [GuestInstall recordVerifiedFingerprintForPath:rootfsPath attrs:finalAttrs hash:kRootfsSHA256];
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
    // The installed image is NOT deleted here: the pipeline extracts
    // to a side file and swaps it in only after the new image is
    // verified, so a failed or cancelled update leaves the working
    // image in place (see runPipelineFromGz).
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

    // Measure the guest directory, which was just created above — never
    // the image file: it was deleted a few lines up, and measuring a
    // deleted path always reads 0 B free (every Install failed on it).
    unsigned long long free = TXFreeSpaceAtPath(guestDir);
    if (free < TXConfigFreeSpaceNeededBeforeDownloadBytes) {
        TXLogEngine(@"Not enough free space to install: %@ free, need %@",
                    TXFormatBytes(free), TXFormatBytes(TXConfigFreeSpaceNeededBeforeDownloadBytes));
        [self finish:NO error:[NSString stringWithFormat:
            @"not enough free space — the install needs %@ free, this phone has %@",
            TXFormatBytes(TXConfigFreeSpaceNeededBeforeDownloadBytes), TXFormatBytes(free)]];
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
    if (TXErrorIsOutOfSpace(error)) {
        TXLogEngine(@"Download failed: out of space at %@ of %@",
                    TXFormatBytes((unsigned long long)MAX(0, self.received)),
                    TXFormatBytes((unsigned long long)MAX(0, self.expected)));
        [self finish:NO error:@"the phone ran out of free space while downloading — free some space and try again"];
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

// Verified-image fingerprint: once the install pipeline has SHA-256'd
// the extracted image, the verdict is remembered in NSUserDefaults as
// the file's path, size, modification date AND the hash it verified
// as. guestInstalledAt — called on the startup screen's 0.5 s poll
// timer — then answers from that fingerprint with a stat call,
// instead of re-hashing 1 GiB every tick (which is what looped
// "Verifying image" once a second forever after the 10:30 install).
// The fingerprint only counts for the exact file it was recorded
// for: any size or mtime change voids it. The recorded hash is what
// tells an older release from the current one without hashing: a
// fingerprint hash that differs from kRootfsSHA256 means the image
// is an older release — an update is available, not a failure.
// Fingerprints recorded before the hash field existed (older builds)
// carry no hash; the launch update check settles those with one
// full hash and the fingerprint is then re-recorded with it.
static NSString* const kVerifiedRootfsKey = @"app.termx.ios.verified-rootfs";

@implementation GuestInstall

+ (NSDictionary*)verifiedRootfsFingerprint {
    id fp = [[NSUserDefaults standardUserDefaults] objectForKey:kVerifiedRootfsKey];
    return [fp isKindOfClass:[NSDictionary class]] ? fp : nil;
}

+ (BOOL)verifiedFingerprintMatchesPath:(NSString*)path attrs:(NSDictionary*)attrs {
    NSDictionary* fp = [self verifiedRootfsFingerprint];
    if (!fp) return NO;
    if (![fp[@"path"] isEqualToString:path]) return NO;
    if ([fp[@"size"] unsignedLongLongValue] != [attrs fileSize]) return NO;
    NSDate* mtime = fp[@"mtime"];
    if (![mtime isKindOfClass:[NSDate class]]) return NO;
    return [mtime isEqualToDate:[attrs fileModificationDate]];
}

+ (void)recordVerifiedFingerprintForPath:(NSString*)path attrs:(NSDictionary*)attrs hash:(NSString*)hash {
    NSMutableDictionary* fp = [NSMutableDictionary dictionaryWithDictionary:
        @{@"path": path,
          @"size": @([attrs fileSize]),
          @"mtime": [attrs fileModificationDate]}];
    if ([hash isKindOfClass:[NSString class]] && hash.length) fp[@"sha256"] = hash;
    [[NSUserDefaults standardUserDefaults] setObject:fp forKey:kVerifiedRootfsKey];
}

// The hash this exact file was verified as, from its fingerprint —
// or nil when no fingerprint (or no hash field in it) answers for
// this file. Cheap: a stat plus a defaults read, never a hash.
+ (NSString*)installedImageVerifiedHashAt:(NSString*)rootfsPath {
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:rootfsPath error:nil];
    if (!attrs) return nil;
    if (![self verifiedFingerprintMatchesPath:rootfsPath attrs:attrs]) return nil;
    NSString* hash = [self verifiedRootfsFingerprint][@"sha256"];
    return [hash isKindOfClass:[NSString class]] ? hash : nil;
}

// Cheap: is the installed image already this build's release? Only
// the fingerprint's recorded hash can answer without hashing 1 GiB.
+ (BOOL)installedImageIsCurrentReleaseAt:(NSString*)rootfsPath {
    NSString* hash = [self installedImageVerifiedHashAt:rootfsPath];
    return hash != nil && [hash isEqualToString:kRootfsSHA256];
}

// The release tag this build installs, parsed out of kRootfsURL
// (.../releases/download/<tag>/termx-....ext4.gz) — the one copy of
// the tag, not a second hardcoded string. Falls back to the generic
// name if the URL ever stops carrying a tag.
+ (NSString*)rootfsReleaseTag {
    NSArray<NSString*>* parts = [kRootfsURL componentsSeparatedByString:@"/"];
    NSUInteger idx = [parts indexOfObject:@"download"];
    if (idx != NSNotFound && idx + 1 < parts.count) {
        NSString* tag = parts[idx + 1];
        if (tag.length) return tag;
    }
    return @"trixie slim";
}

// Recover a swap interrupted by a kill: the swap moves the live
// image to .old before moving the verified .new in, so a kill
// between the two leaves no live image but a working one in .old.
// Under the swap lock (so this can never race a swap in flight —
// the startup screen polls guestInstalledAt twice a second,
// including during an install): if the live path is empty and .old
// exists, move .old back; if the live image is in place and a .old
// sits beside it, the .old is from a swap that already went live,
// so drop it instead of wasting 1 GiB. Synchronous and cheap (a
// stat and at most one rename): guestInstalledAt must be able to
// answer from the restored image on the same call, or a launch
// after a killed swap would sit at Idle until the next poll.
+ (void)recoverInterruptedSwapAt:(NSString*)rootfsPath {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* oldPath = [rootfsPath stringByAppendingString:@".old"];
    [TXImageSwapLock() lock];
    if ([fm fileExistsAtPath:rootfsPath]) {
        if ([fm fileExistsAtPath:oldPath]) {
            NSError* error = nil;
            if ([fm removeItemAtPath:oldPath error:&error]) {
                TXLogEngine(@"Removed the stale .old image left by an interrupted swap");
            } else {
                TXLogEngine(@"Could not remove the stale .old image: %@", error.localizedDescription ?: @"?");
            }
        }
        [TXImageSwapLock() unlock];
        return;
    }
    if (![fm fileExistsAtPath:oldPath]) {
        [TXImageSwapLock() unlock];
        return;
    }
    NSError* error = nil;
    if ([fm moveItemAtPath:oldPath toPath:rootfsPath error:&error]) {
        TXLogEngine(@"Recovered the guest image from .old after an interrupted swap — the guest boots on the previous image");
    } else {
        TXLogEngine(@"Could not recover the guest image from .old: %@", error.localizedDescription ?: @"?");
    }
    [TXImageSwapLock() unlock];
}

// The ext4 superblock magic 0xEF53 at offset 1080 (1024-byte boot
// sector + 56 bytes into the superblock), little-endian. A two-byte
// pread: the cheap proof a read-only image with no fingerprint is a
// real ext4 filesystem, not a truncated or foreign file.
+ (BOOL)imageLooksLikeExt4At:(NSString*)path {
    NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return NO;
    @try {
        [handle seekToFileOffset:1080];
        NSData* magic = [handle readDataOfLength:2];
        [handle closeFile];
        if (magic.length != 2) return NO;
        const uint8_t* b = (const uint8_t*)magic.bytes;
        return b[0] == 0x53 && b[1] == 0xEF;
    } @catch (NSException* exception) {
        return NO;
    }
}

// The pipeline's one-time verify: full SHA-256 of the extracted
// image, run once after extraction. On success the fingerprint is
// recorded (with the hash), so every later guestInstalledAt call is
// a stat. A failure here is a genuinely damaged fresh download, so
// the error says damaged: a version difference is not corruption,
// and this function only ever runs against the file the pipeline
// just extracted for this release.
+ (BOOL)guestImageHashValidAt:(NSString*)rootfsPath error:(NSString**)error {
    NSError* hashError = nil;
    NSString* hash = SHA256OfFile(rootfsPath, @"Verifying image", &hashError);
    if (!hash || ![hash isEqualToString:kRootfsSHA256]) {
        if (error) *error = @"the guest image is damaged — reinstall";
        return NO;
    }
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:rootfsPath error:nil];
    if (attrs) [self recordVerifiedFingerprintForPath:rootfsPath attrs:attrs hash:hash];
    return YES;
}

// Cheap by design: exists + size, then the recorded fingerprint
// or the ext4 magic (whatever the permission bits). NEVER a hash
// here — this runs on the startup screen's 0.5 s poll timer and on
// engine init, and a full SHA-256 of 1 GiB on every tick is the
// "Verifying image" loop. The only full hashes are the pipeline's
// one-time verify (guestImageHashValidAt:) and the launch update
// check, which runs once on a background queue and never blocks
// booting.
// A version difference is NOT a failure: an older release that is
// a valid ext4 image boots exactly like the current one, and the
// update is offered separately. Only a file that cannot be a guest
// image at all — wrong size, or not ext4 — is damaged.
// Size and filesystem are checked before the permission bits: a
// right-size ext4 image is a valid guest image whatever its bits
// are — an iCloud restore, for example, resets them to 0644, and
// the pre-flight chmods them back to 0444 before booting — so
// rejecting it here would only force a needless 116 MB reinstall.
+ (BOOL)guestInstalledAt:(NSString*)rootfsPath error:(NSString**)error {
    // First, heal an interrupted swap (see recoverInterruptedSwapAt:):
    // a kill mid-swap leaves no live image but a working one in .old,
    // and every consumer of this check — engine init, the startup
    // screen's poll, the boot pre-flight — must see the restored
    // image, not "not installed".
    [self recoverInterruptedSwapAt:rootfsPath];
    NSFileManager* fm = [NSFileManager defaultManager];
    NSDictionary* attrs = [fm attributesOfItemAtPath:rootfsPath error:nil];
    if (!attrs) {
        if (error) *error = @"guest image is not installed";
        return NO;
    }
    if (kRootfsSize > 0 && [attrs fileSize] != kRootfsSize) {
        if (error) *error = @"guest image is damaged (wrong size) — reinstall";
        return NO;
    }
    // This exact file was already hash-verified: the verdict stands,
    // whatever release it was verified as.
    if ([self verifiedFingerprintMatchesPath:rootfsPath attrs:attrs]) return YES;
    // Read-only, no fingerprint: an image installed by an older
    // build, or an older release. If it is a real ext4 image it
    // boots, whatever its permission bits are; only a file that is
    // not ext4 at all is damaged.
    if ([self imageLooksLikeExt4At:rootfsPath]) return YES;
    // Not ext4: a half-extracted file still carries write bits, so
    // it is not installed — and hashing it would only waste a second.
    if ([attrs filePosixPermissions] & 0222) {
        if (error) *error = @"guest image is not verified — reinstall";
        return NO;
    }
    if (error) *error = @"guest image is damaged — reinstall";
    return NO;
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
    // Heal an interrupted swap first: after a killed swap the live
    // image may be sitting in .old, and the skip check below answers
    // from the live path — without the recovery it would see no
    // current image and re-download a release the phone already has.
    [self recoverInterruptedSwapAt:rootfsPath];
    // Skip only when the installed image is already this build's
    // release. An older valid image is NOT skipped: Install (and
    // Update) means "get the current image", and the pipeline swaps
    // it in only after the new one verifies.
    if ([self installedImageIsCurrentReleaseAt:rootfsPath]) {
        TXLogEngine(@"Install skipped: guest image is already the current release");
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
