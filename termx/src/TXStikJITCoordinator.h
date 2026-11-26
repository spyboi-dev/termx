// TXStikJITCoordinator - host side of Built-in StikJIT and the
// one router for both JIT methods.
//
// TermX's JIT allocator (Kernarium) already implements the
// universal brk #0xf00d protocol, so the host only has to acquire
// JIT, never to change the allocator. The two mutually exclusive
// methods, persisted in NSUserDefaults under "termx.jitMethod":
//
//   Built-in StikJIT  - this coordinator + the StikJIT helper
//     extension (via TXStikJITTransport). Recommended when
//     available. Unavailable below iOS 17.4 and inside
//     LiveContainer, which cannot create the helper extension.
//   StikDebug URL     - opens stikdebug://enable-jit with this
//     app's bundle ID, current PID, and script-name=universal.js.
//     Opening the URL only confirms iOS accepted the request.
//
// Before any Built-in StikJIT work the host checks, in its own
// process (the entitlement belongs to the host PID, so checking
// from the helper would check the wrong executable):
//   1. iOS 17.4 or later,
//   2. get-task-allow == true (Security framework SPI),
//   3. pairing bytes stored in the Keychain (TXPairingStore).
// The host app never strongly links StikJIT: the framework lives
// in the helper extension only, and all helper traffic goes
// through TXStikJITTransport.
//
// The pairing bytes are only ever copied as opaque bytes and are
// never logged. The configured script is .universal, fixed in
// backend code; it is not a user setting.
//
// Auto-enable: when the guest starts, the startup screen asks this
// coordinator to enable JIT on its own (autoEnableJITBestEffort).
// It runs the same enable flow in the background and never blocks
// the boot: the guest runs natively without JIT (JIT is only for
// in-guest compilers like Node V8), so a failure is logged and
// shown in About, and the guest boots anyway.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "TXPairingStore.h"
#import "TXStikJITTransport.h"

NS_ASSUME_NONNULL_BEGIN

// Persisted JIT method. Stored as an integer under
// kTXStikJITMethodDefaultsKey ("termx.jitMethod").
typedef NS_ENUM(NSInteger, TXStikJITMethod) {
    TXStikJITMethodBuiltInStikJIT = 0,
    TXStikJITMethodStikDebug = 1,
};

extern NSString *const kTXStikJITMethodDefaultsKey;
extern NSString *const kTXStikJITForceScriptDefaultsKey;

// Readiness of the Built-in StikJIT path.
typedef NS_ENUM(NSInteger, TXStikJITReadiness) {
    // Preflight passed and the helper reported Ready.
    TXStikJITReadinessReady = 0,
    // Preflight failed (OS, get-task-allow, pairing, or loopback);
    // `reason` names the failed check.
    TXStikJITReadinessNotReady,
    // Preflight passed but the helper could not be reached;
    // `reason` is the transport failure.
    TXStikJITReadinessHelperUnavailable,
};

typedef void (^TXStikJITReadinessHandler)(TXStikJITReadiness readiness, NSString *reason);
typedef void (^TXStikJITResultHandler)(BOOL success, NSString *statusText);

@interface TXStikJITCoordinator : NSObject

+ (instancetype)shared;

// YES when running inside LiveContainer (LC_HOME_PATH is set).
// Built-in StikJIT is unavailable there: LiveContainer cannot
// create the required helper extension.
+ (BOOL)isRunningInLiveContainer;

// YES when a debugger is attached to this process right now
// (P_TRACED): JIT is already enabled.
+ (BOOL)isDebuggerAttached;

// The selected method, corrected for the environment: when in
// LiveContainer a stored Built-in selection reads as StikDebug
// (see applyLiveContainerDefaultIfNeeded, which persists
// that correction). Never silently falls through at enable time.
- (TXStikJITMethod)selectedMethod;
- (void)setSelectedMethod:(TXStikJITMethod)method;

// If the stored method is Built-in and we are in LiveContainer,
// persist Wait for Debugger instead. Call on appearance, before
// showing the picker, so the stored value is always usable.
- (void)applyLiveContainerDefaultIfNeeded;

// Force JIT Script toggle, off by default. Only bypasses TXM
// detection and runs the configured (.universal) script regardless.
- (BOOL)forceScript;
- (void)setForceScript:(BOOL)forceScript;

// --- Built-in StikJIT preflight (host process) ---

// iOS 17.4 or later. Returns NO with a reason otherwise.
- (BOOL)supportsOSVersionWithReason:(NSString * _Nullable * _Nullable)reason;
// get-task-allow == true for this process, via the Security
// framework SPI (SecTaskCreateFromSelf +
// SecTaskCopyValueForEntitlement). Returns NO with a reason
// otherwise. Needs Security.framework linked.
- (BOOL)hasGetTaskAllowWithReason:(NSString * _Nullable * _Nullable)reason;

