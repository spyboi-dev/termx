// TXGuestFlow - the startup flow state for one launch.
//
// The engine owns the guest state (TermXState: Idle, Ready, Booting,
// Running, ...), but the startup screen also has to remember what the
// automatic flow has already done this launch: whether the one
// automatic boot ran, whether the one automatic retry was used,
// whether the terminal was already presented, whether an update is
// waiting for the guest to stop. Those flags used to live as eight
// booleans on TXStartupViewController, scattered through its methods,
// so no one place could answer "what is the guest doing and what
// happens next". They live here now, in one object owned by the
// engine (KernEngine.flow), so the flow state and the guest state are
// read from the same place.
//
// The split is not fully gone: the engine owns the flow *state*, but
// the startup screen still owns the flow *decisions* (maybeAutoBoot,
// maybeScheduleBootRetry, maybePresentTerminal, maybeStartPendingUpdate)
// — those present UI and need the guest view, which the engine does
// not have. Moving the decisions would mean handing the view to the
// engine and re-timing the whole flow; that is a bigger refactor with
// real behaviour risk, and it is deferred, not forgotten. What this
// object buys today: one place holds the state, and every reset goes
// through a named transition below instead of three flags set in six
// places.
//
// All access is on the main thread, like the view controller that
// drove it before. The engine never touches this object from its
// background queues.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TXGuestFlow : NSObject

// One automatic boot per launch (see maybeAutoBoot). Set once the
// boot starts; a manual Start or a fresh Install clears it, so the
// Ready state it ends in boots by itself again.
@property (nonatomic, assign) BOOL autoBootDone;

// One automatic retry if a boot fails (see maybeScheduleBootRetry).
// bootRetryScheduled is YES while the 5 s retry timer is pending;
// bootRetryUsed is YES once the retry has fired. A manual Start or
// a fresh Install clears both, so the new boot earns its retry.
@property (nonatomic, assign) BOOL bootRetryUsed;
@property (nonatomic, assign) BOOL bootRetryScheduled;

// First tick the guest view had no size, while the auto-boot waits
// for layout. Nil when not deferred. After 10 s the auto-boot goes
// ahead anyway, so the pre-flight names the failure on screen.
@property (nonatomic, strong, nullable) NSDate *autoBootDeferredSince;

// The terminal was presented once for this Running state. Coming
// back from the terminal (swipe down) must not re-trigger it.
@property (nonatomic, assign) BOOL terminalPresented;

// The shell came up while the log screen was open: present the
// terminal when the log closes instead of yanking it away.
@property (nonatomic, assign) BOOL presentAfterLogCloses;

// YES once the user tapped Update while the guest was running and
// the guest was asked to stop; the install starts when the state
// actually reaches Stopped. The pipeline replaces the image file,
// which must never happen under a running guest.
@property (nonatomic, assign) BOOL updateAfterStop;

// The user chose Start anyway / Start fresh for this launch's
// crash, so the auto-boot hold (see KernEngine.lastSessionCrashed)
// is released. Never cleared within a launch.
@property (nonatomic, assign) BOOL crashAcknowledged;

// Fresh automatic flow: a manual Install, an Update, or a pending
// update starting all earn a new automatic boot and a new automatic
// retry if that boot fails.
- (void)resetForInstall;

// Fresh automatic retry only: a manual Start earns a new retry if
// this boot fails, but does not re-arm the automatic boot itself.
- (void)resetRetry;

// Record the user's crash choice (Start anyway / Start fresh).
- (void)acknowledgeCrash;

@end

NS_ASSUME_NONNULL_END
