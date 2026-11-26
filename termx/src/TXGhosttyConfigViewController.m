// TXGhosttyConfigViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXGhosttyConfigViewController.h"

#import "TXConfig.h"
#import "TXGhosttyView.h"
#import "TXTerminalTheme.h"
#import "TXTheme.h"

typedef NS_ENUM(NSInteger, TXGhosttyConfigSection) {
    TXGhosttyConfigSectionFont = 0,
    TXGhosttyConfigSectionAppearance,
    TXGhosttyConfigSectionTheme,
    TXGhosttyConfigSectionCount,
};

@implementation TXGhosttyConfigViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Ghostty Configuration";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = TXThemeBackgroundColor();
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return TXGhosttyConfigSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case TXGhosttyConfigSectionFont: return 2;
        case TXGhosttyConfigSectionAppearance: return 1;
        case TXGhosttyConfigSectionTheme: return TXTerminalThemeCount;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case TXGhosttyConfigSectionFont: return @"Font";
        case TXGhosttyConfigSectionAppearance: return @"Appearance";
        case TXGhosttyConfigSectionTheme: return @"Color Theme";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == TXGhosttyConfigSectionFont) {
        return @"The same size pinch zoom changes in the terminal.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const kCellID = @"TXGhosttyConfigCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kCellID];
        cell.backgroundColor = TXThemeCardBackground();
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        cell.detailTextLabel.textColor = TXThemeSecondaryTextColor();
        cell.detailTextLabel.font = [UIFont systemFontOfSize:17];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;

    if (indexPath.section == TXGhosttyConfigSectionFont) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Font Size";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f pt", TXTermFontSize()];
            UIStepper *stepper = [[UIStepper alloc] init];
            stepper.minimumValue = TXConfigTermFontSizeMin;
            stepper.maximumValue = TXConfigTermFontSizeMax;
            stepper.stepValue = 1;
            stepper.value = TXTermFontSize();
            [stepper addTarget:self action:@selector(fontSizeStepperChanged:)
              forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = stepper;
        } else {
            cell.textLabel.text = @"Reset Font Size";
            cell.textLabel.textColor = TXThemeAccentColor();
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (indexPath.section == TXGhosttyConfigSectionAppearance) {
        // The background of the selected theme, so this row stays
        // true when another theme is picked.
        TXTerminalTheme theme = TXTerminalThemes[TXTerminalThemeSelectedIndex()];
        cell.textLabel.text = @"Background";
        cell.detailTextLabel.text = [NSString stringWithUTF8String:theme.background];
    } else if (indexPath.section == TXGhosttyConfigSectionTheme) {
        // Preset themes only, no color picker and no hex field:
        // a tap picks the theme, the checkmark shows the selected
        // one, and the config is rewritten and reloaded on the
        // live surface at once.
        TXTerminalTheme theme = TXTerminalThemes[indexPath.row];
        cell.textLabel.text = [NSString stringWithUTF8String:theme.name];
        cell.accessoryType = (indexPath.row == TXTerminalThemeSelectedIndex())
            ? UITableViewCellAccessoryCheckmark
            : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == TXGhosttyConfigSectionFont && indexPath.row == 1) {
        [self.terminalOutput setFontSize:TXConfigTermFontSizeDefault];
        [self.tableView reloadData];
    } else if (indexPath.section == TXGhosttyConfigSectionTheme) {
        TXTerminalThemeSetSelectedIndex(indexPath.row);
        TXTerminalThemeWriteConfig();
        [self.terminalOutput reloadConfig];
        [self.tableView reloadData];
    }
}

- (void)fontSizeStepperChanged:(UIStepper *)sender {
    [self.terminalOutput setFontSize:sender.value];
    [self.tableView reloadData];
}

@end
