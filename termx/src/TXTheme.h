// TXTheme - the one shared TermX look. Every screen (startup, terminal,
// log) reads its colours and terminal font from here, so the app has a
// single dark theme and the pieces cannot drift apart again (the
// terminal used to be pure black while the startup screen was pure
// black with a different text white, and the placeholder once rendered
// black-on-black because it used the text view's default colour).
//
// The theme is pure black: #000000 background with #E6EDF3 text, at
// the user's direction (he asked for a black background, 2026-11-23).
// xterm black as a foreground still renders as a dim grey, and colour
// 0 in the palette is pure black too, so black-background cells blend
// into the screen instead of reading as holes.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// App background: every full-screen view. Pure black.
static inline UIColor *TXThemeBackgroundColor(void) {
    return [UIColor blackColor];
}

// Default terminal / log text: soft white, never pure white.
static inline UIColor *TXThemeForegroundColor(void) {
    return [UIColor colorWithRed:0xE6 / 255.0 green:0xED / 255.0 blue:0xF3 / 255.0 alpha:1.0];
}

// The one accent: Andarium teal, used for the startup checks, the
// progress bar, and the terminal's jump-to-bottom control.
static inline UIColor *TXThemeAccentColor(void) {
    return [UIColor colorWithRed:0x2A / 255.0 green:0xB3 / 255.0 blue:0xA3 / 255.0 alpha:1.0];
}

// The terminal font size, persisted across launches. Default 14 pt.
// Pinch to zoom changes it (see TerminalViewController); the font is
// built from this size everywhere, so one change re-renders the whole
// terminal. Clamped to 10–24 pt: smaller and the text is unreadable,
// larger and a single line no longer fits the screen.
static inline CGFloat TXTermFontSize(void) {
    CGFloat size = [[NSUserDefaults standardUserDefaults] doubleForKey:@"termx.fontSize"];
    if (size < 10 || size > 24) return 14;
    return size;
}
static inline void TXSetTermFontSize(CGFloat size) {
    if (size < 10) size = 10;
    if (size > 24) size = 24;
    [[NSUserDefaults standardUserDefaults] setDouble:size forKey:@"termx.fontSize"];
}

// The one terminal font: system monospace at the current size. The
// text view, the placeholder, and the flush renderer must all use
// this — a size or weight set in only one place is how the
// placeholder once rendered in the wrong colour and the grid in
// another size.
static inline UIFont *TXTermFont(void) {
    return [UIFont monospacedSystemFontOfSize:TXTermFontSize() weight:UIFontWeightRegular];
}

NS_ASSUME_NONNULL_END
