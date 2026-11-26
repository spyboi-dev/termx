// TXStikJITTransport - host <-> StikJIT helper transport.
//
// The Built-in StikJIT helper is a separate app extension (Swift,
// StikJIT is Swift-only) that the host app must NOT strongly link.
// This class is the single seam between the host coordinator
// (TXStikJITCoordinator) and whatever carries PID + pairing-file
// data to that helper and progress + results back. The coordinator
// only ever talks to this interface; it never touches the helper
// directly.
//
// The transport launches the helper with NSExtension's private
// calls (there is no public API to start an app's own classic
// extension): it looks the extension up by bundle ID, begins a
// request whose input item's userInfo is {op, pid, pairing,
// forceScript}, and takes the reply item's userInfo {ok, summary,
// log}. The helper is a second process because a process that
// attaches a debugger to itself deadlocks. helperAvailable is YES
// only when the .appex is embedded in this app; a launch failure
// still reports why. TXM/SPTM status is parsed from the helper's
// prepare summary ("ready, TXM present" / "ready, no TXM") and
// stays Unknown until a prepare has actually answered.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TXStikJITTransportErrorDomain;

typedef NS_ENUM(NSInteger, TXStikJITTransportError) {
    // No helper extension is reachable (stub: always).
    TXStikJITTransportErrorHelperUnavailable = 1,
    TXStikJITTransportErrorInvalidRequest = 2,
};

// The outcome of one helper operation. success is YES only when
// the helper actually completed the operation; a stub call always
// returns success = NO with statusText explaining why.
@interface TXStikJITTransportResult : NSObject

@property (nonatomic, readonly) BOOL success;
@property (nonatomic, readonly, copy) NSString *statusText;
@property (nonatomic, readonly, nullable) NSError *error;

+ (instancetype)successWithStatusText:(NSString *)statusText;
+ (instancetype)failureWithError:(NSError *)error statusText:(NSString *)statusText;

@end

// TXM/SPTM presence as reported by the helper. Unknown until the
// helper has actually answered (the stub always reports Unknown).
typedef NS_ENUM(NSInteger, TXStikJITTXMStatus) {
    TXStikJITTXMStatusUnknown = 0,
    TXStikJITTXMStatusPresent,
    TXStikJITTXMStatusNotPresent,
};

NSString *TXStikJITTXMStatusText(TXStikJITTXMStatus status);

// Progress callback: one short stage string, e.g. "Downloading DDI".
typedef void (^TXStikJITProgressHandler)(NSString *stage);
// Completion callback: always invoked, on the main queue.
typedef void (^TXStikJITCompletionHandler)(TXStikJITTransportResult *result);

@interface TXStikJITTransport : NSObject

+ (instancetype)shared;

// YES only when the helper extension is embedded in this app.
// It does not prove iOS will launch it (in LiveContainer the
// coordinator never asks); a launch failure still reports why.
@property (nonatomic, readonly) BOOL helperAvailable;

// Last TXM/SPTM status the helper reported. Unknown until a
// prepare has actually answered.
@property (nonatomic, readonly) TXStikJITTXMStatus txmSPTMStatus;

// Ask the helper to run StikJIT.prepareDevice. Runs the helper's
// blocking preparation (reachability, DDI mount, TXM detection).
// pairingData is the raw pairing-file bytes; it is never logged.
- (void)prepareJITWithPID:(pid_t)pid
              pairingData:(NSData *)pairingData
              forceScript:(BOOL)forceScript
                 progress:(nullable TXStikJITProgressHandler)progress
               completion:(TXStikJITCompletionHandler)completion;

// Ask the helper to run StikJIT.enableJIT for the host PID with
// the configured script (.universal). Performs preparation itself;
// callers do not need to prepare first.
- (void)enableJITWithPID:(pid_t)pid
             pairingData:(NSData *)pairingData
             forceScript:(BOOL)forceScript
                progress:(nullable TXStikJITProgressHandler)progress
              completion:(TXStikJITCompletionHandler)completion;

// Ask the helper to run StikJIT.resetCachedDDI: removes only the
// cached DDI files, so the next preparation re-downloads them.
- (void)resetCachedDDIWithCompletion:(TXStikJITCompletionHandler)completion;

@end

NS_ASSUME_NONNULL_END
