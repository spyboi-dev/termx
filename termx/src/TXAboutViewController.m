// TXAboutViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXAboutViewController.h"
#import "GuestInstall.h"
#import "KernEngine.h"
#import "TXLocalhostProxy.h"
#import "TXLog.h"
#import "TXTheme.h"

@interface TXAboutViewController ()
// The ports list inside the Localhost card, rebuilt when the user
// adds or removes a port. The add field stays fixed below it.
@property (nonatomic, strong) UIStackView *localhostPortsStack;
@property (nonatomic, strong) UITextField *localhostPortField;
@end

@implementation TXAboutViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"About";
    self.view.backgroundColor = TXThemeBackgroundColor();

    KernEngine *engine = [KernEngine shared];

    // App version from Info.plist; the build commit from the marker
    // build.sh bakes in. The commit is the real identity of a dev
    // build — the version number only changes per release.
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    NSString *commit = [KernEngine appBuildCommit];

    // System image: the installed release when it is this build's,
    // "older release" when it is a valid older one (its tag is not
    // known — only the current release's hash is pinned — so no tag
    // can be named here), and "not installed" when there is no image
    // at all. The release this build installs is always named, so
    // the user can see whether an update is waiting.
    NSString *installedRelease = engine.installedImageRelease;
    NSString *installedText;
    if (installedRelease) {
        installedText = installedRelease;
    } else if ([engine guestInstalled]) {
        installedText = @"Older release — newer release available";
    } else {
        installedText = @"Not installed";
    }
    NSString *wantedRelease = [GuestInstall rootfsReleaseTag];

    // Runtime: the API version the app was built against, the
    // upstream Kernarium commit the framework was built from, and
    // the framework hash as a secondary detail (first 12 chars —
    // enough to identify it, short enough to read).
    NSString *frameworkSHA = [KernEngine runtimeFrameworkSHA256];
    NSString *frameworkShort = frameworkSHA.length > 12
        ? [[frameworkSHA substringToIndex:12] stringByAppendingString:@"…"]
        : frameworkSHA;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont boldSystemFontOfSize:36];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.text = @"TermX";
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *taglineLabel = [[UILabel alloc] init];
    taglineLabel.font = [UIFont systemFontOfSize:15];
    taglineLabel.textColor = TXThemeSecondaryTextColor();
    taglineLabel.numberOfLines = 0;
    taglineLabel.text = @"A real Linux terminal for iPhone — Debian on the Kernarium Linux kernel.";
    taglineLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *appCard = [self cardWithTitle:@"App" rows:@[
        @[@"Version", [NSString stringWithFormat:@"%@ (%@)", version, build]],
        @[@"Build", commit],
    ]];
    UIView *imageCard = [self cardWithTitle:@"System image" rows:@[
        @[@"Installed", installedText],
        @[@"This build installs", wantedRelease],
    ]];
    UIView *runtimeCard = [self cardWithTitle:@"Runtime" rows:@[
        @[@"Kernarium runtime", [NSString stringWithFormat:@"API %u", [KernEngine runtimeAPIVersion]]],
        @[@"Upstream commit", [KernEngine runtimeUpstreamCommit]],
        @[@"Framework SHA-256", frameworkShort],
    ]];

    // Diagnostics: the debug logging switch. Off by default; when
    // on, engine.log also gets the verbose lines (memory sampler,
    // session record dumps) for diagnosis. Takes effect at once,
    // no restart (see TXLogDebug).
    UIView *diagnosticsCard = [self diagnosticsCard];

    // Localhost: the guest's 127.0.0.1 services, reachable from the
    // iPhone at the same address while the guest is running.
    UIView *localhostCard = [self localhostCard];

    UILabel *licenseNote = [self noteLabelWithText:
        @"TermX is free software under the GPL-2.0-or-later, built on the Kernarium Linux runtime."];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel, taglineLabel, appCard, imageCard, runtimeCard, localhostCard, diagnosticsCard, licenseNote]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 20;
    [stack setCustomSpacing:8 afterView:titleLabel];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];
}

