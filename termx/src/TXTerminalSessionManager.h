// TXTerminalSessionManager - multiple terminal windows (sessions) for
// TermX, backed by tmux in the guest.
//
// TermX has one guest console and one Ghostty surface. tmux multiplexes
// that console: each TermX window is a tmux window, and the host
// switches windows by sending tmux commands. The surface never changes;
// tmux redraws it for the new window, and per-window scrollback lives
// in tmux. No guest agent, no new host-guest channel.
//
// How the host talks to tmux (all keystrokes into the console):
//   start (first +): the shell runs
//     tmux new-session -A -s termx -n termx-1 \; new-window -n termx-N
//   which attaches the console to a new tmux session with two windows
//   and lands on the new one. -A attaches to an existing "termx"
//   session instead of failing, so an app relaunch over a persisted
//   guest still works.
//   create (tmux running): the tmux command prompt (prefix + ":"),
//   then "new-window -n termx-N", then Enter. The prompt is tmux UI,
//   so it works even inside a full-screen app.
//   switch: command prompt, "select-window -t <name>", Enter.
//   close: command prompt, "kill-window -t <name>", Enter, then an
//   explicit select-window to a survivor so host and tmux agree on
//   which window is current (tmux would otherwise pick one itself).
//
// Names: tmux window names are unique and stable ("termx-1",
// "termx-2", ...) from a persisted counter, so they never collide
// across relaunches. Display names are positional ("iphone",
// "iphone 2", ...) and re-derive when a window closes.
//
// The first start types a command into the shell, so it only runs
// when the shell is at a prompt (isShellAtPrompt, from the visible
// screen). Otherwise the user gets an alert instead of text typed
// into whatever app is running.
//
// tmux is not in the current system image (fix8): it has to be
// added to the image (configure-rootfs-slim.sh) and the image
// rebuilt. Until then, starting tmux prints "command not found" and
// the manager reverts to a single session with an alert (see
// checkConsoleOutputForTmuxFailure:). The last session can never
// be closed; the X is hidden when only one remains.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

@class TXGhosttyView;
@class TXTerminalSession;

@protocol TXTerminalSessionManagerDelegate <NSObject>
// Sessions, current index, or tmux state changed: refresh the top
// bar title and the sidebar list.
- (void)sessionManagerDidUpdateSessions:(id)manager;
// Show an alert (tmux missing, shell not at a prompt).
- (void)sessionManager:(id)manager showAlertWithTitle:(NSString *)title message:(NSString *)message;
@end

@interface TXTerminalSession : NSObject
// Stable tmux window name, e.g. "termx-1". Never reused.
@property (nonatomic, copy, readonly) NSString *tmuxName;
// Positional display name, e.g. "iphone", "iphone 2".
@property (nonatomic, copy, readonly) NSString *displayName;
- (instancetype)initWithTmuxName:(NSString *)tmuxName displayName:(NSString *)displayName;
@end

@interface TXTerminalSessionManager : NSObject

// The Ghostty surface the tmux keystrokes go through. Set by the
// terminal view controller; weak, the controller owns both.
@property (nonatomic, weak) TXGhosttyView *output;
@property (nonatomic, weak) id<TXTerminalSessionManagerDelegate> delegate;

@property (nonatomic, readonly) NSArray<TXTerminalSession *> *sessions;
@property (nonatomic, readonly) NSUInteger currentIndex;
@property (nonatomic, readonly) TXTerminalSession *currentSession;
// YES once tmux has been started (first +). NO before that, and
// after a reset.
@property (nonatomic, readonly) BOOL tmuxStarted;
// YES while a tmux start command is in flight (for the missing-
// tmux detection).
@property (nonatomic, readonly) BOOL tmuxStartPending;

// The + button: start tmux and open a second window (first time),
// or open a new tmux window (later). No-op when the shell is not
// at a prompt on the first start (alert instead).
- (void)createSession;
// Switch the visible tmux window to the session at index.
- (void)switchToSessionAtIndex:(NSUInteger)index;
// Close the session at index. No-op when it is the only one.
- (void)closeSessionAtIndex:(NSUInteger)index;
// Back to one plain-shell session (guest rebooted, tmux gone).
- (void)resetToSingleSession;

// Called from the terminal's live console-output handler with each
// chunk. While a tmux start is pending, "command not found" means
// tmux is not installed: revert to one session and alert.
- (void)checkConsoleOutputForTmuxFailure:(NSData *)data;

// YES when the visible screen ends at the shell prompt, so typing
// the tmux start command is safe. Used only for the first start.
- (BOOL)isShellAtPrompt;

@end
