// TXAboutViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXAboutViewController.h"
#import "GuestInstall.h"
#import "KernEngine.h"
#import "TXBackgroundKeepAlive.h"
#import "TXJITManager.h"
#import "TXLocalhostProxy.h"
#import "TXLog.h"
#import "TXTheme.h"

@interface TXAboutViewController ()
// The ports list inside the Localhost card, rebuilt when the user
// adds or removes a port. The add field stays fixed below it.
@property (nonatomic, strong) UIStackView *localhostPortsStack;
@property (nonatomic, strong) UITextField *localhostPortField;
// The background keep-alive switch, synced on every appearance so
// it shows off when the location authorization denied it.
@property (nonatomic, strong) UISwitch *backgroundSwitch;
// The JIT switch and status line, synced on every appearance and
// whenever the JIT manager posts a status change, so the discovery
// progress shows live while the view is on screen. The token row
// only appears when the discovered Swipt server asks for one.
@property (nonatomic, strong) UISwitch *jitSwitch;
@property (nonatomic, strong) UILabel *jitStatusLabel;
@property (nonatomic, strong) UIButton *jitTokenButton;
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
    [self syncJITCard];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(syncJITCard)
                                                 name:TXJITManagerStatusDidChangeNotification
                                               object:nil];
    __weak TXAboutViewController *weakSelf = self;
    self.localhostRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                                 repeats:YES
                                                                   block:^(NSTimer *timer) {
        [weakSelf refreshLocalhostPorts];
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:TXJITManagerStatusDidChangeNotification
                                                  object:nil];
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

    // JIT: native JIT for the guest via the Swipt helper app
    // (see TXJITManager). The Swipt app must be installed and
    // running on this phone; without it the status stays Not Found.
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

// JIT card: one switch row plus a live status line, styled like the
// Background card. The switch is the JIT control (TXJITManager):
// on, TermX looks for the Swipt helper app on this phone and asks
// it to enable native JIT, so JIT compilers inside the guest
// (Node.js V8, JVM, ...) run at full speed instead of JITless.
// Without the separate Swipt app installed and running, the status
// stays Not Found. The token row only appears when the discovered
// server asks for a token.
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

    UILabel *keyLabel = [[UILabel alloc] init];
    keyLabel.font = [UIFont systemFontOfSize:15];
    keyLabel.textColor = TXThemeSecondaryTextColor();
    keyLabel.text = @"JIT";
    keyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.font = [UIFont systemFontOfSize:13];
    detailLabel.textColor = TXThemeSecondaryTextColor();
    detailLabel.text = @"Enables native JIT for the guest (faster Node.js and other JIT compilers) via the Swipt helper app. Swipt must be installed and running on this phone.";
    detailLabel.numberOfLines = 0;
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[keyLabel, detailLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 2;
    labels.translatesAutoresizingMaskIntoConstraints = NO;

    UISwitch *jitSwitch = [[UISwitch alloc] init];
    jitSwitch.on = [[TXJITManager shared] jitEnabled];
    jitSwitch.onTintColor = TXThemeAccentColor();
    jitSwitch.accessibilityLabel = @"JIT";
    jitSwitch.accessibilityHint = @"Enables native JIT for the guest via the Swipt helper app.";
    [jitSwitch addTarget:self action:@selector(jitSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    jitSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitSwitch = jitSwitch;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[labels, jitSwitch]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *statusLabel = [[UILabel alloc] init];
    statusLabel.font = [UIFont systemFontOfSize:13];
    statusLabel.textColor = TXThemeSecondaryTextColor();
    statusLabel.text = [[TXJITManager shared] statusText];
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitStatusLabel = statusLabel;

    UIButton *tokenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    tokenButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    tokenButton.titleLabel.font = [UIFont systemFontOfSize:15];
    [tokenButton setTitleColor:TXThemeSecondaryTextColor() forState:UIControlStateNormal];
    [tokenButton addTarget:self action:@selector(jitTokenButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    tokenButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitTokenButton = tokenButton;
    [self syncJITCard];

    UIStackView *cardStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, row, statusLabel, tokenButton]];
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

- (void)jitSwitchChanged:(UISwitch *)sender {
    [[TXJITManager shared] setJITEnabled:sender.isOn];
}

- (void)syncJITCard {
    TXJITManager *jit = [TXJITManager shared];
    if (self.jitSwitch) self.jitSwitch.on = jit.jitEnabled;
    if (self.jitStatusLabel) {
        self.jitStatusLabel.text = [NSString stringWithFormat:@"Status: %@", jit.statusText];
    }
    if (self.jitTokenButton) {
        BOOL showToken = jit.requiresToken || jit.swiptToken.length > 0;
        self.jitTokenButton.hidden = !showToken;
        NSString *value = jit.swiptToken.length > 0 ? @"•••" : @"Required";
        [self.jitTokenButton setTitle:[NSString stringWithFormat:@"Swipt Token: %@", value]
                             forState:UIControlStateNormal];
    }
}

- (void)jitTokenButtonTapped:(UIButton *)sender {
    (void)sender;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Swipt Token"
                         message:@"Enter the token shown by the Swipt app."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = [[TXJITManager shared] swiptToken];
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak TXAboutViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        NSString *token = alert.textFields.firstObject.text ?: @"";
        [[TXJITManager shared] setSwiptToken:
            [token stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        [weakSelf syncJITCard];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
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
