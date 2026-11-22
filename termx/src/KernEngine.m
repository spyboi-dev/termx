// SPDX-License-Identifier: GPL-2.0-or-later
#import "KernEngine.h"
#import "KernariumRuntime.h"
#import "GuestInstall.h"
#import "TXBootPathCheck.h"
#import "TXLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>

NSString* const kTermXStateChanged = @"TermXStateChanged";

// The Linux guest: 1024 MiB RAM and 2 vCPUs are plenty for a shell, and
// leave the process headroom the runtime's GPU budget wants.
static const uint32_t kGuestMemoryMiB = 1024;
static const uint32_t kGuestCPUs = 2;
// The guest's persistent data disk, in GiB: one sparse file at a fixed
// path (see dataDiskPath), created once and reused on every boot, so
// the 8 GiB is capacity, not allocated size — the file only grows as
// the guest writes, like Andarium's "628 MiB of 8 GiB".
static const uint64_t kDataDiskGiB = 8;

@interface KernEngine () {
    const kernarium_runtime_api* _api;
    void* _runtimeHandle; // dlopen handle; held for the process lifetime
    BOOL _running;
    // Held for the whole run: the boot struct hands the runtime C strings,
    // and they must stay alive until run() returns. All four are __strong
    // (verified: no weak/assign anywhere) — the paths are built once in
    // init, the session record once per boot in the pre-flight, and
    // nothing reassigns them while a run is in flight.
    __strong NSString* _sessionRecordPath;
    __strong NSString* _dataDiskPath;
    __strong NSString* _guestDir;
    __strong NSString* _rootfsPath;
    BOOL _dataDiskReady;
}
// Readwrite here so the console callback and the boot/install paths
// (which run outside the @implementation) can move the phase.
@property (nonatomic, readwrite) TXBootPhase bootPhase;
@property (nonatomic, readwrite) NSInteger failedStep;
@property (nonatomic, readwrite) int64_t downloadReceived;
@property (nonatomic, readwrite) int64_t downloadExpected;
// Console output buffered since boot for the terminal's replay (see
// bufferedConsoleOutput). Appended on the runtime thread, read on
// the main thread, so every access is under @synchronized(self).
@property (nonatomic, strong) NSMutableData *consoleBuffer;
@end

// The console replay buffer keeps the most recent output (the boot
// log and the login prompt are ~10-20 KiB); older bytes are dropped
// from the front, so the buffer never grows without bound.
static const NSUInteger kConsoleBufferMaxBytes = 128 * 1024;

static NSString* TXStateName(TermXState state) {
    switch (state) {
        case TermXStateIdle: return @"Idle";
        case TermXStateDownloading: return @"Downloading";
        case TermXStateReady: return @"Ready";
        case TermXStateBooting: return @"Booting";
        case TermXStateRunning: return @"Running";
        case TermXStateStopped: return @"Stopped";
        case TermXStateFailed: return @"Failed";
    }
}

