// TXJITDetailViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXJITDetailViewController.h"

#import "TXLog.h"
#import "TXOnDevicePairing.h"
#import "TXStikJITCoordinator.h"
#import "TXTheme.h"

typedef NS_ENUM(NSInteger, TXJITSection) {
    TXJITSectionMethod = 0,
    TXJITSectionPairing,
    TXJITSectionConnection,
    TXJITSectionActions,
    TXJITSectionStikDebug,
    TXJITSectionCount,
};

@interface TXJITDetailViewController ()
// The immediate Prepare/Enable result, shown in the Status row
// until the coordinator's last status replaces it.
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, copy) NSString *stikDebugStatusText;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL loopbackCheckedThisAppearance;
@end

@implementation TXJITDetailViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"JIT";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = TXThemeBackgroundColor();
    [[TXStikJITCoordinator shared] applyLiveContainerDefaultIfNeeded];
    // Pairing callbacks refresh the table (PIN appears, status
    // changes). The coordinator's pairing object is a singleton,
    // so these survive across appearances.
    __weak typeof(self) weakSelf = self;
    TXOnDevicePairing *pairing = [TXOnDevicePairing shared];
    pairing.onPIN = ^(NSString *pin) {
        (void)pin;
        TXJITDetailViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.tableView reloadData];
    };
    pairing.completion = ^(BOOL success, NSString *deviceName, NSString *message) {
        TXJITDetailViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.statusText = success
            ? [NSString stringWithFormat:@"Paired with %@.", deviceName ?: @"this iPhone"]
            : (message ?: @"Pairing failed.");
        [strongSelf.tableView reloadData];
    };
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    // One loopback check per appearance, like About.
    TXStikJITCoordinator *coordinator = [TXStikJITCoordinator shared];
    if (coordinator.selectedMethod == TXStikJITMethodBuiltInStikJIT && !self.loopbackCheckedThisAppearance) {
        self.loopbackCheckedThisAppearance = YES;
        __weak typeof(self) weakSelf = self;
        [coordinator checkLoopbackWithCompletion:^(BOOL reachable, NSString *detail) {
            (void)reachable; (void)detail;
            TXJITDetailViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.tableView reloadData];
        }];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    self.loopbackCheckedThisAppearance = NO;
}

#pragma mark - Helpers

- (BOOL)isBuiltIn {
    return [TXStikJITCoordinator shared].selectedMethod == TXStikJITMethodBuiltInStikJIT;
}

- (BOOL)isLiveContainer {
    return [TXStikJITCoordinator isRunningInLiveContainer];
}

- (UITableViewCell *)valueCellForTableView:(UITableView *)tableView {
    static NSString *const kValueID = @"TXJITValueCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValueID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kValueID];
        cell.backgroundColor = TXThemeCardBackground();
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        cell.detailTextLabel.textColor = TXThemeSecondaryTextColor();
        cell.detailTextLabel.font = [UIFont systemFontOfSize:17];
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    return cell;
}

