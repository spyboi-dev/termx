// TXBackgroundKeepAlive - keep the guest running while the app is
// in the background: the Swipterm "caffeinate" idea, adapted to TermX.
//
// A background CLLocationManager session at 3 km accuracy with the
// distance filter at maximum keeps iOS from suspending the app, so
// the guest keeps running instead of being quiesced on background
// (see KernEngine enterBackground). The location itself is never
// used: the delegate ignores every fix, nothing is read, stored, or
// sent anywhere — the session exists only to keep the app alive.
// 3 km accuracy means the OS answers from cell and Wi-Fi, never a
// GPS fix, so the battery cost is the session itself, not
// positioning.
//
// It only keeps the app alive with Always authorization. WhenInUse
// stops delivering once the app backgrounds, so the guest still
// suspends until the user picks Always. The first enable asks
// WhenInUse, then asks for the Always upgrade while the app is in
// the foreground.
//
// Off by default; the About screen has the switch. The guest side
// has no `caffeinate` command: Swipterm's reaches the host through
// its engine's host-command channel, which Kernarium does not have,
// so the About switch is the only control.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

// NSUserDefaults key for the switch. @"termx.backgroundKeepAlive".
extern NSString * const kTXBackgroundKeepAliveDefaultsKey;

@interface TXBackgroundKeepAlive : NSObject

+ (instancetype)shared;

// The About switch. Persisted; turning it on starts the
// authorization flow and reconciles.
- (BOOL)isEnabled;
- (void)setEnabled:(BOOL)enabled;

// YES only while a location session is actually running with Always
// authorization — the state the engine's background quiesce checks
// before suspending the guest.
- (BOOL)isKeepingAlive;

// Re-run the start/stop decision. Called on enable, on guest state
// change, on authorization change, and on foreground/background.
- (void)reconcile;

@end
