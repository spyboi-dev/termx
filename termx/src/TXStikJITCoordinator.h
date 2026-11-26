// TXStikJITCoordinator - host side of Built-in StikJIT and the
// one router for all three JIT methods.
//
// TermX's JIT allocator (Kernarium) already implements the
// universal brk #0xf00d protocol, so the host only has to acquire
// JIT, never to change the allocator. The three mutually exclusive
// methods, persisted in NSUserDefaults under "termx.jitMethod":
//
//   Built-in StikJIT  - this coordinator + the StikJIT helper
//     extension (via TXStikJITTransport). Recommended when
//     available. Unavailable below iOS 17.4 and inside
//     LiveContainer, which cannot create the helper extension.
//   StikDebug URL     - opens stikdebug://enable-jit with this
//     app's bundle ID, current PID, and script-name=universal.js.
//     Opening the URL only confirms iOS accepted the request.
//   Wait for Debugger - the existing Swipt client (TXJITManager).
//     This coordinator does not own that flow; it only routes to
//     it by method selection.
//
// Before any Built-in StikJIT work the host checks, in its own
// process (the entitlement belongs to the host PID, so checking
// from the helper would check the wrong executable):
//   1. iOS 17.4 or later,
//   2. get-task-allow == true (Security framework SPI),
//   3. a pairing file at Documents/StikJIT/pairingFile.plist.
// The host app never strongly links StikJIT: the framework lives
// in the helper extension only, and all helper traffic goes
// through TXStikJITTransport (currently a stub reporting the
// helper as unavailable; see that file).
//
// The pairing file is only ever copied as opaque bytes and is
// never logged. The configured script is .universal, fixed in
// backend code; it is not a user setting.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "TXStikJITTransport.h"

NS_ASSUME_NONNULL_BEGIN

// Persisted JIT method. Stored as an integer under
// kTXStikJITMethodDefaultsKey ("termx.jitMethod").
typedef NS_ENUM(NSInteger, TXStikJITMethod) {
    TXStikJITMethodBuiltInStikJIT = 0,
    TXStikJITMethodStikDebug = 1,
    TXStikJITMethodWaitForDebugger = 2,
};

extern NSString *const kTXStikJITMethodDefaultsKey;
extern NSString *const kTXStikJITForceScriptDefaultsKey;

// Readiness of the Built-in StikJIT path.
typedef NS_ENUM(NSInteger, TXStikJITReadiness) {
    // Preflight passed and the helper reported Ready.
    TXStikJITReadinessReady = 0,
    // Preflight failed (OS, get-task-allow, or pairing file);
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

// The selected method, corrected for the environment: when in
// LiveContainer a stored Built-in selection reads as Wait for
// Debugger (see applyLiveContainerDefaultIfNeeded, which persists
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

// --- Pairing file ---

// Documents/StikJIT/pairingFile.plist.
+ (NSURL *)pairingFileURL;
- (BOOL)pairingFileExists;
// The imported filename ("pairingFile.plist"), or nil when none
// is imported. Only the filename is ever shown or logged.
- (nullable NSString *)pairingFileName;
// "pairingFile.plist" when imported, "Not imported" otherwise.
- (NSString *)pairingFileStatusText;
// Raw pairing-file bytes for the transport. Never logged.
- (nullable NSData *)readPairingFileDataWithError:(NSError **)error;
// Copy a picked file to Documents/StikJIT/pairingFile.plist,
// replacing atomically. Uses security-scoped access while
// copying; never logs the file contents. Changing the pairing
// file clears the last prepare status. Completion is on the main
// queue with success and a short status string.
- (void)importPairingFileFromURL:(NSURL *)sourceURL
                      completion:(void (^)(BOOL success, NSString *statusText))completion;

// TXM/SPTM status from the helper (Unknown while the transport
// is a stub). Informational only; the script stays .universal.
- (TXStikJITTXMStatus)txmSPTMStatus;
- (NSString *)txmSPTMStatusText;

// Last prepare/enable status text, for the About card to show
// across appearances. Cleared when the pairing file changes.
@property (nonatomic, readonly, copy, nullable) NSString *lastPrepareStatusText;

// Run the preflight, then ask the helper to prepare the device
// (reachability, DDI mount, TXM detection). Do not require the
// user to prepare before enabling: enableJIT does preparation
// itself. In LiveContainer this returns HelperUnavailable
// without launching anything.
- (void)prepareJITWithCompletion:(TXStikJITReadinessHandler)completion;

// Run the preflight, then ask the helper to enable JIT for this
// process with the .universal script. Success here means the
// helper completed enablement; JIT readiness itself is still
// confirmed through the existing breakpoint protocol.
- (void)enableJITWithCompletion:(TXStikJITResultHandler)completion;

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