static void ConsoleOutput(void* context, const void* buffer, size_t length) {
    KernEngine* engine = (__bridge KernEngine*)context;
    NSData* data = [NSData dataWithBytes:buffer length:length];
    // Every console byte also goes to Documents/Engine/guest.log.
    TXLogConsoleData(data);
    // And into the in-memory replay buffer, so a terminal presented
    // later can still show the boot log and the login prompt.
    @synchronized (engine) {
        if (!engine.consoleBuffer) engine.consoleBuffer = [NSMutableData data];
        [engine.consoleBuffer appendData:data];
        if (engine.consoleBuffer.length > kConsoleBufferMaxBytes) {
            [engine.consoleBuffer replaceBytesInRange:NSMakeRange(0, engine.consoleBuffer.length - kConsoleBufferMaxBytes)
                                            withBytes:NULL length:0];
        }
    }
    id<KernEngineDelegate> delegate = engine.delegate;
    if (delegate) {
        // The callback runs on a runtime thread; the terminal view renders
        // from its own timer, so no main-queue hop is needed here.
        [delegate kernEngineDidReceiveConsoleOutput:data];
    }
    NSString* text = [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
    if (!text) return;
    if ([text containsString:@"UML_BOOT_ERROR:"]) {
        engine.failedStep = (engine.bootPhase == TXBootPhaseServices)
            ? TXBootStepStartup : TXBootStepKernel;
        engine.bootPhase = TXBootPhaseFailed;
        engine.state = TermXStateFailed;
        engine.statusText = [@"Guest boot failed: " stringByAppendingString:text];
        return;
    }
    if (engine.state == TermXStateBooting) {
        if ([text containsString:@"UML_BOOT_SWITCH_ROOT:/sbin/init"]) {
            // The kernel booted and init is running: systemd is now
            // starting services, and the login prompt comes next.
            engine.bootPhase = TXBootPhaseServices;
            engine.statusText = @"Starts services";
        }
        // The serial getty prints "kterm login: " once systemd is up.
        // That is the moment the shell is usable.
        if ([text containsString:@"login: "]) {
            engine.bootPhase = TXBootPhaseReady;
            engine.state = TermXStateRunning;
            engine.statusText = @"Debian shell — logged in as termux";
        }
    }
}

@implementation KernEngine

+ (instancetype)shared {
    static KernEngine* s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[KernEngine alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = TermXStateIdle;
        _bootPhase = TXBootPhaseIdle;
        _failedStep = -1;
        _statusText = @"Not installed yet — tap Install";
        NSString* docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        // Canonicalize once, here: /var is a symlink to /private/var,
        // so the raw Documents path starts with /var/mobile/... while
        // the framework resolves /private/var/mobile/... . Every guest
        // path below is built from this one, so all of them are
        // canonical from the start. (Side effect, one time: the
        // install fingerprint is keyed by the exact path string, so
        // the first launch of this build does one full hash verify
        // and re-records the fingerprint under the canonical path.)
        _guestDir = TXCanonicalizePath([docs stringByAppendingPathComponent:@"guest"]);
        TXLogEngine(@"Guest dir: %@", _guestDir);
        _rootfsPath = [_guestDir stringByAppendingPathComponent:kRootfsName];
        // Fixed path in the data container, NOT the tmp directory: iOS
        // may purge tmp, and a persistent disk must survive. The file
        // is created once and reused on every boot (see
        // createDataDiskIfNeededWithError:).
        _dataDiskPath = [_guestDir stringByAppendingPathComponent:@"termx-data.ext4"];
        // The runtime framework is deliberately NOT loaded here: the
        // app binary carries no framework load commands, and the
        // framework (53 MB, kernel inside) is dlopen()ed on Start
        // instead, so launch stays light. See loadRuntimeWithError:.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(enterBackground)
                                                     name:@"TermXEnterBackground" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(enterForeground)
                                                     name:@"TermXEnterForeground" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(memoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        // Refresh the state from disk on launch: an installed guest means Ready.
        BOOL installed = [self guestInstalled];
        if (installed) {
            _state = TermXStateReady;
            _statusText = @"Guest ready — starting the engine…";
        }
        TXLogEngine(@"TermX engine init: state %@, guest %@",
                    TXStateName(_state), installed ? @"installed" : @"not installed");
        // The runtime records how the last guest's session ended in
        // guest/session.json ("running" from boot on, then the end,
        // a kernel panic with its message). Read it before booting
        // again: after a failed run it says what the last one did.
        NSString* sessionPath = [_guestDir stringByAppendingPathComponent:@"session.json"];
        NSString* record = [NSString stringWithContentsOfFile:sessionPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        if (record.length) {
            NSString* trimmed = [record stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 2000) trimmed = [trimmed substringToIndex:2000];
            TXLogEngine(@"Previous session record: %@", trimmed);
        } else {
            TXLogEngine(@"No previous session record");
        }
    }
    return self;
}

// Canonicalize a path with realpath(): /var is a symlink to
// /private/var, so the guest paths the app builds start with
// /var/mobile/... while the framework's own dlopen path in the log
// reads /private/var/mobile/... . The runtime's std::filesystem
// checks should not care about a symlinked prefix, but a symlinked
// prefix is the one difference between the path the app stats and
// the path the framework resolves — remove it, so both sides name
// the same file the same way. Falls back to canonicalizing the
// parent directory and re-appending the last component when the
// file itself does not exist yet (the session record is created by
// the runtime during the run; the guest dir may not exist before
// the first install).
static NSString* TXCanonicalizePath(NSString* path) {
    if (!path.length) return path;
    char resolved[PATH_MAX];
    if (realpath(path.UTF8String, resolved)) {
        return [NSString stringWithUTF8String:resolved];
    }
    NSString* parent = [path stringByDeletingLastPathComponent];
    NSString* name = [path lastPathComponent];
    if (parent.length && realpath(parent.UTF8String, resolved)) {
        return [[NSString stringWithUTF8String:resolved] stringByAppendingPathComponent:name];
    }
    return path;
}

// Whether a host path can be named in a `ubd<n>=` kernel argument
// as itself: the runtime's uml::block::usable_ubd_path, replicated
// here so the pre-flight names the exact check that fails it. UML
// joins its arguments with spaces, and the kernel splits at
// whitespace (including byte 0xa0), quotes, and reads a comma or
// colon in a UBD specification as another field.
static BOOL TXPathUsableOnKernelCommandLine(NSString* path) {
    if (!path.length) return NO;
    const char* s = path.UTF8String;
    for (const char* p = s; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' ||
            c == '\r' || c == 0xa0 || c == '"' || c == ',' || c == ':') return NO;
    }
    return YES;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Load the runtime framework on Start, not at launch (see the header).
// The framework's own load commands pull in the three GPU frameworks,
// so nothing else needs loading. The handle is held forever: the
// runtime owns one host runtime per process lifetime, and its API
// table stays valid until process exit.
- (BOOL)loadRuntimeWithError:(NSString**)error {
    if (_api) return YES;
    // The framework lives in the bundle's Frameworks/ subdirectory,
    // which pathForResource:ofType: does NOT search on its own: the
    // bare call always returned nil, so every Boot failed with
    // "runtime framework is missing from the app bundle" even though
    // the framework is in the IPA. Look in Frameworks/ explicitly,
    // and fall back to the direct bundle-path construction.
    NSString* frameworkPath = [[NSBundle mainBundle] pathForResource:@"KRuntime_6_18_4K"
                                                              ofType:@"framework"
                                                         inDirectory:@"Frameworks"];
    if (!frameworkPath) {
        frameworkPath = [[[NSBundle mainBundle] bundlePath]
                         stringByAppendingPathComponent:@"Frameworks/KRuntime_6_18_4K.framework"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:frameworkPath]) frameworkPath = nil;
    }
    if (!frameworkPath) {
        // Diagnosable miss: log where we looked and what is there.
        NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
        NSString* frameworksDir = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
        NSArray* contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:frameworksDir error:nil];
        TXLogEngine(@"Runtime framework not found. Bundle: %@. Frameworks/: %@",
                    bundlePath, contents ?: @[]);
        if (error) *error = @"runtime framework is missing from the app bundle";
        return NO;
    }
    NSString* binaryPath = [frameworkPath stringByAppendingPathComponent:@"KRuntime_6_18_4K"];
    TXLogEngine(@"Loading runtime framework (dlopen): %@", binaryPath);
    // RTLD_GLOBAL, not RTLD_LOCAL: the kernel's ELF loader resolves
    // its Darwin imports through dlsym(RTLD_DEFAULT), so the
    // framework's symbols (e.g. darwin_uml_guest_shutdown) must be
    // globally visible or the guest exits with status 126.
    _runtimeHandle = dlopen(binaryPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!_runtimeHandle) {
        const char* why = dlerror();
        TXLogEngine(@"dlopen failed: %s", why ?: "?");
        if (error) *error = [NSString stringWithFormat:@"runtime framework did not load: %s", why ?: "?"];
        return NO;
    }
    typedef const kernarium_runtime_api* (*TXGetRuntimeAPIFn)(void);
    TXGetRuntimeAPIFn getAPI = (TXGetRuntimeAPIFn)dlsym(_runtimeHandle, "kernarium_runtime_get_api_v28");
    if (!getAPI) {
        TXLogEngine(@"dlsym failed: no kernarium_runtime_get_api_v28 in the framework");
        if (error) *error = @"runtime framework has no API entry point";
        return NO;
    }
    _api = getAPI();
    if (!_api) {
        if (error) *error = @"runtime framework returned no API";
        return NO;
    }
    TXLogEngine(@"Runtime loaded: ABI v%u, footprint %@", _api->abi_version,
                TXFormatBytes(TXCurrentFootprintBytes()));
    return YES;
}

- (void)memoryWarning:(NSNotification*)note {
    (void)note;
    TXLogEngine(@"MEMORY WARNING: state %@, footprint %@",
                TXStateName(self.state), TXFormatBytes(TXCurrentFootprintBytes()));
}

- (void)setState:(TermXState)state {
    if (state == _state) return;
    _state = state;
    TXLogEngine(@"State: %@ — %@", TXStateName(state), self.statusText ?: @"");
    [[NSNotificationCenter defaultCenter] postNotificationName:kTermXStateChanged object:nil];
    id<KernEngineDelegate> delegate = self.delegate;
    if (delegate) [delegate termXEngineDidChangeState:state status:self.statusText];
}

- (void)setStatusText:(NSString*)statusText {
    // The download watcher reports the same step text every 0.25 s;
    // log only when the text actually changes, or the log drowns.
    BOOL changed = ![_statusText isEqualToString:statusText ?: @""];
    _statusText = [statusText copy];
    if (changed) TXLogEngine(@"%@", _statusText);
    [[NSNotificationCenter defaultCenter] postNotificationName:kTermXStateChanged object:nil];
    id<KernEngineDelegate> delegate = self.delegate;
    if (delegate) [delegate termXEngineDidChangeState:self.state status:self.statusText];
}

- (double)bootProgress {
    switch (self.state) {
        case TermXStateDownloading:
            return self.progress; // install fraction, 0..1, real
        case TermXStateBooting:
            // Real phase transitions only: run() started, then init.
            return (_bootPhase == TXBootPhaseServices) ? 0.7 : 0.35;
        case TermXStateRunning:
            return 1.0;
        case TermXStateFailed:
            return self.progress; // keep the last real value
        default:
            return 0.0;
    }
}

- (unsigned long long)storageUsedBytes {
    struct stat st;
    if (stat(_dataDiskPath.UTF8String, &st) != 0) return 0;
    return (unsigned long long)st.st_blocks * 512ULL;
}

- (unsigned long long)storageTotalBytes {
    return (unsigned long long)kDataDiskGiB << 30;
}

- (BOOL)dataDiskReady {
    return _dataDiskReady;
}

- (NSString*)kernelDetail {
    NSString* ram = kGuestMemoryMiB >= 1024
        ? [NSString stringWithFormat:@"%u GiB RAM", kGuestMemoryMiB / 1024]
        : [NSString stringWithFormat:@"%u MiB RAM", kGuestMemoryMiB];
    return [NSString stringWithFormat:@"6.18.60 · %u vCPUs · %@", kGuestCPUs, ram];
}

- (NSString*)imageDetail {
    return @"trixie slim · read-only";
}

- (void)enterBackground {
    if (_api && _running) _api->set_gpu_hold(1);
}

- (void)enterForeground {
    if (_api && _running) _api->set_gpu_hold(0);
}

- (NSString*)dataDiskPath {
    return _dataDiskPath;
}

- (BOOL)guestInstalled {
    NSString* error = nil;
    return [GuestInstall guestInstalledAt:_rootfsPath error:&error];
}

- (void)installGuestWithCompletion:(void (^)(BOOL, NSString*))completion {
    self.bootPhase = TXBootPhaseDownloading;
    self.failedStep = -1;
    self.downloadReceived = 0;
    self.downloadExpected = 0;
    self.state = TermXStateDownloading;
    self.statusText = @"Downloading Debian image…";
    TXLogEngine(@"Install started: %@", kRootfsURL);
    __weak typeof(self) weakSelf = self;
    [GuestInstall installGuestTo:_rootfsPath progress:^(double f, NSString* step, int64_t received, int64_t expected) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.progress = f;
        strongSelf.downloadReceived = received;
        strongSelf.downloadExpected = expected;
        // The install fraction is the real phase: the download
        // occupies 0..0.6, verify/extract/verify the rest.
        strongSelf.bootPhase = (f < 0.6) ? TXBootPhaseDownloading : TXBootPhaseVerifying;
        strongSelf.statusText = step;
    } completion:^(BOOL ok, NSString* error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { if (completion) completion(ok, error); return; }
        if (ok) {
            strongSelf.bootPhase = TXBootPhaseIdle;
            strongSelf.state = TermXStateReady;
            strongSelf.statusText = @"Guest ready — starting the engine…";
            // Distinct from the pipeline's "Install complete: guest
            // image verified" line: that one is the pipeline finishing,
            // this one is the completion reaching the engine. The two
            // used to share one string, which read as the pipeline
            // running twice (the 10:32 log) when the completion was
            // merely delayed behind the per-tick re-hash on the main
            // queue.
            TXLogEngine(@"Install done — guest ready");
        } else if ([error isEqualToString:@"cancelled"]) {
            // A user cancel is not a failure: back to Idle, and the
            // next Install resumes from the saved resume data.
            strongSelf.bootPhase = TXBootPhaseIdle;
            strongSelf.state = TermXStateIdle;
            strongSelf.statusText = @"Download cancelled — tap Install to resume";
        } else {
            strongSelf.bootPhase = TXBootPhaseFailed;
            strongSelf.failedStep = TXBootStepImage;
            strongSelf.state = TermXStateFailed;
            strongSelf.statusText = error ?: @"Install failed";
        }
        if (completion) completion(ok, error);
    }];
}