- (UITableViewCell *)buttonCellForTableView:(UITableView *)tableView title:(NSString *)title destructive:(BOOL)destructive {
    static NSString *const kButtonID = @"TXJITButtonCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kButtonID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kButtonID];
        cell.backgroundColor = TXThemeCardBackground();
        cell.textLabel.font = [UIFont systemFontOfSize:17];
    }
    cell.textLabel.text = title;
    cell.textLabel.textColor = destructive ? [UIColor systemRedColor] : TXThemeAccentColor();
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return TXJITSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    BOOL builtIn = [self isBuiltIn];
    switch (section) {
        case TXJITSectionMethod: return 2;
        case TXJITSectionPairing: return builtIn ? 4 : 0;
        case TXJITSectionConnection: {
            if (!builtIn) return 0;
            TXStikJITCoordinator *coordinator = [TXStikJITCoordinator shared];
            // The Connect row only matters when the loopback is down.
            return (coordinator.loopbackChecked && !coordinator.loopbackReachable) ? 2 : 1;
        }
        case TXJITSectionActions: return builtIn ? 6 : 0;
        case TXJITSectionStikDebug: return builtIn ? 0 : ([self isLiveContainer] ? 4 : 3);
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if ([self tableView:tableView numberOfRowsInSection:section] == 0) return nil;
    switch (section) {
        case TXJITSectionMethod: return @"Method";
        case TXJITSectionPairing: return @"Pairing";
        case TXJITSectionConnection: return @"Connection";
        case TXJITSectionActions: return @"Actions";
        case TXJITSectionStikDebug: return @"StikDebug";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    TXStikJITCoordinator *coordinator = [TXStikJITCoordinator shared];
    TXOnDevicePairing *pairing = [TXOnDevicePairing shared];
    BOOL builtIn = [self isBuiltIn];
    BOOL inLiveContainer = [self isLiveContainer];

    if (indexPath.section == TXJITSectionMethod) {
        UITableViewCell *cell = [self valueCellForTableView:tableView];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (indexPath.row == TXStikJITMethodBuiltInStikJIT) {
            cell.textLabel.text = @"Built-in StikJIT";
            cell.accessoryType = builtIn ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            if (inLiveContainer) {
                cell.textLabel.textColor = TXThemeSecondaryTextColor();
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
        } else {
            cell.textLabel.text = @"StikDebug";
            cell.accessoryType = builtIn ? UITableViewCellAccessoryNone : UITableViewCellAccessoryCheckmark;
        }
        return cell;
    }

    if (indexPath.section == TXJITSectionPairing) {
        switch (indexPath.row) {
            case 0: {
                UITableViewCell *cell = [self valueCellForTableView:tableView];
                cell.textLabel.text = @"Pairing";
                cell.detailTextLabel.text = [coordinator pairingStatusText];
                return cell;
            }
            case 1: {
                NSString *title = pairing.active ? @"Cancel pairing" : @"Pair on this iPhone";
                return [self buttonCellForTableView:tableView title:title destructive:NO];
            }
            case 2: {
                UITableViewCell *cell = [self valueCellForTableView:tableView];
                cell.textLabel.text = @"PIN";
                if (pairing.phase == TXOnDevicePairingPhasePIN && pairing.pin) {
                    cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:24 weight:UIFontWeightBold];
                    cell.detailTextLabel.textColor = [UIColor whiteColor];
                    cell.detailTextLabel.text = pairing.pin;
                } else if (pairing.phase == TXOnDevicePairingPhaseWaiting) {
                    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
                    cell.detailTextLabel.text = pairing.backgroundLimited
                        ? @"Open Settings > Privacy & Security > Developer Mode, then tap Pair with TermX. Go straight away: this install can only wait briefly in the background."
                        : @"Open Settings > Privacy & Security > Developer Mode, then tap Pair with TermX.";
                } else {
                    cell.detailTextLabel.text = @"Not pairing";
                }
                return cell;
            }
            case 3:
                return [self buttonCellForTableView:tableView title:@"Import pairing file" destructive:NO];
            default: break;
        }
    }

    if (indexPath.section == TXJITSectionConnection) {
        if (indexPath.row == 0) {
            UITableViewCell *cell = [self valueCellForTableView:tableView];
            cell.textLabel.text = @"LocalDevVPN";
            if ([coordinator loopbackChecked]) {
                cell.detailTextLabel.text = [coordinator loopbackReachable] ? @"Connected" : @"Not connected";
            } else {
                cell.detailTextLabel.text = @"Checking…";
            }
            return cell;
        }
        return [self buttonCellForTableView:tableView
                                      title:[TXStikJITCoordinator localDevVPNActionTitle]
                                destructive:NO];
    }

    if (indexPath.section == TXJITSectionActions) {
        switch (indexPath.row) {
            case 0:
                return [self buttonCellForTableView:tableView title:@"Prepare JIT" destructive:NO];
            case 1:
                return [self buttonCellForTableView:tableView title:@"Enable JIT" destructive:NO];
            case 2: {
                UITableViewCell *cell = [self valueCellForTableView:tableView];
                cell.textLabel.text = @"Status";
                cell.detailTextLabel.text = self.statusText ?: coordinator.lastPrepareStatusText
                    ?: coordinator.lastAutoEnableStatusText ?: @"";
                return cell;
            }
            case 3: {
                UITableViewCell *cell = [self valueCellForTableView:tableView];
                cell.textLabel.text = @"TXM/SPTM";
                cell.detailTextLabel.text = [coordinator txmSPTMStatusText];
                return cell;
            }
            case 4: {
                UITableViewCell *cell = [self valueCellForTableView:tableView];
                cell.textLabel.text = @"Force JIT Script";
                UISwitch *forceSwitch = [[UISwitch alloc] init];
                forceSwitch.onTintColor = TXThemeAccentColor();
                forceSwitch.on = [coordinator forceScript];
                [forceSwitch addTarget:self action:@selector(forceScriptChanged:)
                      forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = forceSwitch;
                return cell;
            }
            case 5:
                return [self buttonCellForTableView:tableView title:@"Reset Developer Disk Image" destructive:YES];
            default: break;
        }
    }

    if (indexPath.section == TXJITSectionStikDebug) {
        switch (indexPath.row) {
            case 0: {
                UITableViewCell *cell = [self valueCellForTableView:tableView];
                cell.textLabel.text = @"StikDebug";
                cell.detailTextLabel.text = [coordinator canOpenStikDebug] ? @"Installed" : @"Not installed";
                return cell;
            }
            case 1:
                return [self buttonCellForTableView:tableView title:@"Enable JIT" destructive:NO];
            case 2: {
                UITableViewCell *cell = [self valueCellForTableView:tableView];
                cell.textLabel.text = @"Status";
                cell.detailTextLabel.text = self.stikDebugStatusText ?: @"";
                return cell;
            }
            case 3: {
                UITableViewCell *cell = [self valueCellForTableView:tableView];
                cell.textLabel.text = @"Note";
                cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
                cell.detailTextLabel.text = @"Enable Use LiveContainer's Bundle ID in LiveContainer settings.";
                return cell;
            }
            default: break;
        }
    }
    return [self valueCellForTableView:tableView];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    TXStikJITCoordinator *coordinator = [TXStikJITCoordinator shared];
    TXOnDevicePairing *pairing = [TXOnDevicePairing shared];

    if (indexPath.section == TXJITSectionMethod) {
        TXStikJITMethod method = (TXStikJITMethod)indexPath.row;
        if ([self isLiveContainer] && method == TXStikJITMethodBuiltInStikJIT) return;
        [coordinator setSelectedMethod:method];
        [self.tableView reloadData];
        return;
    }
    if (indexPath.section == TXJITSectionPairing) {
        switch (indexPath.row) {
            case 1:
                if (pairing.active) {
                    [pairing cancelWithReason:nil];
                } else {
                    [pairing start];
                }
                [self.tableView reloadData];
                break;
            case 3: {
                UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                    initWithDocumentTypes:@[@"public.property-list"] inMode:UIDocumentPickerModeImport];
                picker.delegate = self;
                picker.modalPresentationStyle = UIModalPresentationFormSheet;
                [self presentViewController:picker animated:YES completion:nil];
                break;
            }
            default: break;
        }
        return;
    }
    if (indexPath.section == TXJITSectionConnection) {
        if (indexPath.row == 1) [TXStikJITCoordinator openLocalDevVPN];
        return;
    }
    if (indexPath.section == TXJITSectionActions) {
        switch (indexPath.row) {
            case 0: [self onPrepareJIT]; break;
            case 1: [self onEnableBuiltInJIT]; break;
            case 5: [self onResetDDI]; break;
            default: break;
        }
        return;
    }
    if (indexPath.section == TXJITSectionStikDebug && indexPath.row == 1) {
        [self onEnableStikDebugJIT];
        return;
    }
}

#pragma mark - Actions

- (void)forceScriptChanged:(UISwitch *)sender {
    [[TXStikJITCoordinator shared] setForceScript:sender.isOn];
}

- (void)onPrepareJIT {
    if (self.busy) return;
    self.busy = YES;
    self.statusText = @"Preparing…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    [[TXStikJITCoordinator shared] prepareJITWithCompletion:
        ^(TXStikJITReadiness readiness, NSString *reason) {
        TXJITDetailViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.busy = NO;
        NSString *prefix = (readiness == TXStikJITReadinessReady) ? @"Ready" : @"Not ready";
        strongSelf.statusText = [NSString stringWithFormat:@"%@: %@", prefix, reason];
        [strongSelf.tableView reloadData];
    }];
}

