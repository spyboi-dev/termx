// TXAboutViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXAboutViewController.h"
#import "GuestInstall.h"
#import "KernEngine.h"
#import "TXBackgroundKeepAlive.h"
#import "TXLocalhostProxy.h"
#import "TXLog.h"
#import "TXOnDevicePairing.h"
#import "TXStikJITCoordinator.h"
#import "TXTheme.h"

@interface TXAboutViewController () <UIDocumentPickerDelegate>
// The ports list inside the Localhost card, rebuilt when the user
// adds or removes a port. The add field stays fixed below it.
@property (nonatomic, strong) UIStackView *localhostPortsStack;
@property (nonatomic, strong) UITextField *localhostPortField;
// The background keep-alive switch, synced on every appearance so
// it shows off when the location authorization denied it.
@property (nonatomic, strong) UISwitch *backgroundSwitch;
// JIT method picker: one checkmark label per method row, indexed
// by TXStikJITMethod, plus the per-method sections shown only
// when that method is selected.
@property (nonatomic, strong) NSArray<UILabel *> *jitMethodCheckLabels;
@property (nonatomic, strong) NSArray<UIButton *> *jitMethodButtons;
@property (nonatomic, strong) UILabel *jitLiveContainerNoteLabel;
@property (nonatomic, strong) UIStackView *jitBuiltInStack;
@property (nonatomic, strong) UIStackView *jitStikDebugStack;
@property (nonatomic, strong) UILabel *jitPairingFileLabel;
@property (nonatomic, strong) UILabel *jitPairingPinLabel;
@property (nonatomic, strong) UIButton *jitPairButton;
@property (nonatomic, strong) UIButton *jitPairCancelButton;
@property (nonatomic, strong) UILabel *jitLoopbackLabel;
@property (nonatomic, strong) UIButton *jitLocalDevVPNButton;
@property (nonatomic, strong) UILabel *jitAutoEnableLabel;
@property (nonatomic, strong) UILabel *jitPrepareStatusLabel;
@property (nonatomic, strong) UILabel *jitTXMStatusLabel;
@property (nonatomic, strong) UISwitch *jitForceScriptSwitch;
@property (nonatomic, strong) UILabel *jitStikDebugAppLabel;
@property (nonatomic, strong) UILabel *jitStikDebugStatusLabel;
// Guards re-entry on the async Built-in prepare/enable actions.
@property (nonatomic, assign) BOOL jitBuiltInBusy;
// Guards stacking loopback checks while the card refreshes.
@property (nonatomic, assign) BOOL jitLoopbackCheckInFlight;
// The loopback check runs once per appearance, not on every card
// refresh (its completion re-enters syncJITCard).
@property (nonatomic, assign) BOOL jitLoopbackCheckedThisAppearance;
// Refreshes the Localhost card's port list while the view is on
// screen, so auto-detected ports appear and leave as guest
// services start and stop.
@property (nonatomic, strong) NSTimer *localhostRefreshTimer;
@end

@implementation TXAboutViewController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshLocalhostPorts];
    self.backgroundSwitch.on = [[TXBackgroundKeepAlive shared] isEnabled];
    [[TXStikJITCoordinator shared] applyLiveContainerDefaultIfNeeded];
    self.jitLoopbackCheckedThisAppearance = NO;
    [self syncJITCard];
    __weak TXAboutViewController *weakSelf = self;
    self.localhostRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                                 repeats:YES
                                                                   block:^(NSTimer *timer) {
        [weakSelf refreshLocalhostPorts];
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.localhostRefreshTimer invalidate];
    self.localhostRefreshTimer = nil;
}

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

    // Background: keep the guest running when the app is left, with
    // a low-precision location session (see TXBackgroundKeepAlive).
    UIView *backgroundCard = [self backgroundCard];

    // JIT: native JIT for the guest (see TXStikJITCoordinator).
    UIView *jitCard = [self jitCard];

    UILabel *licenseNote = [self noteLabelWithText:
        @"TermX is free software under the GPL-2.0-or-later, built on the Kernarium Linux runtime."];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel, taglineLabel, appCard, imageCard, runtimeCard, localhostCard, backgroundCard, jitCard, diagnosticsCard, licenseNote]];
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
    detailLabel.text = @"A service on guest localhost (127.0.0.1) answers at the iPhone's localhost too, while the guest is running — so any tool or agent's pairing page and web UI just open in Safari. Ports the guest is listening on are forwarded automatically (Auto); the list below is the manual override, always forwarded.";
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
    // Auto-detected ports the guest is listening on right now,
    // excluding the configured ones (those already have a row).
    // These are read-only: they appear when a guest service starts
    // listening and leave when it stops.
    NSSet<NSNumber *> *configured = [NSSet setWithArray:ports];
    NSMutableArray<NSNumber *> *autoPorts = [NSMutableArray array];
    for (NSNumber *port in [[KernEngine shared] localhostAutoPorts]) {
        if (![configured containsObject:port]) [autoPorts addObject:port];
    }
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
    for (NSNumber *port in autoPorts) {
        UILabel *portLabel = [[UILabel alloc] init];
        portLabel.font = [UIFont systemFontOfSize:15];
        portLabel.textColor = [UIColor whiteColor];
        portLabel.text = [NSString stringWithFormat:@"127.0.0.1:%@", port];
        portLabel.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *autoLabel = [[UILabel alloc] init];
        autoLabel.font = [UIFont systemFontOfSize:13];
        autoLabel.textColor = TXThemeAccentColor();
        autoLabel.text = @"Auto";
        autoLabel.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[portLabel, autoLabel]];
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

