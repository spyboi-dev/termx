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
#import "TXConfig.h"

NS_ASSUME_NONNULL_BEGIN

// App background: every full-screen view. Pure black.
static inline UIColor *TXThemeBackgroundColor(void) {
    return [UIColor blackColor];
}

// Default terminal / log text: soft white, never pure white.
static inline UIColor *TXThemeForegroundColor(void) {
    return [UIColor colorWithRed:0xE6 / 255.0 green:0xED / 255.0 blue:0xF3 / 255.0 alpha:1.0];
}

// The one accent: Andarium teal, used for the startup checks and
// the progress bar.
static inline UIColor *TXThemeAccentColor(void) {
    return [UIColor colorWithRed:0x2A / 255.0 green:0xB3 / 255.0 blue:0xA3 / 255.0 alpha:1.0];
}

// Shared grey scale: every screen reads its greys from here, so the
// same role is the same value everywhere. The card and the log view
// share one background (0.11); the progress track shares the button
// background (0.22).
static inline UIColor *TXThemeCardBackground(void) {
    return [UIColor colorWithWhite:0.11 alpha:1.0];
}

static inline UIColor *TXThemeButtonBackground(void) {
    return [UIColor colorWithWhite:0.22 alpha:1.0];
}

// Separator hairline: white at 8% alpha, not opaque 0.08 grey —
// over the 0.11 card it composites lighter than the card, while an
// opaque 0.08 would render darker than the card.
static inline UIColor *TXThemeSeparatorColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.08];
}

static inline UIColor *TXThemeSecondaryTextColor(void) {
    return [UIColor colorWithWhite:0.6 alpha:1.0];
}

// Guest-dead notice pill background.
static inline UIColor *TXThemePillBackground(void) {
    return [UIColor colorWithWhite:0.15 alpha:1.0];
}

// Dimmed elements: pending row icon border and title, header dot.
static inline UIColor *TXThemeDimmedColor(void) {
    return [UIColor colorWithWhite:0.5 alpha:1.0];
}

// Failure-reason label on the startup screen.
static inline UIColor *TXThemeReasonTextColor(void) {
    return [UIColor colorWithWhite:0.65 alpha:1.0];
}

// Corner radii: one token per radius. The 5 pt status dot is not
// tokenized: it is half of the 10 pt dot, a derived value.
static const CGFloat TXThemeCornerRadiusPill = 8.0;
static const CGFloat TXThemeCornerRadiusButton = 12.0;
static const CGFloat TXThemeCornerRadiusLog = 18.0;
static const CGFloat TXThemeCornerRadiusCard = 24.0;

// Shared heights: the primary button height, and the startup
// checklist row height.
static const CGFloat TXThemePrimaryButtonHeightPt = 48.0;
static const CGFloat TXThemeChecklistRowHeightPt = 68.0;

// The terminal font size, persisted across launches. Default 14 pt.
// Pinch to zoom changes it (see TerminalViewController); the font is
// built from this size everywhere, so one change re-renders the whole
// terminal. Clamped to Termux's range, 4-256 pt.
static inline CGFloat TXTermFontSize(void) {
    CGFloat size = [[NSUserDefaults standardUserDefaults] doubleForKey:@"termx.fontSize"];
    if (size < TXConfigTermFontSizeMin || size > TXConfigTermFontSizeMax) return TXConfigTermFontSizeDefault;
    return size;
}
static inline void TXSetTermFontSize(CGFloat size) {
    if (size < TXConfigTermFontSizeMin) size = TXConfigTermFontSizeMin;
    if (size > TXConfigTermFontSizeMax) size = TXConfigTermFontSizeMax;
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
