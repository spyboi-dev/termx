// TXLocalhostDetailViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXLocalhostDetailViewController.h"

#import "KernEngine.h"
#import "TXLocalhostProxy.h"
#import "TXTheme.h"

typedef NS_ENUM(NSInteger, TXLocalhostSection) {
    TXLocalhostSectionConfigured = 0,
    TXLocalhostSectionAuto,
    TXLocalhostSectionAdd,
    TXLocalhostSectionCount,
};

@interface TXLocalhostDetailViewController ()
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation TXLocalhostDetailViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Localhost";
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    // Auto-detected ports appear and leave as guest services start
    // and stop; refresh while on screen, like About.
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        TXLocalhostDetailViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.tableView reloadData];
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = TXThemeBackgroundColor();
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return TXLocalhostSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case TXLocalhostSectionConfigured:
            return [TXLocalhostProxy configuredPorts].count;
        case TXLocalhostSectionAuto: {
            NSSet<NSNumber *> *configured = [NSSet setWithArray:[TXLocalhostProxy configuredPorts]];
            NSUInteger count = 0;
            for (NSNumber *port in [[KernEngine shared] localhostAutoPorts]) {
                if (![configured containsObject:port]) count++;
            }
            return count;
        }
        case TXLocalhostSectionAdd: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case TXLocalhostSectionConfigured: return @"Configured Ports";
        case TXLocalhostSectionAuto: return @"Auto-detected";
        case TXLocalhostSectionAdd: return @"Add Port";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == TXLocalhostSectionConfigured) {
        return @"Ports the guest is listening on are forwarded automatically (Auto); the list here is the manual override, always forwarded.";
    }
    return nil;
}

- (NSArray<NSNumber *> *)autoPorts {
    NSSet<NSNumber *> *configured = [NSSet setWithArray:[TXLocalhostProxy configuredPorts]];
    NSMutableArray<NSNumber *> *autoPorts = [NSMutableArray array];
    for (NSNumber *port in [[KernEngine shared] localhostAutoPorts]) {
        if (![configured containsObject:port]) [autoPorts addObject:port];
    }
    return autoPorts;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const kCellID = @"TXLocalhostCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kCellID];
        cell.backgroundColor = TXThemeCardBackground();
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        cell.detailTextLabel.textColor = TXThemeAccentColor();
        cell.detailTextLabel.font = [UIFont systemFontOfSize:15];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;

    if (indexPath.section == TXLocalhostSectionConfigured) {
        NSNumber *port = [TXLocalhostProxy configuredPorts][indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"127.0.0.1:%@", port];
    } else if (indexPath.section == TXLocalhostSectionAuto) {
        NSNumber *port = [self autoPorts][indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"127.0.0.1:%@", port];
        cell.detailTextLabel.text = @"Auto";
    } else if (indexPath.section == TXLocalhostSectionAdd) {
        cell.textLabel.text = @"Add Port";
        cell.textLabel.textColor = TXThemeAccentColor();
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    // Only the configured ports can be removed (swipe to delete);
    // the auto-detected ones are read-only.
    return indexPath.section == TXLocalhostSectionConfigured
        ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section != TXLocalhostSectionConfigured) return;
    NSMutableArray<NSNumber *> *ports = [[TXLocalhostProxy configuredPorts] mutableCopy];
    if (indexPath.row < (NSInteger)ports.count) {
        [ports removeObjectAtIndex:indexPath.row];
        [TXLocalhostProxy setConfiguredPorts:ports];
        [[KernEngine shared] restartLocalhostProxy];
    }
    [tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != TXLocalhostSectionAdd) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Port"
                                                                   message:@"Forward a guest localhost port to the iPhone's localhost."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Port, e.g. 3000";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        TXLocalhostDetailViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSInteger port = [alert.textFields.firstObject.text integerValue];
        if (port < 1 || port > 65535) return;
        NSMutableArray<NSNumber *> *ports = [[TXLocalhostProxy configuredPorts] mutableCopy];
        if (![ports containsObject:@(port)]) {
            [ports addObject:@(port)];
            [TXLocalhostProxy setConfiguredPorts:ports];
            [[KernEngine shared] restartLocalhostProxy];
        }
        [strongSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