// One rounded dark card, like the startup screen's checklist card:
// a small teal title, then key/value rows with a hairline between
// them. Keys are dim grey on the left; values are white on the
// right and may wrap to two lines (a release tag is long).
- (UIView *)cardWithTitle:(NSString *)title rows:(NSArray<NSArray<NSString *> *> *)rows {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = TXThemeCardBackground();
    card.layer.cornerRadius = TXThemeCornerRadiusCard;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont boldSystemFontOfSize:13];
    titleLabel.textColor = TXThemeAccentColor();
    titleLabel.text = [title uppercaseString];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *rowsStack = [[UIStackView alloc] init];
    rowsStack.axis = UILayoutConstraintAxisVertical;
    rowsStack.spacing = 0;
    rowsStack.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *previousRow = nil;
    for (NSArray<NSString *> *row in rows) {
        UIView *rowView = [self rowWithKey:row[0] value:row[1]];
        [rowsStack addArrangedSubview:rowView];
        if (previousRow) {
            UIView *sep = [[UIView alloc] init];
            sep.backgroundColor = TXThemeSeparatorColor();
            sep.translatesAutoresizingMaskIntoConstraints = NO;
            [rowsStack addArrangedSubview:sep];
            [sep.heightAnchor constraintEqualToConstant:1].active = YES;
        }
        previousRow = rowView;
    }

    UIStackView *cardStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, rowsStack]];
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.spacing = 12;
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardStack];
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [cardStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [cardStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [cardStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
    return card;
}

- (UIView *)rowWithKey:(NSString *)key value:(NSString *)value {
    UILabel *keyLabel = [[UILabel alloc] init];
    keyLabel.font = [UIFont systemFontOfSize:15];
    keyLabel.textColor = TXThemeSecondaryTextColor();
    keyLabel.text = key;
    keyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [keyLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [keyLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.font = [UIFont systemFontOfSize:15];
    valueLabel.textColor = [UIColor whiteColor];
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.numberOfLines = 0;
    valueLabel.text = value;
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[keyLabel, valueLabel]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentTop;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    return row;
}

// Localhost card: the guest's 127.0.0.1 services, reachable from
// the iPhone at the same address while the guest is running. The
// port list is the proxy's configured ports (TXLocalhostProxy);
// tapping a port's Remove takes it out, and the field adds one.
// Changes take effect at once when the guest is up (the engine
// restarts the proxy); when it is not up, they apply on the next
// boot. The card's port rows are rebuilt on every change.
- (UIView *)localhostCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = TXThemeCardBackground();
    card.layer.cornerRadius = TXThemeCornerRadiusCard;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont boldSystemFontOfSize:13];
    titleLabel.textColor = TXThemeAccentColor();
    titleLabel.text = [@"Localhost" uppercaseString];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.font = [UIFont systemFontOfSize:13];
    detailLabel.textColor = TXThemeSecondaryTextColor();
    detailLabel.numberOfLines = 0;
    detailLabel.text = @"A service on guest localhost (127.0.0.1) answers at the iPhone's localhost too, while the guest is running — so any tool or agent's pairing page and web UI just open in Safari.";
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.localhostPortsStack = [[UIStackView alloc] init];
    self.localhostPortsStack.axis = UILayoutConstraintAxisVertical;
    self.localhostPortsStack.spacing = 0;
    self.localhostPortsStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self refreshLocalhostPorts];

    UITextField *field = [[UITextField alloc] init];
    field.placeholder = @"Port, e.g. 3000";
    field.keyboardType = UIKeyboardTypeNumberPad;
    field.font = [UIFont systemFontOfSize:15];
    field.textColor = [UIColor whiteColor];
    field.backgroundColor = TXThemeButtonBackground();
    field.layer.cornerRadius = 8;
    field.layer.masksToBounds = YES;
    field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 0)];
    field.leftViewMode = UITextFieldViewModeAlways;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.heightAnchor constraintEqualToConstant:44].active = YES;
    self.localhostPortField = field;

    UIButton *addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [addButton setTitle:@"Add" forState:UIControlStateNormal];
    addButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [addButton setTitleColor:TXThemeAccentColor() forState:UIControlStateNormal];
    [addButton addTarget:self action:@selector(localhostAddPort) forControlEvents:UIControlEventTouchUpInside];
    addButton.translatesAutoresizingMaskIntoConstraints = NO;
    [addButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *addRow = [[UIStackView alloc] initWithArrangedSubviews:@[field, addButton]];
    addRow.axis = UILayoutConstraintAxisHorizontal;
    addRow.spacing = 12;
    addRow.alignment = UIStackViewAlignmentCenter;
    addRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *cardStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel, detailLabel, self.localhostPortsStack, addRow]];
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.spacing = 12;
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardStack];
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [cardStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [cardStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [cardStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
    return card;
}

- (void)refreshLocalhostPorts {
    for (UIView *view in self.localhostPortsStack.arrangedSubviews) {
        [self.localhostPortsStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray<NSNumber *> *ports = [TXLocalhostProxy configuredPorts];
    UIView *previousRow = nil;
    for (NSNumber *port in ports) {
        UILabel *portLabel = [[UILabel alloc] init];
        portLabel.font = [UIFont systemFontOfSize:15];
        portLabel.textColor = [UIColor whiteColor];
        portLabel.text = [NSString stringWithFormat:@"127.0.0.1:%@", port];
        portLabel.translatesAutoresizingMaskIntoConstraints = NO;

        UIButton *removeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [removeButton setTitle:@"Remove" forState:UIControlStateNormal];
        removeButton.titleLabel.font = [UIFont systemFontOfSize:15];
        [removeButton setTitleColor:TXThemeSecondaryTextColor() forState:UIControlStateNormal];
        removeButton.tag = [port intValue];
        [removeButton addTarget:self action:@selector(localhostRemovePort:) forControlEvents:UIControlEventTouchUpInside];
        removeButton.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[portLabel, removeButton]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 12;
        row.alignment = UIStackViewAlignmentCenter;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self.localhostPortsStack addArrangedSubview:row];
        if (previousRow) {
            UIView *sep = [[UIView alloc] init];
            sep.backgroundColor = TXThemeSeparatorColor();
            sep.translatesAutoresizingMaskIntoConstraints = NO;
            [self.localhostPortsStack addArrangedSubview:sep];
            [sep.heightAnchor constraintEqualToConstant:1].active = YES;
        }
        previousRow = row;
    }
}

- (void)localhostAddPort {
    NSInteger port = [self.localhostPortField.text integerValue];
    self.localhostPortField.text = @"";
    [self.localhostPortField resignFirstResponder];
    if (port < 1 || port > 65535) return;
    NSMutableArray<NSNumber *> *ports = [[TXLocalhostProxy configuredPorts] mutableCopy];
    if (![ports containsObject:@(port)]) {
        [ports addObject:@(port)];
        [TXLocalhostProxy setConfiguredPorts:ports];
        [[KernEngine shared] restartLocalhostProxy];
    }
    self.localhostPortField.text = @"";
    [self.localhostPortField resignFirstResponder];
    [self refreshLocalhostPorts];
}

- (void)localhostRemovePort:(UIButton *)sender {
    NSMutableArray<NSNumber *> *ports = [[TXLocalhostProxy configuredPorts] mutableCopy];
    [ports removeObject:@(sender.tag)];
    [TXLocalhostProxy setConfiguredPorts:ports];
    [[KernEngine shared] restartLocalhostProxy];
    [self refreshLocalhostPorts];
}

// Diagnostics card: one switch row, styled like the other cards.
// The switch writes the debug flag (kTXDebugLoggingDefaultsKey);
// TXLogDebug reads it fresh on every call, so the change takes
// effect at once. The toggle itself is logged, so the log shows
// when diagnosis started.
- (UIView *)diagnosticsCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = TXThemeCardBackground();
    card.layer.cornerRadius = TXThemeCornerRadiusCard;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont boldSystemFontOfSize:13];
    titleLabel.textColor = TXThemeAccentColor();
    titleLabel.text = [@"Diagnostics" uppercaseString];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *keyLabel = [[UILabel alloc] init];
    keyLabel.font = [UIFont systemFontOfSize:15];
    keyLabel.textColor = TXThemeSecondaryTextColor();
    keyLabel.text = @"Debug logging";
    keyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.font = [UIFont systemFontOfSize:13];
    detailLabel.textColor = TXThemeSecondaryTextColor();
    detailLabel.text = @"Verbose sampler and session lines in the log. Off by default; takes effect at once.";
    detailLabel.numberOfLines = 0;
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[keyLabel, detailLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 2;
    labels.translatesAutoresizingMaskIntoConstraints = NO;

    UISwitch *debugSwitch = [[UISwitch alloc] init];
    debugSwitch.on = TXLogDebugEnabled();
    debugSwitch.onTintColor = TXThemeAccentColor();
    debugSwitch.accessibilityLabel = @"Debug logging";
    debugSwitch.accessibilityHint = @"Writes verbose sampler and session lines to the log for diagnosis.";
    [debugSwitch addTarget:self action:@selector(debugSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    debugSwitch.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[labels, debugSwitch]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *cardStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, row]];
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.spacing = 12;
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardStack];
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [cardStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [cardStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [cardStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
    return card;
}

- (void)debugSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:kTXDebugLoggingDefaultsKey];
    TXLogEngine(@"Debug logging %@", sender.isOn ? @"on" : @"off");
}

- (UILabel *)noteLabelWithText:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = TXThemeSecondaryTextColor();
    label.numberOfLines = 0;
    label.text = text;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

@end
