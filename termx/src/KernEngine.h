// KernEngine: drives the Kernarium Linux runtime framework
// (KRuntime_6_18_4K) from Objective-C. The guest is a Debian Linux rootfs
// that boots straight to a shell on its serial console (ttyS0), which the
// runtime mirrors to the host through the console callbacks. No Android,
// no ADB, no Termux APK: the shell IS the app.
// Interpreter (gadget) engine only: use_jit is always 0, so no StikDebug,
// no StikJIT and no debugger are needed at any point.
//
// The runtime framework is NOT linked at launch: the app binary carries
// no framework load commands, and the framework is dlopen()ed on Start
// instead. Linking it mapped its 53 MB (with the 36 MB kernel inside)
// into the process before anything ran, which is the launch-memory
// pattern that kills apps during a long download; dlopen keeps that
// memory out until the guest actually boots. The framework's own
// dependencies (the three GPU frameworks) load with it, as its own
// load commands name them.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import <MetalKit/MetalKit.h>

typedef NS_ENUM(NSInteger, TermXState) {
    TermXStateIdle = 0,       // nothing installed, nothing running
    TermXStateDownloading,    // Debian image downloading
    TermXStateReady,          // guest installed, ready to boot
    TermXStateBooting,        // guest booting
    TermXStateRunning,        // guest up (login prompt seen on the console)
    TermXStateStopping,       // stop requested, run() has not returned yet
    TermXStateSuspended,      // guest quiesced in background, resumes on foreground
    TermXStateStopped,        // guest stopped
    TermXStateFailed,         // last step failed; statusText says why
};

// Boot phase, driven only by real events: the download steps, the
// data disk creation, run() starting, the UML_BOOT_SWITCH_ROOT console
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
    TXBootStepStorage,         // data disk creation
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
// "56 MB of 116 MB" line. 0 when no download is in flight.
@property (nonatomic, readonly) int64_t downloadReceived;
@property (nonatomic, readonly) int64_t downloadExpected;

// Writable storage: bytes actually allocated on the data disk
// (sparse file, so this grows as the guest writes) and its total
// capacity. 0 used before the data disk is created for a boot.
@property (nonatomic, readonly) unsigned long long storageUsedBytes;
@property (nonatomic, readonly) unsigned long long storageTotalBytes;

// Fixed guest facts for the startup screen's row details.
@property (nonatomic, readonly) NSString* kernelDetail;  // "6.18.60 · 2 vCPUs · 2 GiB RAM"
@property (nonatomic, readonly) NSString* imageDetail;   // "rootfs-20261123-slim-fix5 · read-only" when current
@property (nonatomic, readonly) BOOL dataDiskReady;      // data disk exists for this boot

// Guest files live here. rootfsPath is the Debian ext4 image (read-only,
// no write bits, as the runtime requires); dataDiskPath is the guest's
// persistent writable data disk: one sparse file at a fixed path in the
// app's data container, created once on first install and reused on
// every boot, so anything installed or saved in a session is still
// there after a reboot. The system image stays read-only; only the
// data disk is writable. (The stock upstream boot-ramdisk /init
// formats the overlay upper layer on every boot, which ends the layer
// with the run; TermX ships a framework built with that step changed
// to format-only-when-unformatted — see patches/ — so the same file
// survives across boots.)
@property (nonatomic, readonly) NSString* guestDir;
@property (nonatomic, readonly) NSString* rootfsPath;
@property (nonatomic, readonly) NSString* dataDiskPath;

+ (instancetype)shared;

// YES when the installed image is a valid older release and a
// newer one is published: the app boots the installed image and
// offers the new one as an Update, never a failure. Set by the
// background launch update check; cleared by a successful install.
// Changes post kTermXStateChanged so the startup screen refreshes.
@property (nonatomic, readonly) BOOL updateAvailable;

// What the last guest session did, read from guest/session.json at
// launch (see KernEngine.m init). lastSessionCrashed is YES when the
// last run ended in a guest panic or kernel abort: the startup screen
// shows that and holds the auto-boot instead of silently booting
// into the same failure. lastSessionEnd is the record's end word
// ("running", "stopped", "guest-panic", "kernel-abort", …) and
// lastSessionMessage is its message, if any. A last run still
// "running" means the process was killed from outside (force-quit
// or jetsam): the boot proceeds normally, and the data-disk
// integrity check is the guard for a dirty disk, not this record.
@property (nonatomic, readonly) NSString *lastSessionEnd;
@property (nonatomic, readonly) NSString *lastSessionMessage;
@property (nonatomic, readonly) BOOL lastSessionCrashed;

// NO after a boot failure that must not be retried (a corrupt data
// disk: a retry fails identically). YES for ordinary failures. The
// startup screen's one automatic retry reads this.
@property (nonatomic, readonly) BOOL lastFailureRetryable;

// YES while the launch update check (background, at cold launch) is
// still running. The startup screen waits for it before auto-booting:
// if a newer image is available the guest is held stopped and the
// Update button is the choice, not a race with the auto-boot.
@property (nonatomic, readonly) BOOL launchUpdateCheckInFlight;

// True when a valid rootfs image exists on disk — any release. A
// version difference is an update, not a failure: the image boots
// as-is. Only a file that cannot be a guest image at all (wrong
// size, not ext4) counts as not installed.
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

// End the guest before the process dies (best effort, bounded
// 3 s): the runtime's request_stop, so run() returns and the
// session record ends "stopped" instead of "running" + suspended.
// The background quiesce (enterBackground) is the primary defence;
// a force-quit never calls applicationWillTerminate at all.
- (void)stopGuestForTermination;

// Delete the persistent data disk (the guest's saved state: installed
// packages, files, everything). The system image is untouched. The
// next boot creates a fresh data disk. This is the recovery path when
// the guest's saved state is broken.
- (BOOL)eraseDataDiskWithError:(NSString**)error;

// Data disk size setting: the size in GiB a NEW data disk gets.
// Stored in NSUserDefaults under "termx.dataDiskGiB", default 2.
// The startup screen offers a picker that writes it through
// +setDataDiskGiB:. An existing disk is never resized by this
// setting — it keeps its size until erased.
+ (uint64_t)dataDiskGiB;
+ (void)setDataDiskGiB:(uint64_t)giB;

// Console I/O: bytes to the guest's ttyS0, and the entry point the
// console-output callback feeds.
- (void)sendConsoleInput:(NSData*)data;

// Console output buffered since boot (most recent 128 KiB): the
// terminal replays this on presentation, because the engine's
// delegate is nil until the terminal exists and the boot log and the
// login prompt would otherwise never reach the view (they still
// reach guest.log). Returns a copy; safe from any thread.
- (NSData*)bufferedConsoleOutput;

@end