// Background card: one switch row, styled like the Diagnostics
// card. The switch is the keep-alive control
// (TXBackgroundKeepAlive): on, the guest keeps running when the app
// is left, with a low-precision location session. It only keeps the
// guest running with Location set to Always; with WhenInUse the
// guest still suspends, and with location denied the switch turns
// itself off (synced in viewWillAppear).
- (UIView *)backgroundCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = TXThemeCardBackground();
    card.layer.cornerRadius = TXThemeCornerRadiusCard;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont boldSystemFontOfSize:13];
    titleLabel.textColor = TXThemeAccentColor();
    titleLabel.text = [@"Background" uppercaseString];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *keyLabel = [[UILabel alloc] init];
    keyLabel.font = [UIFont systemFontOfSize:15];
    keyLabel.textColor = TXThemeSecondaryTextColor();
    keyLabel.text = @"Keep running in background";
    keyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.font = [UIFont systemFontOfSize:13];
    detailLabel.textColor = TXThemeSecondaryTextColor();
    detailLabel.text = @"The guest keeps running when you leave the app, with a low-precision location session (3 km, no GPS fix). Needs Location set to Always in Settings; the location is never stored or shared.";
    detailLabel.numberOfLines = 0;
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[keyLabel, detailLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 2;
    labels.translatesAutoresizingMaskIntoConstraints = NO;

    UISwitch *backgroundSwitch = [[UISwitch alloc] init];
    backgroundSwitch.on = [[TXBackgroundKeepAlive shared] isEnabled];
    backgroundSwitch.onTintColor = TXThemeAccentColor();
    backgroundSwitch.accessibilityLabel = @"Keep running in background";
    backgroundSwitch.accessibilityHint = @"Keeps the guest running when the app is left, using a low-precision location session.";
    [backgroundSwitch addTarget:self action:@selector(backgroundSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    backgroundSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundSwitch = backgroundSwitch;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[labels, backgroundSwitch]];
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

- (void)backgroundSwitchChanged:(UISwitch *)sender {
    [[TXBackgroundKeepAlive shared] setEnabled:sender.isOn];
}

// JIT card: a method picker plus one section per method, styled
// like the Background card. The two methods are mutually
// exclusive and persist in NSUserDefaults ("termx.jitMethod"):
// Built-in StikJIT (TXStikJITCoordinator + helper extension,
// recommended when available) and StikDebug URL (opens StikDebug
// for this process). In LiveContainer the Built-in row is
// disabled and the stored method defaults to StikDebug.
- (UIView *)jitCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = TXThemeCardBackground();
    card.layer.cornerRadius = TXThemeCornerRadiusCard;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont boldSystemFontOfSize:13];
    titleLabel.textColor = TXThemeAccentColor();
    titleLabel.text = [@"JIT" uppercaseString];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.font = [UIFont systemFontOfSize:13];
    detailLabel.textColor = TXThemeSecondaryTextColor();
    detailLabel.text = @"Enables native JIT for the guest (faster Node.js and other JIT compilers).";
    detailLabel.numberOfLines = 0;
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Method picker: two tappable rows, one checkmark on the
    // selected row. Built-in is disabled in LiveContainer.
    NSArray<NSString *> *methodTitles = @[
        @"Built-in StikJIT", @"StikDebug"];
    NSMutableArray<UILabel *> *checks = [NSMutableArray array];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    UIStackView *pickerStack = [[UIStackView alloc] init];
    pickerStack.axis = UILayoutConstraintAxisVertical;
    pickerStack.spacing = 0;
    pickerStack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSInteger method = 0; method < 2; method++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.titleLabel.font = [UIFont systemFontOfSize:15];
        [button setTitle:methodTitles[method] forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [button setTitleColor:TXThemeSecondaryTextColor() forState:UIControlStateDisabled];
        button.tag = method;
        [button addTarget:self action:@selector(jitMethodTapped:) forControlEvents:UIControlEventTouchUpInside];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [button.heightAnchor constraintEqualToConstant:44].active = YES;

        UILabel *checkLabel = [[UILabel alloc] init];
        checkLabel.font = [UIFont systemFontOfSize:15];
        checkLabel.textColor = TXThemeAccentColor();
        checkLabel.text = @"✓";
        checkLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [checkLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[button, checkLabel]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 12;
        row.alignment = UIStackViewAlignmentCenter;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [pickerStack addArrangedSubview:row];
        if (method > 0) {
            UIView *sep = [[UIView alloc] init];
            sep.backgroundColor = TXThemeSeparatorColor();
            sep.translatesAutoresizingMaskIntoConstraints = NO;
            [pickerStack insertArrangedSubview:sep atIndex:pickerStack.arrangedSubviews.count - 1];
            [sep.heightAnchor constraintEqualToConstant:1].active = YES;
        }
        [checks addObject:checkLabel];
        [buttons addObject:button];
    }
    self.jitMethodCheckLabels = checks;
    self.jitMethodButtons = buttons;

    UILabel *liveContainerNote = [[UILabel alloc] init];
    liveContainerNote.font = [UIFont systemFontOfSize:13];
    liveContainerNote.textColor = TXThemeSecondaryTextColor();
    liveContainerNote.numberOfLines = 0;
    liveContainerNote.text = @"Built-in StikJIT unavailable in LiveContainer.";
    liveContainerNote.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitLiveContainerNoteLabel = liveContainerNote;

    // Per-method sections, built once and hidden/shown by
    // syncJITCard.
    self.jitBuiltInStack = [self jitBuiltInSection];
    self.jitStikDebugStack = [self jitStikDebugSection];
    [self syncJITCard];

    UIStackView *cardStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel, detailLabel, pickerStack, liveContainerNote,
        self.jitBuiltInStack, self.jitStikDebugStack]];
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

