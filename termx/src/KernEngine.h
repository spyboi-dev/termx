// KernEngine: drives the Kernarium Linux runtime framework
// (KRuntime_6_18_4K) from Objective-C. The guest is a Debian Linux rootfs
// that boots straight to a shell on its serial console (ttyS0), which the
// runtime mirrors to the host through the console callbacks. No Android,
// no ADB, no Termux APK: the shell IS the app.
// Interpreter (gadget) engine only: use_jit is always 0, so no StikDebug,
// no StikJIT and no debugger are needed at any point.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import <MetalKit/MetalKit.h>

typedef NS_ENUM(NSInteger, TermXState) {
    TermXStateIdle = 0,       // nothing installed, nothing running
    TermXStateDownloading,    // Debian image downloading
    TermXStateReady,          // guest installed, ready to boot
    TermXStateBooting,        // guest booting
    TermXStateRunning,        // guest up (login prompt seen on the console)
    TermXStateStopped,        // guest stopped
    TermXStateFailed,         // last step failed; statusText says why
};

// Boot phase, driven only by real events: the download steps, the
// overlay creation, run() starting, the UML_BOOT_SWITCH_ROOT console
// marker, and the login prompt. The startup screen's rows and its
// progress bar read this, never a timer.
typedef NS_ENUM(NSInteger, TXBootPhase) {
    TXBootPhaseIdle = 0,       // nothing in flight
    TXBootPhaseDownloading,    // rootfs archive downloading
    TXBootPhaseVerifying,      // download hash / extract / image verify
    TXBootPhaseKernel,         // run() started, kernel booting
    TXBootPhaseServices,       // init running, systemd starting services
    TXBootPhaseReady,          // login prompt seen, shell usable
    TXBootPhaseFailed,         // a step failed; failedStep says which
};

// The startup screen's checklist rows, in order. The engine reports
// which row failed (failedStep, -1 when nothing failed) so the
// screen can show the failure on the right row with the reason.
typedef NS_ENUM(NSInteger, TXBootStep) {
    TXBootStepImage = 0,       // system image (download + verify)
    TXBootStepKernel,          // Linux kernel boot
    TXBootStepStorage,         // overlay disk creation
    TXBootStepStartup,         // init + services up to the login prompt
    TXBootStepCount,
};

extern NSString* const kTermXStateChanged;

@protocol KernEngineDelegate <NSObject>
- (void)termXEngineDidChangeState:(TermXState)state status:(NSString*)status;
- (void)kernEngineDidReceiveConsoleOutput:(NSData*)data;
@end

@interface KernEngine : NSObject

@property (nonatomic, copy) NSString* statusText;
@property (nonatomic) TermXState state;
@property (atomic) double progress; // 0..1 for the current download step
@property (nonatomic, weak) id<KernEngineDelegate> delegate;

// Boot phase and failure step for the startup screen (see above).
@property (nonatomic, readonly) TXBootPhase bootPhase;
@property (nonatomic, readonly) NSInteger failedStep; // TXBootStep, or -1

// Real boot progress 0..1 for the startup screen's progress bar:
// the install fraction while downloading/verifying, then 0.35 once
// the kernel is booting, 0.7 once init is running, 1.0 at the login
// prompt. Never a timer, only these real transitions.
@property (nonatomic, readonly) double bootProgress;

// Live download counters (bytes), for the startup screen's
// "156 MB of 368 MB" line. 0 when no download is in flight.
@property (nonatomic, readonly) int64_t downloadReceived;
@property (nonatomic, readonly) int64_t downloadExpected;

// Writable storage: bytes actually allocated on the overlay disk
// (sparse file, so this grows as the guest writes) and its total
// capacity. 0 used before the overlay is created for a boot.
@property (nonatomic, readonly) unsigned long long storageUsedBytes;
@property (nonatomic, readonly) unsigned long long storageTotalBytes;

// Fixed guest facts for the startup screen's row details.
@property (nonatomic, readonly) NSString* kernelDetail;  // "6.18.60 · 2 vCPUs · 1 GiB RAM"
@property (nonatomic, readonly) NSString* imageDetail;   // "trixie · read-only"
@property (nonatomic, readonly) BOOL overlayCreated;     // overlay exists for this boot

// Guest files live here. rootfsPath is the Debian ext4 image (read-only,
// no write bits, as the runtime requires); overlayPath is the sparse
// overlay disk the boot formats fresh on ubd1 at every boot, so a guest's
// writes live for one session only — apt installs do not survive a reboot.
// Bake the tools you want into the image instead (see rootfs-build/).
@property (nonatomic, readonly) NSString* guestDir;
@property (nonatomic, readonly) NSString* rootfsPath;
@property (nonatomic, readonly) NSString* overlayPath;

+ (instancetype)shared;

// True when the rootfs image exists and its SHA-256 matches the build.
- (BOOL)guestInstalled;

// Download the Debian image, verify it (SHA-256 of the archive and of
// the extracted image), and place it at rootfsPath, read-only.
// Runs on a background queue; progress/status update as it goes.
- (void)installGuestWithCompletion:(void (^)(BOOL ok, NSString* error))completion;

// Boot the Linux guest on the given Metal view. run() blocks until the
// guest stops, so this returns at once and the boot runs on its own thread.
// The view must be non-nil: the runtime refuses a null view. It is the
// guest's framebuffer; the terminal view sits on top of it.
- (void)bootOnView:(MTKView*)view;
- (void)stopGuest;

// Console I/O: bytes to the guest's ttyS0, and the entry point the
// console-output callback feeds.
- (void)sendConsoleInput:(NSData*)data;

@end