- (void)onEnableBuiltInJIT {
    if (self.busy) return;
    self.busy = YES;
    self.statusText = @"Enabling…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    [[TXStikJITCoordinator shared] enableJITWithCompletion:
        ^(BOOL success, NSString *statusText) {
        TXJITDetailViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.busy = NO;
        strongSelf.statusText = statusText;
        (void)success;
        [strongSelf.tableView reloadData];
    }];
}

- (void)onEnableStikDebugJIT {
    __weak typeof(self) weakSelf = self;
    [[TXStikJITCoordinator shared] openStikDebugWithCompletion:^(BOOL accepted) {
        TXJITDetailViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        // Opening the URL only means iOS accepted the request;
        // it is not JIT success.
        strongSelf.stikDebugStatusText = accepted ? @"Request sent to StikDebug." : @"Could not open StikDebug.";
        [strongSelf.tableView reloadData];
    }];
}

- (void)onResetDDI {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reset Developer Disk Image"
                         message:@"Deletes the cached Developer Disk Image. The next preparation downloads it again."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        (void)action;
        [[TXStikJITCoordinator shared] resetCachedDDIWithCompletion:
            ^(BOOL success, NSString *statusText) {
            (void)success;
            TXJITDetailViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.statusText = statusText;
            [strongSelf.tableView reloadData];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Document picker (pairing file import)

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *picked = urls.firstObject;
    if (!picked) return;
    __weak typeof(self) weakSelf = self;
    [[TXStikJITCoordinator shared] importPairingFileFromURL:picked
                                                  completion:^(BOOL success, NSString *statusText) {
        (void)success;
        TXJITDetailViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.statusText = statusText;
        [strongSelf.tableView reloadData];
    }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
}

@end