// One left-aligned text button, like the token row below.
- (UIButton *)jitActionButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.titleLabel.font = [UIFont systemFontOfSize:15];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:TXThemeAccentColor() forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

// Built-in StikJIT section: on-device pairing + PIN, pairing
// file import (older path), loopback status, Prepare/Enable JIT +
// readiness status, TXM/SPTM status, Force JIT Script toggle,
// Reset Developer Disk Image.
- (UIStackView *)jitBuiltInSection {
    UILabel *pairingLabel = [[UILabel alloc] init];
    pairingLabel.font = [UIFont systemFontOfSize:15];
    pairingLabel.textColor = [UIColor whiteColor];
    pairingLabel.textAlignment = NSTextAlignmentRight;
    pairingLabel.numberOfLines = 0;
    pairingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitPairingFileLabel = pairingLabel;
    UIStackView *pairingRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self jitSectionKeyLabel:@"Pairing"], pairingLabel]];
    pairingRow.axis = UILayoutConstraintAxisHorizontal;
    pairingRow.spacing = 12;
    pairingRow.alignment = UIStackViewAlignmentTop;
    pairingRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *pairButton = [self jitActionButtonWithTitle:@"Pair on this iPhone"
                                                   action:@selector(jitPairTapped:)];
    self.jitPairButton = pairButton;
    UIButton *pairCancelButton = [self jitActionButtonWithTitle:@"Cancel pairing"
                                                        action:@selector(jitPairCancelTapped:)];
    self.jitPairCancelButton = pairCancelButton;

    UILabel *pinLabel = [[UILabel alloc] init];
    pinLabel.font = [UIFont monospacedDigitSystemFontOfSize:32 weight:UIFontWeightBold];
    pinLabel.textColor = [UIColor whiteColor];
    pinLabel.textAlignment = NSTextAlignmentCenter;
    pinLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitPairingPinLabel = pinLabel;

    UIButton *importButton = [self jitActionButtonWithTitle:@"Import pairing file (older path)"
                                                     action:@selector(jitImportPairingFileTapped:)];

    UILabel *loopbackLabel = [[UILabel alloc] init];
    loopbackLabel.font = [UIFont systemFontOfSize:15];
    loopbackLabel.textColor = [UIColor whiteColor];
    loopbackLabel.textAlignment = NSTextAlignmentRight;
    loopbackLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitLoopbackLabel = loopbackLabel;
    UIStackView *loopbackRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self jitSectionKeyLabel:@"LocalDevVPN"], loopbackLabel]];
    loopbackRow.axis = UILayoutConstraintAxisHorizontal;
    loopbackRow.spacing = 12;
    loopbackRow.alignment = UIStackViewAlignmentTop;
    loopbackRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *localDevVPNButton = [self jitActionButtonWithTitle:@"Connect LocalDevVPN"
                                                          action:@selector(jitLocalDevVPNTapped:)];
    self.jitLocalDevVPNButton = localDevVPNButton;

    UIButton *prepareButton = [self jitActionButtonWithTitle:@"Prepare JIT"
                                                      action:@selector(jitPrepareTapped:)];
    UIButton *enableButton = [self jitActionButtonWithTitle:@"Enable JIT"
                                                     action:@selector(jitBuiltInEnableTapped:)];

    UILabel *prepareStatus = [[UILabel alloc] init];
    prepareStatus.font = [UIFont systemFontOfSize:13];
    prepareStatus.textColor = TXThemeSecondaryTextColor();
    prepareStatus.numberOfLines = 0;
    prepareStatus.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitPrepareStatusLabel = prepareStatus;

    UILabel *autoEnableLabel = [[UILabel alloc] init];
    autoEnableLabel.font = [UIFont systemFontOfSize:13];
    autoEnableLabel.textColor = TXThemeSecondaryTextColor();
    autoEnableLabel.numberOfLines = 0;
    autoEnableLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitAutoEnableLabel = autoEnableLabel;

    UILabel *txmLabel = [[UILabel alloc] init];
    txmLabel.font = [UIFont systemFontOfSize:15];
    txmLabel.textColor = [UIColor whiteColor];
    txmLabel.textAlignment = NSTextAlignmentRight;
    txmLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitTXMStatusLabel = txmLabel;
    UIStackView *txmRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self jitSectionKeyLabel:@"TXM/SPTM"], txmLabel]];
    txmRow.axis = UILayoutConstraintAxisHorizontal;
    txmRow.spacing = 12;
    txmRow.alignment = UIStackViewAlignmentTop;
    txmRow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *forceLabel = [[UILabel alloc] init];
    forceLabel.font = [UIFont systemFontOfSize:15];
    forceLabel.textColor = TXThemeSecondaryTextColor();
    forceLabel.text = @"Force JIT Script";
    forceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UISwitch *forceSwitch = [[UISwitch alloc] init];
    forceSwitch.onTintColor = TXThemeAccentColor();
    forceSwitch.accessibilityLabel = @"Force JIT Script";
    [forceSwitch addTarget:self action:@selector(jitForceScriptChanged:) forControlEvents:UIControlEventValueChanged];
    forceSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitForceScriptSwitch = forceSwitch;
    UIStackView *forceRow = [[UIStackView alloc] initWithArrangedSubviews:@[forceLabel, forceSwitch]];
    forceRow.axis = UILayoutConstraintAxisHorizontal;
    forceRow.spacing = 12;
    forceRow.alignment = UIStackViewAlignmentCenter;
    forceRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *resetButton = [self jitActionButtonWithTitle:@"Reset Developer Disk Image"
                                                    action:@selector(jitResetDDITapped:)];

    UIStackView *section = [[UIStackView alloc] initWithArrangedSubviews:@[
        pairingRow, pairButton, pairCancelButton, pinLabel, importButton,
        loopbackRow, localDevVPNButton, prepareButton, enableButton,
        prepareStatus, autoEnableLabel, txmRow, forceRow, resetButton]];
    section.axis = UILayoutConstraintAxisVertical;
    section.spacing = 12;
    section.translatesAutoresizingMaskIntoConstraints = NO;
    return section;
}

