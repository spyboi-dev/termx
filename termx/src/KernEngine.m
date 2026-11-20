// SPDX-License-Identifier: GPL-2.0-or-later
#import "KernEngine.h"
#import "KernariumRuntime.h"
#import "GuestInstall.h"
#import "TXLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>

NSString* const kTermXStateChanged = @"TermXStateChanged";

// The Linux guest: 1024 MiB RAM and 2 vCPUs are plenty for a shell, and
// leave the process headroom the runtime's GPU budget wants.
static const uint32_t kGuestMemoryMiB = 1024;
static const uint32_t kGuestCPUs = 2;
// Writable space for one session, in GiB. The boot formats the overlay
// fresh every time, so this is session scratch, not storage.
static const uint64_t kOverlayGiB = 4;

@interface KernEngine () {
    const kernarium_runtime_api* _api;
    BOOL _running;
    // Held for the whole run: the boot struct hands the runtime C strings,
    // and they must stay alive until run() returns.
    NSString* _sessionRecordPath;
    NSString* _overlayPath;
    BOOL _overlayCreated;
}
// Readwrite here so the console callback and the boot/install paths
// (which run outside the @implementation) can move the phase.
@property (nonatomic, readwrite) TXBootPhase bootPhase;
@property (nonatomic, readwrite) NSInteger failedStep;
@property (nonatomic, readwrite) int64_t downloadReceived;
@property (nonatomic, readwrite) int64_t downloadExpected;
@end

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
        _guestDir = [docs stringByAppendingPathComponent:@"guest"];
        _rootfsPath = [_guestDir stringByAppendingPathComponent:kRootfsName];
        _overlayPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"kterm-overlay.ext4"];
        _api = kernarium_runtime_get_api_v28();
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(enterBackground)
                                                     name:@"TermXEnterBackground" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(enterForeground)
                                                     name:@"TermXEnterForeground" object:nil];
        // Refresh the state from disk on launch: an installed guest means Ready.
        if ([self guestInstalled]) {
            _state = TermXStateReady;
            _statusText = @"Guest ready — tap Boot";
        }
        TXLogEngine(@"TermX engine init: state %@, guest %@",
                    TXStateName(_state), [self guestInstalled] ? @"installed" : @"not installed");
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    if (stat(_overlayPath.UTF8String, &st) != 0) return 0;
    return (unsigned long long)st.st_blocks * 512ULL;
}

- (unsigned long long)storageTotalBytes {
    return (unsigned long long)kOverlayGiB << 30;
}

- (BOOL)overlayCreated {
    return _overlayCreated;
}

- (NSString*)kernelDetail {
    NSString* ram = kGuestMemoryMiB >= 1024
        ? [NSString stringWithFormat:@"%u GiB RAM", kGuestMemoryMiB / 1024]
        : [NSString stringWithFormat:@"%u MiB RAM", kGuestMemoryMiB];
    return [NSString stringWithFormat:@"6.18.60 · %u vCPUs · %@", kGuestCPUs, ram];
}

- (NSString*)imageDetail {
    return @"trixie · read-only";
}

- (void)enterBackground {
    if (_api && _running) _api->set_gpu_hold(1);
}

- (void)enterForeground {
    if (_api && _running) _api->set_gpu_hold(0);
}

- (NSString*)overlayPath {
    return _overlayPath;
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
            strongSelf.statusText = @"Guest ready — tap Boot";
            TXLogEngine(@"Install complete: guest image verified");
        } else {
            strongSelf.bootPhase = TXBootPhaseFailed;
            strongSelf.failedStep = TXBootStepImage;
            strongSelf.state = TermXStateFailed;
            strongSelf.statusText = error ?: @"Install failed";
        }
        if (completion) completion(ok, error);
    }];
}

