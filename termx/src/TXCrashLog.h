// TXCrashLog - best-effort crash recorder.
//
// Installs an uncaught-exception handler and fatal-signal handlers
// (SIGSEGV, SIGABRT, SIGBUS, SIGILL) that append one line to the
// engine log file (Documents/Engine/engine.log) and write a
// separate, easy-to-find Documents/CRASH.txt (overwritten on each
// crash) with the signal/exception, a timestamp, and the last few
// engine-log lines.
//
// The signal path uses only async-signal-safe calls (write, open,
// read, lseek, close, time) on fds/paths fixed at install time: no
// ObjC, no allocation, no locks, so it can run while the process is
// dying. After writing, the default handler is restored and the
// signal re-raised, so iOS still produces its normal crash report
// (.ips, in a system location outside the sandbox — the app cannot
// move that file into its data folder; CRASH.txt + engine.log are
// the in-sandbox record instead).
//
// Install FIRST THING in main(), before UIApplicationMain: any
// crash from the first milliseconds on is then captured, including
// one inside a framework loaded later. Never crashes the app from
// the logging code itself: if the fd is not open, every function is
// a no-op.
//
// Unclean exits: iOS kills (jetsam, SIGKILL) run no handler at all,
// so they leave no CRASH line. The app therefore writes a CLEAN
// SHUTDOWN marker when it backgrounds or terminates, and a
// FOREGROUND marker when it returns. On launch, if the previous
// run's log has neither a CRASH line nor a clean end (i.e. the app
// did work after its last clean shutdown and then ended), a
// "Previous run ended without shutdown" line is appended, so a
// jetsam kill is distinguishable from broken logging.
//
// Adapted from the same author's OCCrashLog in the OpenCode iOS app
// (same design, TermX paths and names).
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Install the handlers for the log at logPath. Creates the parent
// directory if needed. Safe to call twice; the second call is a no-op.
void TXCrashLogInstall(NSString *logPath);

// Install first thing in main(): computes the default log path
// (Documents/Engine/engine.log), installs the handlers, checks the
// previous run for an unclean end, and writes the launch line.
// Safe to call twice; the second call is a no-op.
void TXCrashLogInstallEarly(void);

// Mark a clean shutdown (call on entering background and on
// terminate). A no-op when the handlers were never installed.
void TXCrashLogMarkCleanShutdown(void);

// Mark a return to the foreground, so a clean-shutdown marker from
// an earlier backgrounding cannot mask later foreground work.
void TXCrashLogMarkForeground(void);

NS_ASSUME_NONNULL_END