// StikDebug section: installed status, Enable JIT (opens the
// StikDebug URL), request status. Opening the URL only confirms
// iOS accepted the request.
- (UIStackView *)jitStikDebugSection {
    UILabel *appLabel = [[UILabel alloc] init];
    appLabel.font = [UIFont systemFontOfSize:15];
    appLabel.textColor = [UIColor whiteColor];
    appLabel.textAlignment = NSTextAlignmentRight;
    appLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitStikDebugAppLabel = appLabel;
    UIStackView *appRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self jitSectionKeyLabel:@"StikDebug"], appLabel]];
    appRow.axis = UILayoutConstraintAxisHorizontal;
    appRow.spacing = 12;
    appRow.alignment = UIStackViewAlignmentTop;
    appRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *enableButton = [self jitActionButtonWithTitle:@"Enable JIT"
                                                     action:@selector(jitStikDebugEnableTapped:)];

    UILabel *statusLabel = [[UILabel alloc] init];
    statusLabel.font = [UIFont systemFontOfSize:13];
    statusLabel.textColor = TXThemeSecondaryTextColor();
    statusLabel.numberOfLines = 0;
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitStikDebugStatusLabel = statusLabel;

    UILabel *lcNote = [[UILabel alloc] init];
    lcNote.font = [UIFont systemFontOfSize:13];
    lcNote.textColor = TXThemeSecondaryTextColor();
    lcNote.numberOfLines = 0;
    lcNote.text = @"Enable Use LiveContainer's Bundle ID in LiveContainer settings.";
    lcNote.translatesAutoresizingMaskIntoConstraints = NO;
    lcNote.hidden = ![TXStikJITCoordinator isRunningInLiveContainer];

    UIStackView *section = [[UIStackView alloc] initWithArrangedSubviews:@[
        appRow, enableButton, statusLabel, lcNote]];
    section.axis = UILayoutConstraintAxisVertical;
    section.spacing = 12;
    section.translatesAutoresizingMaskIntoConstraints = NO;
    return section;
}

