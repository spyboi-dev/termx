// TXOnDevicePairing - on-device pairing for Built-in StikJIT.
//
// iOS 27 can pair with a computer it finds on the local network,
// started from the iPhone: Settings > Privacy & Security >
// Developer Mode lists every _remotepairing-pairable-host._tcp
// service, and pairing with one asks for the PIN that host shows.
// TermX plays that computer for its own iPhone: libtx_rppairing
// (termx/rppairing, idevice's PairableHost) listens on a port and
// runs the pairing; this class publishes the port through
// mDNSResponder (dns_sd, so only the Local Network permission is
// needed) and stores the resulting pairing bytes in the Keychain
// (TXPairingStore).
//
// The user pairs from Settings, so TermX has to keep running in
// the background: a BGContinuedProcessingTask
// ("app.termx.ios.pairing.session", permitted by
// "app.termx.ios.pairing.*" in Info.plist) whose system progress UI
// also shows the PIN. When iOS refuses it, only the short
// background grace period remains, and the UI says so. The PIN is
// also sent as a local notification.
//
// Pairing is iOS 27 and later; TermX's minimum is 27.0, so it is
// always available here. When the pairing library is not in the
// build (host-only build without termx/rppairing-artifact/), start
// fails with "Pairing library missing" and the file import stays
// the only path.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TXOnDevicePairingPhase) {
    TXOnDevicePairingPhaseIdle = 0,
    // Advertised; the user pairs from Settings.
    TXOnDevicePairingPhaseWaiting,
    // The iPhone asked for the code.
    TXOnDevicePairingPhasePIN,
    TXOnDevicePairingPhasePaired,
    TXOnDevicePairingPhaseFailed,
};

typedef void (^TXOnDevicePairingPINHandler)(NSString *pin);
typedef void (^TXOnDevicePairingCompletionHandler)(BOOL success, NSString * _Nullable deviceName, NSString * _Nullable message);

@interface TXOnDevicePairing : NSObject

+ (instancetype)shared;

+ (BOOL)isSupported;

// The host name shown on the iPhone as "Pair with TermX".
+ (NSString *)hostName;

// 5 minutes: the pairing attempt times out and the user retries
// when ready to pair from Settings.
+ (NSTimeInterval)timeout;

@property (nonatomic, readonly) TXOnDevicePairingPhase phase;
@property (nonatomic, readonly, copy, nullable) NSString *pin;
@property (nonatomic, readonly, copy, nullable) NSString *pairedDeviceName;
// iOS refused the continued-processing task: TermX can only wait
// briefly in the background.
@property (nonatomic, readonly) BOOL backgroundLimited;
@property (nonatomic, readonly) BOOL active;

// Callbacks, set by the UI before start. onPIN runs on the main
// queue when the iPhone asks for the code; completion runs on the
// main queue once, with success and the paired device name, or
// failure and the reason.
@property (nonatomic, copy, nullable) TXOnDevicePairingPINHandler onPIN;
@property (nonatomic, copy, nullable) TXOnDevicePairingCompletionHandler completion;

// Starts advertising and waits for the user to pair from Settings.
// Does nothing when a pairing is already running.
- (void)start;

// Stops a pairing in progress. `reason` is shown as the failure;
// nil returns to idle.
- (void)cancelWithReason:(nullable NSString *)reason;

@end

NS_ASSUME_NONNULL_END
