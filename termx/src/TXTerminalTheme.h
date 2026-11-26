// TXTerminalTheme - preset terminal color themes for the Ghostty
// Configuration detail in Settings.
//
// Each theme is a set of Ghostty config color lines (background,
// foreground, cursor, selection). The selected theme is persisted
// and written into the live Ghostty config file
// (Documents/ghostty-config.conf), the same file Ghostty reads at
// surface creation. The app owns only these color keys in that
// file; every other line the user may have added in Files is kept.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef struct {
    const char *name; // display name, e.g. "One Dark"
    const char *background; // hex, e.g. "#282c34"
    const char *foreground;
    const char *cursorColor;
    const char *selectionBackground;
    const char *selectionForeground;
} TXTerminalTheme;

extern const TXTerminalTheme TXTerminalThemes[];
extern const NSInteger TXTerminalThemeCount;

// The selected theme index, persisted in NSUserDefaults.
// Default 0 (Black).
NSInteger TXTerminalThemeSelectedIndex(void);
void TXTerminalThemeSetSelectedIndex(NSInteger index);

// The live Ghostty config path (Documents/ghostty-config.conf).
NSString *TXTerminalThemeConfigPath(void);

// The selected theme's background color, for the chrome around
// the terminal (the root view behind the key row and the top
// pill): the key area must follow the terminal color instead of
// staying black.
UIColor *TXTerminalThemeBackgroundColor(void);

// Posted on the main thread when a theme is applied live (by a
// reloadConfig), so the controller can repaint its chrome in the
// new theme's background color.
extern NSString *const TXTerminalThemeDidChangeNotification;

// Rewrite the config file with the selected theme's color lines:
// drops any existing lines for the owned color keys, inserts the
// theme's lines, keeps every other line. Creates the file if it
// does not exist.
void TXTerminalThemeWriteConfig(void);