- (UILabel *)jitSectionKeyLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:15];
    label.textColor = TXThemeSecondaryTextColor();
    label.text = text;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return label;
}

- (void)syncJITCard {
    TXStikJITCoordinator *coordinator = [TXStikJITCoordinator shared];
    TXStikJITMethod method = [coordinator selectedMethod];
    BOOL inLiveContainer = [TXStikJITCoordinator isRunningInLiveContainer];
    // Picker: checkmark on the selected row; Built-in disabled
    // in LiveContainer.
    for (NSInteger i = 0; i < 2; i++) {
        if (i < self.jitMethodCheckLabels.count) {
            self.jitMethodCheckLabels[i].hidden = (i != method);
        }
        if (i < self.jitMethodButtons.count) {
            UIButton *button = self.jitMethodButtons[i];
            BOOL disabled = inLiveContainer && i == TXStikJITMethodBuiltInStikJIT;
            button.enabled = !disabled;
            button.alpha = disabled ? 0.4 : 1.0;
        }
    }
    if (self.jitLiveContainerNoteLabel) {
        self.jitLiveContainerNoteLabel.hidden = !inLiveContainer;
    }
    // One section visible: the selected method's.
    if (self.jitBuiltInStack) {
        self.jitBuiltInStack.hidden = (method != TXStikJITMethodBuiltInStikJIT);
    }
    if (self.jitStikDebugStack) {
        self.jitStikDebugStack.hidden = (method != TXStikJITMethodStikDebug);
    }
    // Built-in section state.
    if (self.jitPairingFileLabel) {
        self.jitPairingFileLabel.text = [coordinator pairingStatusText];
    }
    TXOnDevicePairing *pairing = [TXOnDevicePairing shared];
    if (self.jitPairButton) {
        self.jitPairButton.hidden = pairing.active;
    }
    if (self.jitPairCancelButton) {
        self.jitPairCancelButton.hidden = !pairing.active;
    }
    if (self.jitPairingPinLabel) {
        if (pairing.phase == TXOnDevicePairingPhasePIN && pairing.pin) {
            self.jitPairingPinLabel.font = [UIFont monospacedDigitSystemFontOfSize:32 weight:UIFontWeightBold];
            self.jitPairingPinLabel.textColor = [UIColor whiteColor];
            self.jitPairingPinLabel.numberOfLines = 1;
            self.jitPairingPinLabel.text = pairing.pin;
            self.jitPairingPinLabel.hidden = NO;
        } else if (pairing.phase == TXOnDevicePairingPhaseWaiting) {
            self.jitPairingPinLabel.text = pairing.backgroundLimited
                ? @"Open Settings > Privacy & Security > Developer Mode, then tap Pair with TermX. Go straight away: this install can only wait briefly in the background."
                : @"Open Settings > Privacy & Security > Developer Mode, then tap Pair with TermX.";
            self.jitPairingPinLabel.font = [UIFont systemFontOfSize:13];
            self.jitPairingPinLabel.textColor = TXThemeSecondaryTextColor();
            self.jitPairingPinLabel.numberOfLines = 0;
            self.jitPairingPinLabel.hidden = NO;
        } else {
            self.jitPairingPinLabel.hidden = YES;
        }
    }
    if (self.jitLoopbackLabel) {
        if ([coordinator loopbackChecked]) {
            self.jitLoopbackLabel.text = [coordinator loopbackReachable] ? @"Connected" : @"Not connected";
        } else {
            self.jitLoopbackLabel.text = @"Checking…";
        }
    }
    if (self.jitLocalDevVPNButton) {
        // Shown only when the loopback check found LocalDevVPN
        // down; the title follows whether it is installed.
        BOOL show = [coordinator loopbackChecked] && ![coordinator loopbackReachable];
        self.jitLocalDevVPNButton.hidden = !show;
        if (show) [self.jitLocalDevVPNButton setTitle:[TXStikJITCoordinator localDevVPNActionTitle]
                                              forState:UIControlStateNormal];
    }
    if (self.jitAutoEnableLabel) {
        NSString *autoStatus = coordinator.lastAutoEnableStatusText;
        self.jitAutoEnableLabel.text = autoStatus ?: @"";
        self.jitAutoEnableLabel.hidden = (autoStatus == nil);
    }
    if (self.jitPrepareStatusLabel) {
        self.jitPrepareStatusLabel.text = coordinator.lastPrepareStatusText ?: @"";
    }
    if (self.jitTXMStatusLabel) {
        self.jitTXMStatusLabel.text = [coordinator txmSPTMStatusText];
    }
    if (self.jitForceScriptSwitch) {
        self.jitForceScriptSwitch.on = [coordinator forceScript];
    }
    // StikDebug section state.
    if (self.jitStikDebugAppLabel) {
        self.jitStikDebugAppLabel.text = [coordinator canOpenStikDebug] ? @"Installed" : @"Not installed";
    }
    // Refresh the loopback row once per appearance: the check is
    // off the main thread and updates the labels when it answers.
    if (method == TXStikJITMethodBuiltInStikJIT
        && !self.jitLoopbackCheckedThisAppearance
        && !self.jitLoopbackCheckInFlight) {
        self.jitLoopbackCheckedThisAppearance = YES;
        self.jitLoopbackCheckInFlight = YES;
        __weak TXAboutViewController *weakSelf = self;
        [coordinator checkLoopbackWithCompletion:^(BOOL reachable, NSString *detail) {
            (void)reachable; (void)detail;
            TXAboutViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.jitLoopbackCheckInFlight = NO;
            [strongSelf syncJITCard];
        }];
    }
}

