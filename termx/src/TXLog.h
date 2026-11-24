// TXLog - the in-app log hub.
//
// Two files, both under Documents/Engine/:
//   engine.log - timestamped lines: engine state changes, install
//     and download progress, boot phases, startup lines. Written by
//     TXLogEngine().
//   guest.log  - the guest's raw serial console output, byte for
//     byte, no timestamps added (the console is its own record).
//     Written by TXLogConsoleData().
//
// Both files are capped: once one passes 512 KB only the last
// 256 KB is kept, starting at a line boundary, so a chatty guest
// cannot grow them forever. All writes run on one serial queue, so
// appends from any thread (main, console callback, download
// watcher) cannot interleave. A logging failure must never break
// the engine, so every failure is swallowed silently.
//
// The crash recorder (TXCrashLog) appends to the same engine.log
// through its own O_APPEND fd; both writers only ever append, so
// they coexist the same way they do in the OpenCode app.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Append one timestamped line ("[HH:MM:SS] <line>") to engine.log.
// Safe from any thread.
void TXLogEngine(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Debug logging, off by default. The NSUserDefaults key is
// kTXDebugLoggingDefaultsKey ("termx.debugLogging"); the About
// screen exposes it as a switch, so it can be turned on for
// diagnosis without a rebuild. TXLogDebug writes to engine.log
// only when the flag is on, and reads it fresh on every call, so
// flipping the switch takes effect at once. It gates the verbose
// diagnostic lines only: the memory sampler and the session-record
// slot dumps. Errors, state changes, boot progress and the guest
// console always log, whatever the flag says.
extern NSString * const kTXDebugLoggingDefaultsKey;
BOOL TXLogDebugEnabled(void);
void TXLogDebug(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Block until every line queued so far is on disk. Safe from any
// thread except the log queue itself. Use at phase boundaries where
// the next step can kill the process (see GuestInstall): without it
// a crash a millisecond later leaves the last line the async queue
// happened to flush, not the true phase.
void TXLogFlush(void);

// Append raw guest console bytes to guest.log. Safe from any thread
// (the runtime's console callback runs on a runtime thread).
void TXLogConsoleData(NSData *data);

// Paths of the two log files.
NSString *TXLogEngineLogPath(void);
NSString *TXLogGuestLogPath(void);

// Capture the process's own stdout/stderr (fd 1/2) into engine.log:
// the Kernarium runtime prints the exact reason a boot fails there
// ("Kernarium: invalid display geometry", "emulator creation
// failed: %d", ...), and the app never saw it — every failed boot
// arrived as a bare "Guest run failed (-1)". Installs a pipe, dup2s
// it onto fds 1 and 2, and forwards lines to TXLogEngine with a
// "runtime: " prefix. The write end is non-blocking and SIGPIPE is
// ignored, so a stalled reader can only drop lines, never stall the
// boot thread. Safe from any thread; call once, early in main().
void TXLogCaptureRuntimeOutput(void);

// Full diagnostic text for the in-app log view: the engine log,
// then the guest console log. Missing files read as empty.
NSString *TXLogFullText(void);

// Human byte size: "116 MB", "1.0 GiB", "128 MiB".
NSString *TXFormatBytes(unsigned long long bytes);

// This process's current physical memory footprint, in bytes
// (0 when it cannot be read). Used to log memory pressure next to
// the download/install byte counts, so a jetsam kill leaves the
// footprint it died at.
unsigned long long TXCurrentFootprintBytes(void);

NS_ASSUME_NONNULL_END
