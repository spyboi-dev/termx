// TXTerminalTheme - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXTerminalTheme.h"

#import "TXLog.h"

static NSString *const kTXTerminalThemeDefaultsKey = @"termx.terminalTheme";

// Well-known terminal palettes. Black is first and the default:
// it is the look the app has shipped since the Ghostty switch
// (pure black background). The others are the standard upstream
// values for each theme, not tuned here.
const TXTerminalTheme TXTerminalThemes[] = {
    { "Black", "#000000", "#ffffff", "#ffffff", "#333333", "#ffffff" },
    { "One Dark", "#282c34", "#abb2bf", "#528bff", "#3e4451", "#abb2bf" },
    { "Solarized Dark", "#002b36", "#839496", "#93a1a1", "#073642", "#839496" },
    { "Dracula", "#282a36", "#f8f8f2", "#f8f8f2", "#44475a", "#f8f8f2" },
    { "Nord", "#2e3440", "#d8dee9", "#d8dee9", "#434c5e", "#d8dee9" },
    { "Light", "#ffffff", "#000000", "#000000", "#cccccc", "#000000" },
};
const NSInteger TXTerminalThemeCount = (NSInteger)(sizeof(TXTerminalThemes) / sizeof(TXTerminalThemes[0]));

NSInteger TXTerminalThemeSelectedIndex(void) {
    NSInteger index = [[NSUserDefaults standardUserDefaults] integerForKey:kTXTerminalThemeDefaultsKey];
    if (index < 0 || index >= TXTerminalThemeCount) return 0;
    return index;
}

void TXTerminalThemeSetSelectedIndex(NSInteger index) {
    if (index < 0 || index >= TXTerminalThemeCount) index = 0;
    [[NSUserDefaults standardUserDefaults] setInteger:index forKey:kTXTerminalThemeDefaultsKey];
}

NSString *const TXTerminalThemeDidChangeNotification = @"TXTerminalThemeDidChangeNotification";

NSString *TXTerminalThemeConfigPath(void) {
    NSString *configDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [configDir stringByAppendingPathComponent:@"ghostty-config.conf"];
}

// The selected theme's background hex ("#rrggbb") as a color.
// Malformed input falls back to black, the default theme.
UIColor *TXTerminalThemeBackgroundColor(void) {
    TXTerminalTheme theme = TXTerminalThemes[TXTerminalThemeSelectedIndex()];
    const char *hex = theme.background;
    if (!hex || hex[0] != '#' || strlen(hex) != 7) return [UIColor blackColor];
    unsigned int rgb = 0;
    if (sscanf(hex + 1, "%06x", &rgb) != 1) return [UIColor blackColor];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

// The config keys this theme owns. A line is owned if it starts
// with one of these keys followed by "=". "background-opacity" is
// not owned: after "background" the next non-space character must
// be "=".
static BOOL TXTerminalThemeLineIsOwned(NSString *trimmed) {
    static const char *keys[] = {
        "background", "foreground", "cursor-color",
        "selection-background", "selection-foreground",
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        NSString *key = [NSString stringWithUTF8String:keys[i]];
        if ([trimmed hasPrefix:key]) {
            NSString *rest = [[trimmed substringFromIndex:key.length]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([rest hasPrefix:@"="]) return YES;
        }
    }
    return NO;
}

void TXTerminalThemeWriteConfig(void) {
    TXTerminalTheme theme = TXTerminalThemes[TXTerminalThemeSelectedIndex()];
    NSString *configPath = TXTerminalThemeConfigPath();
    // One live copy only: the config lives in Documents, and the
    // stale Caches copy from before is removed so there is one
    // source of truth.
    NSString *oldCachesPath = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject]
        stringByAppendingPathComponent:@"ghostty-config.conf"];
    [[NSFileManager defaultManager] removeItemAtPath:oldCachesPath error:nil];
    NSString *existing = [NSString stringWithContentsOfFile:configPath
                                                    encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray<NSString *> *keptLines = [NSMutableArray array];
    for (NSString *line in [existing componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (!TXTerminalThemeLineIsOwned(trimmed) && trimmed.length) [keptLines addObject:line];
    }
    NSArray<NSString *> *themeLines = @[
        [NSString stringWithFormat:@"background = %s", theme.background],
        [NSString stringWithFormat:@"foreground = %s", theme.foreground],
        [NSString stringWithFormat:@"cursor-color = %s", theme.cursorColor],
        [NSString stringWithFormat:@"selection-background = %s", theme.selectionBackground],
        [NSString stringWithFormat:@"selection-foreground = %s", theme.selectionForeground],
    ];
    NSMutableArray<NSString *> *allLines = [themeLines mutableCopy];
    [allLines addObjectsFromArray:keptLines];
    NSString *configContent = [[allLines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    NSError *writeError = nil;
    if (![configContent writeToFile:configPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        TXLogEngine(@"Ghostty: theme config write failed: %@", writeError);
    }
}