- (void)jitMethodTapped:(UIButton *)sender {
    TXStikJITMethod method = (TXStikJITMethod)sender.tag;
    [[TXStikJITCoordinator shared] setSelectedMethod:method];
    [self syncJITCard];
}

- (void)jitPairTapped:(UIButton *)sender {
    (void)sender;
    TXOnDevicePairing *pairing = [TXOnDevicePairing shared];
    if (pairing.active) return;
    __weak TXAboutViewController *weakSelf = self;
    pairing.onPIN = ^(NSString *pin) {
        (void)pin;
        TXAboutViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf syncJITCard];
    };
    pairing.completion = ^(BOOL success, NSString *deviceName, NSString *message) {
        TXAboutViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        // syncJITCard rewrites the status label from the
        // coordinator's last status; keep the pairing result
        // visible instead.
        [strongSelf syncJITCard];
        if (success) {
            strongSelf.jitPrepareStatusLabel.text =
                [NSString stringWithFormat:@"Paired with %@.", deviceName ?: @"this iPhone"];
        } else if (message) {
            strongSelf.jitPrepareStatusLabel.text = message;
        }
    };
    [pairing start];
    [self syncJITCard];
}

- (void)jitPairCancelTapped:(UIButton *)sender {
    (void)sender;
    [[TXOnDevicePairing shared] cancelWithReason:nil];
    [self syncJITCard];
}