// Create the persistent data disk if it does not exist yet; reuse it
// otherwise. The path must name no spaces, quotes, commas or colons
// (the runtime names it on the kernel command line); Documents/guest
// is safe. The file is sparse (ftruncate), so an 8 GiB disk costs
// nothing until the guest writes, and it is excluded from backup: a
// multi-gigabyte guest disk must never ride along in an iCloud backup.
// The stock upstream boot-ramdisk /init formats the upper layer on
// every boot, which would wipe this file's contents each time; TermX
// ships a framework built with that step changed to
// format-only-when-unformatted, so a reused file keeps its data.
- (BOOL)createDataDiskIfNeededWithError:(NSString**)error {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSDictionary* attrs = [fm attributesOfItemAtPath:_dataDiskPath error:nil];
    off_t size = (off_t)kDataDiskGiB << 30;
    if (attrs) {
        if ([attrs fileSize] == (unsigned long long)size) {
            TXLogEngine(@"Reusing data disk: %@ used of %@",
                        TXFormatBytes(self.storageUsedBytes),
                        TXFormatBytes(self.storageTotalBytes));
            return YES;
        }
        TXLogEngine(@"Data disk has the wrong size (%@) — recreating it",
                    TXFormatBytes([attrs fileSize]));
        [fm removeItemAtPath:_dataDiskPath error:nil];
    }
    int fd = open(_dataDiskPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        if (error) *error = @"could not create the data disk";
        return NO;
    }
    BOOL ok = ftruncate(fd, size) == 0;
    close(fd);
    if (!ok) {
        if (error) *error = @"could not size the data disk";
        return NO;
    }
    NSURL* url = [NSURL fileURLWithPath:_dataDiskPath];
    [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    TXLogEngine(@"Created data disk: %@ at %@", TXFormatBytes(self.storageTotalBytes), _dataDiskPath);
    return YES;
}

- (BOOL)eraseDataDiskWithError:(NSString**)error {
    if (self.state == TermXStateRunning || self.state == TermXStateBooting ||
        self.state == TermXStateDownloading) {
        if (error) *error = @"stop the guest before erasing the data disk";
        return NO;
    }
    NSFileManager* fm = [NSFileManager defaultManager];
    NSError* removeError = nil;
    if ([fm fileExistsAtPath:_dataDiskPath] &&
        ![fm removeItemAtPath:_dataDiskPath error:&removeError]) {
        if (error) *error = @"could not erase the data disk";
        return NO;
    }
    _dataDiskReady = NO;
    TXLogEngine(@"Data disk erased");
    return YES;
}

// Pre-flight: replicate the runtime's runtimeRun() validation
// with the real values, before run() is called. The 13:42 run
// failed with "Guest run failed (-1)" — -UML_EMULATOR_INVALID_
// ARGUMENT — three times, and the runtime prints the exact failing
// check to stderr, which the app never captured (main() now does).
// This check names the cause here instead: a failure returns NO
// with *error set to the exact check, the engine goes Failed with
// that text, and run() is never called. On success it logs the
// validated values in one line and hands back the display size
// run() must use. The checks run in the runtime's own order, so the
// first failure named is the first failure the runtime would hit.
- (BOOL)preflightBootOnView:(MTKView*)view
                      width:(uint32_t*)outWidth
                     height:(uint32_t*)outHeight
                      error:(NSString**)error {
    // 1. The request itself: the runtime refuses a struct smaller
    // than everything before the adb key. The app's header is the
    // upstream header at the pinned commit fbe12ee, the same commit
    // the Mac framework was built from, and the framework reports
    // ABI v43, which the header declares — but log the numbers, so
    // a mismatch shows up instead of being assumed away.
    uint32_t structSize = (uint32_t)sizeof(kernarium_runtime_boot);
    size_t minStructSize = offsetof(kernarium_runtime_boot, android_adb_public_key);
    TXLogEngine(@"Pre-flight: boot struct %u bytes (runtime needs >= %zu), ABI v%u",
                structSize, minStructSize, KERNARIUM_RUNTIME_API_VERSION);
    if (structSize < minStructSize) {
        if (error) *error = @"Boot refused: boot request is too small for this runtime (struct_size)";
        TXLogEngine(@"Pre-flight FAILED: struct_size %u < %zu", structSize, minStructSize);
        return NO;
    }
    // 2. Display geometry: the runtime refuses a zero side, a side
    // over its 4095 maximum, or zero DPI.
    CGFloat scale = [UIScreen mainScreen].scale;
    uint32_t width = (uint32_t)(view.bounds.size.width * scale);
    uint32_t height = (uint32_t)(view.bounds.size.height * scale);
    uint32_t dpi = 160;
    TXLogEngine(@"Pre-flight: display %lux%lu pt @%.0fx = %ux%u px @%u DPI (max 4095)",
                (unsigned long)view.bounds.size.width, (unsigned long)view.bounds.size.height,
                (double)scale, width, height, dpi);
    if (width == 0 || height == 0 || width > 4095 || height > 4095 || dpi == 0) {
        if (error) *error = [NSString stringWithFormat:
            @"Boot refused: guest display is %ux%u — the view has not laid out yet", width, height];
        TXLogEngine(@"Pre-flight FAILED: invalid display geometry %ux%u @%u DPI", width, height, dpi);
        return NO;
    }
    // 3. CPU and memory: the runtime admits 512 MiB through its
    // ceiling in 64 MiB steps, and no more vCPUs than the host has.
    // The ceiling never exceeds physical RAM, so that is the bound
    // checked here; the GPU-budget call below reports the runtime's
    // own limit as well.
    NSUInteger hostCPUs = [NSProcessInfo processInfo].processorCount;
    unsigned long long physicalMiB = [NSProcessInfo processInfo].physicalMemory >> 20;
    TXLogEngine(@"Pre-flight: %u vCPUs (host %lu), %u MiB RAM (host %llu MiB, min 512, step 64)",
                kGuestCPUs, (unsigned long)hostCPUs, kGuestMemoryMiB, physicalMiB);
    if (kGuestCPUs == 0 || kGuestCPUs > (hostCPUs == 0 ? 1 : (uint32_t)hostCPUs)) {
        if (error) *error = @"Boot refused: guest vCPU count is not admitted on this phone";
        TXLogEngine(@"Pre-flight FAILED: %u vCPUs vs host %lu", kGuestCPUs, (unsigned long)hostCPUs);
        return NO;
    }
    if (kGuestMemoryMiB < 512 || (kGuestMemoryMiB - 512) % 64 != 0 ||
        kGuestMemoryMiB > physicalMiB) {
        if (error) *error = @"Boot refused: guest memory size is not admitted on this phone";
        TXLogEngine(@"Pre-flight FAILED: %u MiB RAM vs host %llu MiB", kGuestMemoryMiB, physicalMiB);
        return NO;
    }
    // 4. Session record path: empty or PATH_MAX long is refused.
    // Canonicalized like the other boot paths (see
    // TXCanonicalizePath): the file itself may not exist yet, so
    // the parent directory is what realpath() resolves.
    _sessionRecordPath = TXCanonicalizePath([_guestDir stringByAppendingPathComponent:@"session.json"]);
    TXLogEngine(@"Pre-flight: session record path %@ (%lu bytes)",
                _sessionRecordPath, (unsigned long)_sessionRecordPath.length);
    if (_sessionRecordPath.length == 0 || _sessionRecordPath.length >= PATH_MAX) {
        if (error) *error = @"Boot refused: session record path is invalid";
        TXLogEngine(@"Pre-flight FAILED: session record path length %lu",
                    (unsigned long)_sessionRecordPath.length);
        return NO;
    }
    // 5. Rootfs and overlay: both must be regular files. The rootfs
    // must also be an .ext4 image with no write bits at all — the
    // runtime's immutableExt4Rootfs. The image on the phone was
    // installed by build 11f547d; the pipeline chmods it to 0444
    // after verify, and the 13:42 legacy hash running proves it had
    // no write bits then — but bits can change (a restore, a file
    // provider), so re-assert them here instead of assuming: if
    // they are wrong, fix them and log it; only fail when the fix
    // does not stick.
    struct stat rootSt;
    if (stat(_rootfsPath.UTF8String, &rootSt) != 0 || !S_ISREG(rootSt.st_mode)) {
        if (error) *error = @"Boot refused: guest image is missing or not a file";
        TXLogEngine(@"Pre-flight FAILED: rootfs %@ is not a regular file", _rootfsPath);
        return NO;
    }
    if ((unsigned long long)rootSt.st_size != (unsigned long long)kRootfsSize) {
        if (error) *error = @"Boot refused: guest image has the wrong size";
        TXLogEngine(@"Pre-flight FAILED: rootfs size %@, expected %@",
                    TXFormatBytes((unsigned long long)rootSt.st_size),
                    TXFormatBytes((unsigned long long)kRootfsSize));
        return NO;
    }
    if (![[_rootfsPath.pathExtension lowercaseString] isEqualToString:@"ext4"]) {
        if (error) *error = @"Boot refused: guest image is not an .ext4 image";
        TXLogEngine(@"Pre-flight FAILED: rootfs extension is %@", _rootfsPath.pathExtension);
        return NO;
    }
    mode_t rootMode = rootSt.st_mode & 0777;
    if (rootMode & 0222) {
        TXLogEngine(@"Pre-flight: rootfs has write bits (mode %04o) — re-applying read-only", rootMode);
        chmod(_rootfsPath.UTF8String, 0444);
        if (stat(_rootfsPath.UTF8String, &rootSt) != 0 || (rootSt.st_mode & 0222)) {
            if (error) *error = @"Boot refused: guest image could not be made read-only";
            TXLogEngine(@"Pre-flight FAILED: rootfs still writable after chmod 0444");
            return NO;
        }
        TXLogEngine(@"Pre-flight: rootfs is read-only again (mode %04o)", rootSt.st_mode & 0777);
    }
    // The runtime checks only the extension and the bits, but a file
    // with the right name and bits could still be the wrong bytes:
    // confirm the ext4 superblock magic (0xEF53 at offset 1080).
    int magicFd = open(_rootfsPath.UTF8String, O_RDONLY);
    if (magicFd >= 0) {
        unsigned char magic[2] = {0, 0};
        ssize_t n = pread(magicFd, magic, sizeof(magic), 1080);
        close(magicFd);
        if (n == 2) {
            TXLogEngine(@"Pre-flight: rootfs ext4 magic %02x %02x (want 53 ef)", magic[0], magic[1]);
            if (magic[0] != 0x53 || magic[1] != 0xEF) {
                if (error) *error = @"Boot refused: guest image is not an ext4 filesystem";
                TXLogEngine(@"Pre-flight FAILED: rootfs superblock magic is not ext4");
                return NO;
            }
        } else {
            TXLogEngine(@"Pre-flight: could not read rootfs superblock magic — continuing");
        }
    }
    struct stat overlaySt;
    if (stat(_dataDiskPath.UTF8String, &overlaySt) != 0 || !S_ISREG(overlaySt.st_mode)) {
        if (error) *error = @"Boot refused: data disk is missing or not a file";
        TXLogEngine(@"Pre-flight FAILED: overlay %@ is not a regular file", _dataDiskPath);
        return NO;
    }
    TXLogEngine(@"Pre-flight: rootfs %@ (mode %04o), overlay %@",
                _rootfsPath, rootSt.st_mode & 0777, _dataDiskPath);
    // 6. Both paths are named in `ubd<n>=` kernel arguments, which
    // cannot carry whitespace, a quote, a comma or a colon.
    if (!TXPathUsableOnKernelCommandLine(_rootfsPath)) {
        if (error) *error = @"Boot refused: guest image path cannot be named on the kernel command line";
        TXLogEngine(@"Pre-flight FAILED: rootfs path fails the UBD check: %@", _rootfsPath);
        return NO;
    }
    if (!TXPathUsableOnKernelCommandLine(_dataDiskPath)) {
        if (error) *error = @"Boot refused: data disk path cannot be named on the kernel command line";
        TXLogEngine(@"Pre-flight FAILED: overlay path fails the UBD check: %@", _dataDiskPath);
        return NO;
    }
    // 7. The GPU budget the runtime will compute for this boot: its
    // process limit is the one LiveContainer (or SideStore) gives
    // this process, so log the numbers instead of assuming them.
    if (_api->plan_gpu_budget) {
        kernarium_runtime_gpu_budget budget;
        memset(&budget, 0, sizeof(budget));
        budget.struct_size = (uint32_t)sizeof(budget);
        _api->plan_gpu_budget(kGuestMemoryMiB, kGuestCPUs, 0, 0, 0, &budget);
        TXLogEngine(@"Pre-flight: GPU budget %@ of a %@ limit, short_of_floor=%u, footprint %@",
                    TXFormatBytes(budget.budget_bytes),
                    TXFormatBytes(budget.process_limit_bytes),
                    budget.short_of_floor,
                    TXFormatBytes(TXCurrentFootprintBytes()));
        if (budget.short_of_floor) {
            self.statusText = @"Warning: low memory headroom — booting anyway";
        }
    }
    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    TXLogEngine(@"Pre-flight OK: display %ux%u, %u vCPUs, %u MiB RAM, rootfs read-only ext4, overlay present",
                width, height, kGuestCPUs, kGuestMemoryMiB);
    return YES;
}

- (void)bootOnView:(MTKView*)view {
    NSString* loadError = nil;
    if (![self loadRuntimeWithError:&loadError]) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepKernel;
        self.state = TermXStateFailed;
        self.statusText = loadError ?: @"Runtime framework did not load";
        return;
    }
    if (!view) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepKernel;
        self.state = TermXStateFailed;
        self.statusText = @"No guest display — this is an app bug";
        return;
    }
    // Canonicalize the boot paths before anything reads them: the
    // guest dir was canonicalized in init, so this is normally a
    // no-op, but a path built any other way (a restore, a file
    // provider) still gets the /var -> /private/var symlink resolved
    // here, so the install check, the pre-flight and the runtime all
    // name the same files the same way. Log it when it changes
    // anything: that is the evidence the fix fired.
    NSString* oldRootfs = _rootfsPath;
    NSString* oldDataDisk = _dataDiskPath;
    _rootfsPath = TXCanonicalizePath(_rootfsPath);
    _dataDiskPath = TXCanonicalizePath(_dataDiskPath);
    if (![_rootfsPath isEqualToString:oldRootfs] || ![_dataDiskPath isEqualToString:oldDataDisk]) {
        TXLogEngine(@"Canonicalized boot paths: rootfs %@ -> %@, overlay %@ -> %@",
                    oldRootfs, _rootfsPath, oldDataDisk, _dataDiskPath);
    }
    if (![self guestInstalled]) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepImage;
        self.state = TermXStateFailed;
        self.statusText = @"Guest is not installed — tap Install first";
        return;
    }
    _dataDiskReady = NO;
    self.failedStep = -1;
    NSString* error = nil;
    if (![self createDataDiskIfNeededWithError:&error]) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepStorage;
        self.state = TermXStateFailed;
        self.statusText = error;
        return;
    }
    _dataDiskReady = YES;
    // Pre-flight first: replicate the runtime's validation with the
    // real values. A failure names the exact check, goes Failed with
    // that text, and never calls run() — the 13:42 run failed three
    // times with a bare "Guest run failed (-1)" and no cause.
    uint32_t bootWidth = 0, bootHeight = 0;
    NSString* preflightError = nil;
    if (![self preflightBootOnView:view width:&bootWidth height:&bootHeight error:&preflightError]) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepKernel;
        self.state = TermXStateFailed;
        self.statusText = preflightError ?: @"Boot refused — see the log for the exact check";
        TXLogFlush(); // the named cause must be on disk even if the app is killed next
        return;
    }
    _api->set_console_output_callback(ConsoleOutput, (__bridge void*)self);
    kernarium_runtime_boot boot;
    memset(&boot, 0, sizeof(boot));
    boot.struct_size = (uint32_t)sizeof(boot);
    boot.width = bootWidth;
    boot.height = bootHeight;
    boot.dots_per_inch = 160;
    boot.guest_memory_mib = kGuestMemoryMiB;
    boot.guest_processor_count = kGuestCPUs;
    boot.rootfs_path = _rootfsPath.UTF8String;
    boot.overlay_path = _dataDiskPath.UTF8String;
    boot.session_record_path = _sessionRecordPath.UTF8String; // set by the pre-flight
    boot.use_jit = 0; // gadget (interpreter) engine: no JIT, no debugger
    // The boot struct's C strings must stay valid until run() returns,
    // on the run's own thread: copy them into buffers this boot owns,
    // so no NSString UTF8String lifetime question can remain. The
    // run's block frees them after run() returns; a second boot
    // allocates its own buffers, so the two can never share one.
    char* bootRootfs = boot.rootfs_path ? strdup(boot.rootfs_path) : NULL;
    char* bootOverlay = boot.overlay_path ? strdup(boot.overlay_path) : NULL;
    char* bootSession = boot.session_record_path ? strdup(boot.session_record_path) : NULL;
    if (!bootRootfs || !bootOverlay || (boot.session_record_path && !bootSession)) {
        free(bootRootfs); free(bootOverlay); free(bootSession);
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepKernel;
        self.state = TermXStateFailed;
        self.statusText = @"Boot refused: could not copy the guest paths";
        return;
    }
    boot.rootfs_path = bootRootfs;
    boot.overlay_path = bootOverlay;
    boot.session_record_path = bootSession;
    self.bootPhase = TXBootPhaseKernel;
    self.state = TermXStateBooting;
    self.statusText = @"Booting Debian…";
    TXLogEngine(@"Boot started: %ux%u display, %u vCPUs, %u MiB RAM, data disk %llu GiB",
                bootWidth, bootHeight, kGuestCPUs, kGuestMemoryMiB, kDataDiskGiB);
    _running = YES;
    // run() blocks until the guest stops, so it owns its own thread.
    // A Linux guest has no boot_completed signal: the console callback
    // flips the state to Running on the login prompt.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // The experiment, on the exact C strings run() is about to
        // read: log the raw bytes (pointer, length, full text, hex
        // dump), then repeat the runtime's exact std::filesystem
        // checks on them. If the strings are wrong here, the pointers
        // were the problem all along; if the checks fail here, the
        // log names which one and its error; if they pass here and
        // run() still fails with the runtime's line, the runtime sees
        // different bytes than the app hands it — that is the
        // distinction this build exists to draw. A failure refuses
        // the boot with the named cause instead of handing possibly
        // bad pointers to the runtime.
        NSUInteger rootfsBytes = [self->_rootfsPath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger overlayBytes = [self->_dataDiskPath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger sessionBytes = [self->_sessionRecordPath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        // Each logged separately (no && chain): a bad first string
        // must not hide the other two.
        BOOL rootfsStringOK = TXLogBootCString("rootfs", boot.rootfs_path, rootfsBytes);
        BOOL overlayStringOK = TXLogBootCString("overlay", boot.overlay_path, overlayBytes);
        BOOL sessionStringOK = TXLogBootCString("session", boot.session_record_path, sessionBytes);
        // The exact check runs even when a string looks wrong: the
        // two are independent evidence, and both belong in the log.
        BOOL pathsExactOK = TXCheckBootPathsExact(boot.rootfs_path, boot.overlay_path);
        BOOL stringsOK = rootfsStringOK && overlayStringOK && sessionStringOK;
        BOOL pathsOK = stringsOK && pathsExactOK;
        TXLogFlush(); // the experiment lines must be on disk even if the run kills the process
        if (!pathsOK) {
            free(bootRootfs); free(bootOverlay); free(bootSession);
            self->_running = NO;
            self.bootPhase = TXBootPhaseFailed;
            self.failedStep = TXBootStepKernel;
            self.state = TermXStateFailed;
            self.statusText = @"Boot refused: the runtime's own path check fails on the boot paths — see the log";
            return;
        }
        int result = self->_api->run(view, &boot);
        free(bootRootfs); free(bootOverlay); free(bootSession);
        self->_running = NO;
        if (result == 0) {
            self.bootPhase = TXBootPhaseIdle;
            self.state = TermXStateStopped;
            self.statusText = @"Guest powered off";
        } else if (result == KERNARIUM_RUNTIME_RESULT_RESTART_LOOP) {
            TXBootPhase phaseAtEnd = self.bootPhase;
            self.bootPhase = TXBootPhaseFailed;
            self.failedStep = (phaseAtEnd == TXBootPhaseServices)
                ? TXBootStepStartup : TXBootStepKernel;
            self.state = TermXStateFailed;
            self.statusText = @"Guest kept restarting — see the console";
        } else {
            TXBootPhase phaseAtEnd = self.bootPhase;
            self.bootPhase = TXBootPhaseFailed;
            self.failedStep = (phaseAtEnd == TXBootPhaseServices)
                ? TXBootStepStartup : TXBootStepKernel;
            self.state = TermXStateFailed;
            self.statusText = [NSString stringWithFormat:@"Guest run failed (%d)", result];
        }
    });
}

- (void)stopGuest {
    // Stopping a download cancels it (the background session saves
    // resume data) and goes back to Idle; stopping a running guest
    // asks the runtime to stop it.
    if (self.state == TermXStateDownloading) {
        TXLogEngine(@"Stop requested during download");
        [GuestInstall cancelDownload];
        return;
    }
    TXLogEngine(@"Stop requested");
    if (_api && _running) _api->request_stop();
}

- (NSData*)bufferedConsoleOutput {
    @synchronized (self) {
        return [self.consoleBuffer copy] ?: [NSData data];
    }
}

- (void)sendConsoleInput:(NSData*)data {
    if (!_api || !_running || data.length == 0) return;
    // On the Linux runtime this writes to the guest's ttyS0. (The Android
    // App Store runtime answers -ENOTSUP here; this app never links it.)
    (void)_api->send_console_input(data.bytes, data.length);
}

@end