// --- Pairing (Keychain, TXPairingStore) ---

// YES when pairing bytes are stored (paired on this iPhone, or
// imported). A legacy Documents/StikJIT/pairingFile.plist is
// migrated into the Keychain on first read.
- (BOOL)pairingStored;
- (TXPairingSource)pairingSource;
// "Paired on this iPhone", "Imported", or "Not paired".
- (NSString *)pairingStatusText;
// The stored pairing bytes for the transport. Never logged.
- (nullable NSData *)readPairingDataWithError:(NSError **)error;

// Legacy names, kept for existing callers: the pairing lives in
// the Keychain now, not in a file.
- (BOOL)pairingFileExists;
- (nullable NSString *)pairingFileName;
- (NSString *)pairingFileStatusText;
- (nullable NSData *)readPairingFileDataWithError:(NSError **)error;
+ (NSURL *)pairingFileURL;

// Store picked pairing bytes in the Keychain, replacing any
// stored pairing. Completion is on the main queue with success
// and a short status string.
- (void)importPairingFileFromURL:(NSURL *)sourceURL
                      completion:(void (^)(BOOL success, NSString *statusText))completion;

// --- Loopback (LocalDevVPN, TXLoopbackProbe) ---

// The last loopback check's outcome. NO until a check has run.
@property (nonatomic, readonly) BOOL loopbackChecked;
@property (nonatomic, readonly) BOOL loopbackReachable;
@property (nonatomic, readonly, copy, nullable) NSString *lastLoopbackDetail;
// Runs the loopback check off the main thread; completion is on
// the main queue. Records the outcome above.
- (void)checkLoopbackWithCompletion:(void (^)(BOOL reachable, NSString *detail))completion;

// LocalDevVPN, which Built-in StikJIT and StikDebug reach the
// device through: open it to connect when it is installed,
// otherwise its App Store page.
+ (BOOL)localDevVPNInstalled;
+ (NSURL *)localDevVPNConnectURL;
+ (NSURL *)localDevVPNAppStoreURL;
+ (NSString *)localDevVPNActionTitle;
+ (void)openLocalDevVPN;

// TXM/SPTM status from the helper (Unknown while the transport
// is a stub). Informational only; the script stays .universal.
- (TXStikJITTXMStatus)txmSPTMStatus;
- (NSString *)txmSPTMStatusText;

// Last prepare/enable status text, for the About card to show
// across appearances. Cleared when the pairing changes.
@property (nonatomic, readonly, copy, nullable) NSString *lastPrepareStatusText;

// Last best-effort auto-enable outcome, for the About card.
// Nil until an auto-enable has been attempted this launch.
@property (nonatomic, readonly, copy, nullable) NSString *lastAutoEnableStatusText;
// YES once an auto-enable (or a manual enable) has attached a
// debugger this launch.
@property (nonatomic, readonly) BOOL jitEnabledThisLaunch;

// Run the preflight, then the loopback check, then ask the helper
// to prepare the device (reachability, DDI mount, TXM detection).
// Do not require the user to prepare before enabling: enableJIT
// does preparation itself. In LiveContainer this returns
// HelperUnavailable without launching anything.
- (void)prepareJITWithCompletion:(TXStikJITReadinessHandler)completion;

// Run the preflight, then the loopback check, then ask the helper
// to enable JIT for this process with the .universal script.
// Success here means the helper completed enablement; JIT
// readiness itself is still confirmed through the existing
// breakpoint protocol.
- (void)enableJITWithCompletion:(TXStikJITResultHandler)completion;

// Best-effort auto-enable for the guest start path: when the
// selected method is Built-in StikJIT and no debugger is attached
// yet, runs the enable flow in the background, once per launch.
// Never blocks the boot and never throws: a failure is logged and
// recorded in lastAutoEnableStatusText, and the guest boots
// without JIT. No-op in LiveContainer, for the StikDebug method,
// without stored pairing, or when JIT is already on.
- (void)autoEnableJITBestEffort;

// Ask the helper to delete its cached Developer Disk Image files.
// The next preparation re-downloads them.
- (void)resetCachedDDIWithCompletion:(TXStikJITResultHandler)completion;

// --- StikDebug URL method ---

// stikdebug://enable-jit?bundle-id=<bundle>&pid=<pid>&script-name=universal.js
// with the bundle ID from Bundle.main and the current PID. The
// script name is the one developer-configured script.
- (nullable NSURL *)stikDebugURL;
// YES when iOS reports the StikDebug URL scheme openable
// (requires "stikdebug" in LSApplicationQueriesSchemes).
- (BOOL)canOpenStikDebug;
// Open the StikDebug URL. `accepted` is YES only when iOS
// accepted the request; it is not JIT success.
- (void)openStikDebugWithCompletion:(void (^)(BOOL accepted))completion;

@end

NS_ASSUME_NONNULL_END