- (void)jitLocalDevVPNTapped:(UIButton *)sender {
    (void)sender;
    [TXStikJITCoordinator openLocalDevVPN];
}

- (void)jitForceScriptChanged:(UISwitch *)sender {
    [[TXStikJITCoordinator shared] setForceScript:sender.isOn];
}

- (void)jitImportPairingFileTapped:(UIButton *)sender {
    (void)sender;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.property-list"]
                       inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *picked = urls.firstObject;
    if (!picked) return;
    __weak TXAboutViewController *weakSelf = self;
    [[TXStikJITCoordinator shared] importPairingFileFromURL:picked
                                                  completion:^(BOOL success, NSString *statusText) {
        (void)success;
        TXAboutViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.jitPrepareStatusLabel.text = statusText;
        [strongSelf syncJITCard];
    }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
}

- (void)jitPrepareTapped:(UIButton *)sender {
    (void)sender;
    if (self.jitBuiltInBusy) return;
    self.jitBuiltInBusy = YES;
    self.jitPrepareStatusLabel.text = @"Preparing…";
    __weak TXAboutViewController *weakSelf = self;
    [[TXStikJITCoordinator shared] prepareJITWithCompletion:
        ^(TXStikJITReadiness readiness, NSString *reason) {
        TXAboutViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.jitBuiltInBusy = NO;
        NSString *prefix = (readiness == TXStikJITReadinessReady) ? @"Ready" : @"Not ready";
        strongSelf.jitPrepareStatusLabel.text =
            [NSString stringWithFormat:@"%@: %@", prefix, reason];
        [strongSelf syncJITCard];
        strongSelf.jitPrepareStatusLabel.text =
            [NSString stringWithFormat:@"%@: %@", prefix, reason];
    }];
}

- (void)jitBuiltInEnableTapped:(UIButton *)sender {
    (void)sender;
    if (self.jitBuiltInBusy) return;
    self.jitBuiltInBusy = YES;
    self.jitPrepareStatusLabel.text = @"Enabling…";
    __weak TXAboutViewController *weakSelf = self;
    [[TXStikJITCoordinator shared] enableJITWithCompletion:
        ^(BOOL success, NSString *statusText) {
        TXAboutViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.jitBuiltInBusy = NO;
        strongSelf.jitPrepareStatusLabel.text = statusText;
        [strongSelf syncJITCard];
        // syncJITCard rewrites the label from the coordinator's
        // last status; keep the enable result visible instead.
        strongSelf.jitPrepareStatusLabel.text = statusText;
        (void)success;
    }];
}

- (void)jitResetDDITapped:(UIButton *)sender {
    (void)sender;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reset Developer Disk Image"
                         message:@"Deletes the cached Developer Disk Image. The next preparation downloads it again."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak TXAboutViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        (void)action;
        [[TXStikJITCoordinator shared] resetCachedDDIWithCompletion:
            ^(BOOL success, NSString *statusText) {
            (void)success;
            TXAboutViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.jitPrepareStatusLabel.text = statusText;
            [strongSelf syncJITCard];
            strongSelf.jitPrepareStatusLabel.text = statusText;
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)jitStikDebugEnableTapped:(UIButton *)sender {
    (void)sender;
    __weak TXAboutViewController *weakSelf = self;
    [[TXStikJITCoordinator shared] openStikDebugWithCompletion:^(BOOL accepted) {
        TXAboutViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        // Opening the URL only means iOS accepted the request;
        // it is not JIT success.
        strongSelf.jitStikDebugStatusLabel.text = accepted
            ? @"Request sent to StikDebug."
            : @"Could not open StikDebug.";
    }];
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
