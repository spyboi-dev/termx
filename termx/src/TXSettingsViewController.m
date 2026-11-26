// TXSettingsViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXSettingsViewController.h"

#import "KernEngine.h"
#import "TXAboutViewController.h"
#import "TXBackgroundKeepAlive.h"
#import "TXGhosttyConfigViewController.h"
#import "TXGhosttyView.h"
#import "TXJITDetailViewController.h"
#import "TXLocalhostDetailViewController.h"
#import "TXLocalhostProxy.h"
#import "TXLog.h"
#import "TXStikJITCoordinator.h"
#import "TXTheme.h"

// Sections. Container first, then Terminal, then About — the
// screenshot's order, with About appended at the bottom.
typedef NS_ENUM(NSInteger, TXSettingsSection) {
    TXSettingsSectionContainer = 0,
    TXSettingsSectionTerminal,
    TXSettingsSectionAbout,
    TXSettingsSectionCount,
};

// Container rows, in the screenshot's order (JIT, Data Size,
// Reset), with the keep-alive toggle and the Localhost row
// inserted before Reset, so Reset stays last (destructive).
typedef NS_ENUM(NSInteger, TXSettingsContainerRow) {
    TXSettingsContainerRowJIT = 0,
    TXSettingsContainerRowDataSize,
    TXSettingsContainerRowBackground,
    TXSettingsContainerRowLocalhost,
    TXSettingsContainerRowReset,
    TXSettingsContainerRowCount,
};

@interface TXSettingsViewController ()
@property (nonatomic, strong) UISwitch *backgroundSwitch;
// Light tap for row taps and the background switch; created once
// and prepared after each use.
@property (nonatomic, strong) UIImpactFeedbackGenerator *rowHaptic;
@end

@implementation TXSettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Settings";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = TXThemeBackgroundColor();
    self.rowHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [self.rowHaptic prepare];
    // A modal Settings needs a way back: Done, top right.
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(onDone)];
}

- (void)rowHapticTap {
    [self.rowHaptic impactOccurred];
    [self.rowHaptic prepare];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Values change in the details (JIT method, ports, font size),
    // so refresh on every appearance.
    [self.tableView reloadData];
    if (self.backgroundSwitch) {
        self.backgroundSwitch.on = [[TXBackgroundKeepAlive shared] isEnabled];
    }
}