// Create the sparse overlay file the boot formats fresh on ubd1.
// The path must name no spaces, quotes, commas or colons (the runtime
// names it on the kernel command line); NSTemporaryDirectory is safe.
- (BOOL)createOverlayWithError:(NSString**)error {
    NSFileManager* fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:_overlayPath error:nil];
    int fd = open(_overlayPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        if (error) *error = @"could not create the overlay disk";
        return NO;
    }
    off_t size = (off_t)kOverlayGiB << 30;
    BOOL ok = ftruncate(fd, size) == 0;
    close(fd);
    if (!ok && error) *error = @"could not size the overlay disk";
    return ok;
}

- (void)bootOnView:(MTKView*)view {
    if (!_api) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepKernel;
        self.state = TermXStateFailed;
        self.statusText = @"Runtime framework did not load";
        return;
    }
    if (!view) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepKernel;
        self.state = TermXStateFailed;
        self.statusText = @"No guest display — this is an app bug";
        return;
    }
    if (![self guestInstalled]) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepImage;
        self.state = TermXStateFailed;
        self.statusText = @"Guest is not installed — tap Install first";
        return;
    }
    _overlayCreated = NO;
    self.failedStep = -1;
    NSString* error = nil;
    if (![self createOverlayWithError:&error]) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepStorage;
        self.state = TermXStateFailed;
        self.statusText = error;
        return;
    }
    _overlayCreated = YES;
    // Memory check first: the runtime says whether the process is likely
    // to be killed for the guest size we ask for.
    kernarium_runtime_gpu_budget budget;
    memset(&budget, 0, sizeof(budget));
    budget.struct_size = (uint32_t)sizeof(budget);
    if (_api->plan_gpu_budget) {
        _api->plan_gpu_budget(kGuestMemoryMiB, kGuestCPUs, 0, 0, 0, &budget);
        if (budget.short_of_floor) {
            self.statusText = @"Warning: low memory headroom — booting anyway";
        }
    }
    _api->set_console_output_callback(ConsoleOutput, (__bridge void*)self);
    CGFloat scale = [UIScreen mainScreen].scale;
    kernarium_runtime_boot boot;
    memset(&boot, 0, sizeof(boot));
    boot.struct_size = (uint32_t)sizeof(boot);
    boot.width = (uint32_t)(view.bounds.size.width * scale);
    boot.height = (uint32_t)(view.bounds.size.height * scale);
    boot.dots_per_inch = 160;
    boot.guest_memory_mib = kGuestMemoryMiB;
    boot.guest_processor_count = kGuestCPUs;
    boot.rootfs_path = _rootfsPath.UTF8String;
    boot.overlay_path = _overlayPath.UTF8String;
    _sessionRecordPath = [_guestDir stringByAppendingPathComponent:@"session.json"];
    boot.session_record_path = _sessionRecordPath.UTF8String;
    boot.use_jit = 0; // gadget (interpreter) engine: no JIT, no debugger
    self.bootPhase = TXBootPhaseKernel;
    self.state = TermXStateBooting;
    self.statusText = @"Booting Debian…";
    TXLogEngine(@"Boot started: %u vCPUs, %u MiB RAM, overlay %llu GiB",
                kGuestCPUs, kGuestMemoryMiB, kOverlayGiB);
    _running = YES;
    // run() blocks until the guest stops, so it owns its own thread.
    // The boot struct's C strings point into NSStrings the engine holds
    // (properties and ivars), so the pointers stay valid for the run.
    // A Linux guest has no boot_completed signal: the console callback
    // flips the state to Running on the login prompt.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = self->_api->run(view, &boot);
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
    TXLogEngine(@"Stop requested");
    if (_api && _running) _api->request_stop();
}

- (void)sendConsoleInput:(NSData*)data {
    if (!_api || !_running || data.length == 0) return;
    // On the Linux runtime this writes to the guest's ttyS0. (The Android
    // App Store runtime answers -ENOTSUP here; this app never links it.)
    (void)_api->send_console_input(data.bytes, data.length);
}

@end
