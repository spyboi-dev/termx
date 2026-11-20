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

@protocol KernEngineDelegate <NSObject>
- (void)termXEngineDidChangeState:(TermXState)state status:(NSString*)status;
- (void)kernEngineDidReceiveConsoleOutput:(NSData*)data;
@end

@interface KernEngine : NSObject

@property (nonatomic, copy) NSString* statusText;
@property (nonatomic) TermXState state;
@property (atomic) double progress; // 0..1 for the current download step
@property (nonatomic, weak) id<KernEngineDelegate> delegate;

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