- (void)onDone {
    [self rowHapticTap];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return TXSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case TXSettingsSectionContainer: return TXSettingsContainerRowCount;
        case TXSettingsSectionTerminal: return 1;
        case TXSettingsSectionAbout: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case TXSettingsSectionContainer: return @"Container";
        case TXSettingsSectionTerminal: return @"Terminal";
        case TXSettingsSectionAbout: return @"About";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const kCellID = @"TXSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kCellID];
        // Plain rows, no glass: the doc says to apply Liquid Glass
        // sparingly, only to the most important functional
        // elements. A settings row is not one; it uses the
        // standard grouped cell background.
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        cell.detailTextLabel.textColor = TXThemeSecondaryTextColor();
        cell.detailTextLabel.font = [UIFont systemFontOfSize:17];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;

    if (indexPath.section == TXSettingsSectionContainer) {
        switch (indexPath.row) {
            case TXSettingsContainerRowJIT: {
                cell.textLabel.text = @"JIT";
                // Swipterm's value: whether JIT is on.
                cell.detailTextLabel.text = [TXStikJITCoordinator shared].jitEnabledThisLaunch
                    ? @"Enabled" : @"Not Enabled";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            case TXSettingsContainerRowDataSize: {
                cell.textLabel.text = @"Data Size";
                cell.detailTextLabel.text = [self dataSizeText];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            }
            case TXSettingsContainerRowBackground: {
                cell.textLabel.text = @"Keep running in background";
                cell.textLabel.font = [UIFont systemFontOfSize:17];
                UISwitch *backgroundSwitch = [[UISwitch alloc] init];
                backgroundSwitch.onTintColor = TXThemeAccentColor();
                backgroundSwitch.on = [[TXBackgroundKeepAlive shared] isEnabled];
                backgroundSwitch.accessibilityLabel = @"Keep running in background";
                [backgroundSwitch addTarget:self action:@selector(backgroundSwitchChanged:)
                           forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = backgroundSwitch;
                self.backgroundSwitch = backgroundSwitch;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            }
            case TXSettingsContainerRowLocalhost: {
                cell.textLabel.text = @"Localhost";
                NSUInteger count = [TXLocalhostProxy configuredPorts].count;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu %@",
                    (unsigned long)count, count == 1 ? @"port" : @"ports"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            case TXSettingsContainerRowReset: {
                cell.textLabel.text = @"Reset";
                cell.textLabel.textColor = [UIColor systemRedColor];
                break;
            }
            default: break;
        }
    } else if (indexPath.section == TXSettingsSectionTerminal) {
        cell.textLabel.text = @"Ghostty Configuration";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == TXSettingsSectionAbout) {
        cell.textLabel.text = @"About";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == TXSettingsSectionContainer) {
        switch (indexPath.row) {
            case TXSettingsContainerRowJIT: {
                [self rowHapticTap];
                TXJITDetailViewController *detail = [[TXJITDetailViewController alloc] init];
                [self.navigationController pushViewController:detail animated:YES];
                break;
            }
            case TXSettingsContainerRowLocalhost: {
                [self rowHapticTap];
                TXLocalhostDetailViewController *detail = [[TXLocalhostDetailViewController alloc] init];
                [self.navigationController pushViewController:detail animated:YES];
                break;
            }
            case TXSettingsContainerRowReset:
                [self rowHapticTap];
                [self onResetGuestData];
                break;
            default:
                break;
        }
    } else if (indexPath.section == TXSettingsSectionTerminal) {
        [self rowHapticTap];
        TXGhosttyConfigViewController *detail = [[TXGhosttyConfigViewController alloc] init];
        detail.terminalOutput = self.terminalOutput;
        [self.navigationController pushViewController:detail animated:YES];
    } else if (indexPath.section == TXSettingsSectionAbout) {
        [self rowHapticTap];
        TXAboutViewController *about = [[TXAboutViewController alloc] init];
        [self.navigationController pushViewController:about animated:YES];
    }
}

#pragma mark - Values

- (NSString *)dataSizeText {
    KernEngine *engine = [KernEngine shared];
    if (!engine.dataDiskExists) return @"Not installed";
    // The guest data's actual disk use (the sparse file's allocated
    // blocks), not the disk's nominal size.
    unsigned long long used = [engine storageUsedBytes];
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    return [formatter stringFromByteCount:(long long)used];
}

- (void)backgroundSwitchChanged:(UISwitch *)sender {
    [self rowHapticTap];
    [[TXBackgroundKeepAlive shared] setEnabled:sender.isOn];
}

#pragma mark - Reset guest data

- (void)onResetGuestData {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reset Guest Data"
                         message:@"Deletes the guest's saved data — installed packages, files, everything. The system image is untouched. The guest stops first, and the next boot creates a fresh data disk."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        (void)action;
        [weakSelf resetGuestData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetGuestData {
    KernEngine *engine = [KernEngine shared];
    // Stop the guest first: erasing the data disk under a running
    // guest would corrupt it. stopGuest is async, so the erase
    // waits 2 s for the stop to land.
    [engine stopGuest];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *error = nil;
        BOOL ok = [[KernEngine shared] eraseDataDiskWithError:&error];
        NSString *message = ok
            ? @"Guest data erased. Return to the startup screen to boot a fresh guest."
            : [NSString stringWithFormat:@"Could not erase the guest data: %@",
               error ?: @"unknown error"];
        UIAlertController *done = [UIAlertController alertControllerWithTitle:
            ok ? @"Guest Data Erased" : @"Reset Failed"
            message:message preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault handler:nil]];
        [strongSelf presentViewController:done animated:YES completion:nil];
        [strongSelf.tableView reloadData];
    });
}

@end
