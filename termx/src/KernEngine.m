// SPDX-License-Identifier: GPL-2.0-or-later
#import "KernEngine.h"
#import "KernariumRuntime.h"
#import "GuestInstall.h"
#import <CommonCrypto/CommonDigest.h>

NSString* const kTermXStateChanged = @"TermXStateChanged";

// The Linux guest: 1024 MiB RAM and 2 vCPUs are plenty for a shell, and
// leave the process headroom the runtime's GPU budget wants.
static const uint32_t kGuestMemoryMiB = 1024;
static const uint32_t kGuestCPUs = 2;
// Writable space for one session, in GiB. The boot formats the overlay
// fresh every time, so this is session scratch, not storage.
static const uint64_t kOverlayGiB = 4;

static void ConsoleOutput(void* context, const void* buffer, size_t length) {
    KernEngine* engine = (__bridge KernEngine*)context;
    NSData* data = [NSData dataWithBytes:buffer length:length];
    id<KernEngineDelegate> delegate = engine.delegate;
    if (delegate) {
        // The callback runs on a runtime thread; the terminal view renders
        // from its own timer, so no main-queue hop is needed here.
        [delegate kernEngineDidReceiveConsoleOutput:data];
    }
    NSString* text = [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
    if (!text) return;
    if ([text containsString:@"UML_BOOT_ERROR:"]) {
        engine.state = TermXStateFailed;
        engine.statusText = [@"Guest boot failed: " stringByAppendingString:text];
        return;
    }
    if (engine.state == TermXStateBooting) {
        if ([text containsString:@"UML_BOOT_SWITCH_ROOT:/sbin/init"]) {
            engine.statusText = @"init running — waiting for the login prompt…";
        }
        // The serial getty prints "kterm login: " once systemd is up.
        // That is the moment the shell is usable.
        if ([text containsString:@"login: "]) {
            engine.state = TermXStateRunning;
            engine.statusText = @"Debian shell — logged in as termux";
        }
    }
}

@interface KernEngine () {
    const kernarium_runtime_api* _api;
    BOOL _running;
    // Held for the whole run: the boot struct hands the runtime C strings,
    // and they must stay alive until run() returns.
    NSString* _sessionRecordPath;
    NSString* _overlayPath;
}
@end

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
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setState:(TermXState)state {
    _state = state;
    [[NSNotificationCenter defaultCenter] postNotificationName:kTermXStateChanged object:nil];
    id<KernEngineDelegate> delegate = self.delegate;
    if (delegate) [delegate termXEngineDidChangeState:state status:self.statusText];
}

- (void)setStatusText:(NSString*)statusText {
    _statusText = [statusText copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:kTermXStateChanged object:nil];
    id<KernEngineDelegate> delegate = self.delegate;
    if (delegate) [delegate termXEngineDidChangeState:self.state status:self.statusText];
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
    self.state = TermXStateDownloading;
    self.statusText = @"Downloading Debian image…";
    [GuestInstall installGuestTo:_rootfsPath progress:^(double f, NSString* step) {
        self.progress = f;
        self.statusText = step;
    } completion:^(BOOL ok, NSString* error) {
        if (ok) {
            self.state = TermXStateReady;
            self.statusText = @"Guest ready — tap Boot";
        } else {
            self.state = TermXStateFailed;
            self.statusText = error ?: @"Install failed";
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
        self.state = TermXStateFailed;
        self.statusText = @"Runtime framework did not load";
        return;
    }
    if (!view) {
        self.state = TermXStateFailed;
        self.statusText = @"No guest display — this is an app bug";
        return;
    }
    if (![self guestInstalled]) {
        self.state = TermXStateFailed;
        self.statusText = @"Guest is not installed — tap Install first";
        return;
    }
    NSString* error = nil;
    if (![self createOverlayWithError:&error]) {
        self.state = TermXStateFailed;
        self.statusText = error;
        return;
    }
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
    self.state = TermXStateBooting;
    self.statusText = @"Booting Debian…";
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
            self.state = TermXStateStopped;
            self.statusText = @"Guest powered off";
        } else if (result == KERNARIUM_RUNTIME_RESULT_RESTART_LOOP) {
            self.state = TermXStateFailed;
            self.statusText = @"Guest kept restarting — see the console";
        } else {
            self.state = TermXStateFailed;
            self.statusText = [NSString stringWithFormat:@"Guest run failed (%d)", result];
        }
    });
}

- (void)stopGuest {
    if (_api && _running) _api->request_stop();
}

- (void)sendConsoleInput:(NSData*)data {
    if (!_api || !_running || data.length == 0) return;
    // On the Linux runtime this writes to the guest's ttyS0. (The Android
    // App Store runtime answers -ENOTSUP here; this app never links it.)
    (void)_api->send_console_input(data.bytes, data.length);
}

@end
