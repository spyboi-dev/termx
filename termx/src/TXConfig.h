// TXConfig - the one place for the app's tuning constants.
//
// Before Phase 5 these values were literals scattered across the
// source (a 0.06 here, a 1024 there, a 10000 in the terminal), so
// two copies of the same number could drift apart and nobody could
// tell which 44 was the hide-keyboard width and which was the
// exit-pan strip. Every value here is unchanged from what it was
// as a literal — this file only names them. Change a value here and
// it changes everywhere it is used; change a value in only one
// call site and the two copies drift again.
//
// Two constants deliberately stay where they are, and are named
// there instead:
//   - The scrollback cap (2000 lines) stays VT_SCROLLBACK_MAX in
//     vt.h: vt.h is shared with CrateTerm, and coupling it to this
//     header would break that sharing.
//   - The startup flow timings (5 s boot retry, 0.7 s terminal
//     present, 10 s auto-boot defer) stay in
//     TXStartupViewController.m next to the flow they tune.
// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef TERMX_TXCONFIG_H
#define TERMX_TXCONFIG_H

// Terminal font size (TXTheme.h): the pinch-zoom clamp and the
// default. Smaller and the text is unreadable; larger and a single
// line no longer fits the screen.
#define TXConfigTermFontSizeMin 10.0
#define TXConfigTermFontSizeMax 24.0
#define TXConfigTermFontSizeDefault 14.0

// Line spacing at the default font size: the paragraph style scales
// it linearly with the size (size * TXConfigTermLineSpacingPt /
// TXConfigTermFontSizeDefault), so a pinch-zoomed terminal keeps
// the same proportions.
#define TXConfigTermLineSpacingPt 2.0

// Terminal render loop: the flush timer interval. The guest sends a
// few bytes at a time and redrawing on every one would thrash.
#define TXConfigTerminalFlushIntervalSec 0.06

// Arrow-key hold-to-repeat: the initial delay before repeating
// starts, then the repeat interval (12.5 Hz).
#define TXConfigArrowRepeatInitialDelaySec 0.4
#define TXConfigArrowRepeatIntervalSec 0.08

// I/O chunk sizes, in bytes. Paste is split into chunks because the
// guest tty input buffer is 4096 bytes; the boot-log replay is fed
// in chunks the way the runtime delivers live output. Same value,
// different purposes — hence two names, so one can change without
// the other.
#define TXConfigPasteChunkBytes 1024
#define TXConfigReplayChunkBytes 1024

// Pinch to zoom: changes smaller than this are ignored, so
// recognizer jitter does not resize the font under a steady finger.
#define TXConfigPinchDeadZonePt 0.1

// Key rows: every row (Fn, secondary, primary) is this tall.
// 42 pt matches the iOS keyboard's own key height, so the
// terminal keys read as keyboard keys, not a thin strip.
#define TXConfigKeyRowHeightPt 42.0

// Exit pan (swipe down from the terminal back to the startup
// screen): the drag must start in this strip at the top of the
// screen, and travel at least this far down, while the scrollback
// is already at its top.
#define TXConfigExitPanTopStripPt 44.0
#define TXConfigExitPanTranslationThresholdPt 80.0

// Pinned-to-bottom: the terminal auto-follows new output while the
// scroll offset is within this distance of the bottom.
#define TXConfigPinnedToBottomThresholdPt 16.0

// Text container width: long lines never wrap — the container is
// this wide, so they scroll horizontally instead. Re-asserted on
// every layout (see TerminalViewController).
#define TXConfigTextContainerWidthPt 10000.0

// Image install: free space required before starting the download
// (the .gz is ~116 MB, plus room for the download itself) and
// before extracting (the extracted image is exactly 1 GiB, plus
// room for the side file while it is written).
#define TXConfigFreeSpaceNeededBeforeDownloadBytes (1ULL << 30)
#define TXConfigFreeSpaceNeededBeforeExtractBytes (3ULL << 29)

// Memory sampler (KernEngine): the fine-grained interval during
// the boot window, and the slow interval once the guest is up.
// A long session needs only a trace — enough that a jetsam an
// hour in still leaves recent lines in engine.log.
#define TXConfigSamplerIntervalBootMs 100
#define TXConfigSamplerIntervalRunningMs 5000

// Console replay buffer (KernEngine): the most recent output kept
// in memory so a terminal presented later can still show the boot
// log and the login prompt. Older bytes are dropped from the front.
#define TXConfigConsoleBufferMaxBytes (128 * 1024)

#endif
