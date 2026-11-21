// TXStartupViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXStartupViewController.h"
#import "KernEngine.h"
#import "TXLog.h"
#import "TXLogViewController.h"
#import "TerminalViewController.h"
#import <MetalKit/MetalKit.h>

// Andarium's teal, as in the screenshot: the dot, the "Starting"
// text, the in-progress detail, and the done check circles.
static UIColor *TXStartupTeal(void) {
    return [UIColor colorWithRed:0x2A / 255.0 green:0xB3 / 255.0 blue:0xA3 / 255.0 alpha:1.0];
}

typedef NS_ENUM(NSInteger, TXStartupRowState) {
    TXStartupRowPending, // not started yet: dim hollow circle
    TXStartupRowActive,  // running now: spinner, detail in teal
    TXStartupRowDone,    // really finished: teal check
    TXStartupRowFailed   // failed: red outline, reason in red
};

@interface TXStartupViewController ()
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *reasonLabel;
@property (nonatomic, strong) MTKView *guestView; // the guest framebuffer; never seen
@property (nonatomic, strong) UIButton *actionButton; // Install (or Start when the guest is powered off), by state
// Auto-boot bookkeeping: one automatic boot per launch, plus one
// automatic retry if a boot fails. The user never taps Boot.
@property (nonatomic, assign) BOOL autoBootDone;
@property (nonatomic, assign) BOOL bootRetryUsed;
@property (nonatomic, assign) BOOL bootRetryScheduled;
@property (nonatomic, strong) UIButton *eraseButton; // small destructive text button
@property (nonatomic, strong) NSMutableArray<UIView *> *rowIcons;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *rowChecks;
@property (nonatomic, strong) NSMutableArray<UIActivityIndicatorView *> *rowSpinners;
@property (nonatomic, strong) NSMutableArray<UILabel *> *rowTitles;
@property (nonatomic, strong) NSMutableArray<UILabel *> *rowDetails;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong) NSDate *startTime;
@property (nonatomic, assign) BOOL terminalPresented; // shown once per Running state
@property (nonatomic, assign) BOOL presentAfterLogCloses;
// Download rate: bytes and time of the last poll tick, so the
// "MB/s" figure is measured, not guessed.
@property (nonatomic, assign) int64_t lastReceived;
@property (nonatomic, strong, nullable) NSDate *lastRateTime;
@property (nonatomic, assign) double lastRate;
@end

@implementation TXStartupViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.startTime = [NSDate date];
    self.rowIcons = [NSMutableArray array];
    self.rowChecks = [NSMutableArray array];
    self.rowSpinners = [NSMutableArray array];
    self.rowTitles = [NSMutableArray array];
    self.rowDetails = [NSMutableArray array];

    // The guest's Metal view sits behind everything, full screen. The
    // runtime refuses a null view, and the startup screen and the
    // terminal are both opaque, so the framebuffer is never seen: the
    // console is the interface. It lives here, on the root screen,
    // because the guest boots from this screen, before any terminal
    // exists.
    self.guestView = [[MTKView alloc] initWithFrame:self.view.bounds];
    self.guestView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.guestView];

    // Top row: teal dot + "Starting" left, elapsed timer right.
    self.statusDot = [[UIView alloc] init];
    self.statusDot.backgroundColor = TXStartupTeal();
    self.statusDot.layer.cornerRadius = 5;
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusDot.widthAnchor constraintEqualToConstant:10].active = YES;
    [self.statusDot.heightAnchor constraintEqualToConstant:10].active = YES;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:17];
    self.statusLabel.textColor = TXStartupTeal();
    self.statusLabel.text = @"Starting";
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.timerLabel = [[UILabel alloc] init];
    self.timerLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.timerLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    self.timerLabel.text = @"0:00";
    self.timerLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDot, self.statusLabel]];
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.spacing = 8;
    statusRow.alignment = UIStackViewAlignmentCenter;
    statusRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[statusRow, self.timerLabel]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;
    topRow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont boldSystemFontOfSize:36];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.text = @"TermX";
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Thin progress bar under the title: real progress only — the
    // install fraction while downloading, the boot phase once the
    // guest is booting (see KernEngine.bootProgress).
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.trackTintColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.progressView.progressTintColor = TXStartupTeal();
    self.progressView.progress = 0;

    // The checklist card: one rounded dark card holding the rows.
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    card.layer.cornerRadius = 24;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    NSArray<NSString *> *titles = @[@"System image", @"Linux kernel", @"Storage", @"Startup"];
    UIView *previousRow = nil;
    for (NSInteger i = 0; i < TXBootStepCount; i++) {
        UIView *row = [self makeRowWithTitle:titles[(NSUInteger)i]];
        [card addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
            [row.heightAnchor constraintEqualToConstant:68],
            previousRow ? [row.topAnchor constraintEqualToAnchor:previousRow.bottomAnchor] : [row.topAnchor constraintEqualToAnchor:card.topAnchor],
        ]];
        if (previousRow) {
            UIView *sep = [[UIView alloc] init];
            sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
            sep.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:sep];
            [NSLayoutConstraint activateConstraints:@[
                [sep.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:60],
                [sep.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
                [sep.heightAnchor constraintEqualToConstant:1],
                [sep.topAnchor constraintEqualToAnchor:previousRow.bottomAnchor],
            ]];
        }
        previousRow = row;
    }
    [card.bottomAnchor constraintEqualToAnchor:previousRow.bottomAnchor].active = YES;

    // Plain-words reason, shown only when a step failed.
    self.reasonLabel = [[UILabel alloc] init];
    self.reasonLabel.font = [UIFont systemFontOfSize:14];
    self.reasonLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    self.reasonLabel.numberOfLines = 0;
    self.reasonLabel.hidden = YES;
    self.reasonLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // All controls live here, on this screen, and nowhere else:
    // Install is the only action button — one tap installs, then
    // the engine boots itself and the terminal opens on its own.
    // Log opens the live log view. The terminal window has no
    // buttons at all.
    self.actionButton = [self buttonWithTitle:@"Install" action:@selector(actionTapped)];
    UIButton *logButton = [self buttonWithTitle:@"Log" action:@selector(logTapped)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.actionButton, logButton]];
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 12;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    // Erase data disk: small, destructive, clearly separate. The
    // persistent data disk is the guest's saved state; when it is
    // broken, this is the only way back short of deleting the app.
    self.eraseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.eraseButton setTitle:@"Erase data disk…" forState:UIControlStateNormal];
    self.eraseButton.titleLabel.font = [UIFont systemFontOfSize:14];
    [self.eraseButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    self.eraseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.eraseButton addTarget:self action:@selector(eraseTapped) forControlEvents:UIControlEventTouchUpInside];

    // A spacer holds the title and card low on the screen, the way
    // the Andarium screen does, instead of crowding the top row.
    UIView *spacer = [[UIView alloc] init];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer.heightAnchor constraintEqualToConstant:120].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, spacer, titleLabel, self.progressView, card, self.reasonLabel, buttons, self.eraseButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 28;
    // The progress bar sits tight under the title, not a full
    // 28-point gap away.
    [stack setCustomSpacing:12 afterView:titleLabel];
    [stack setCustomSpacing:28 afterView:self.progressView];
    [stack setCustomSpacing:16 afterView:buttons];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    // Opaque: the guest framebuffer behind this screen is never seen.
    scroll.backgroundColor = [UIColor blackColor];
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.guestView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.guestView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.guestView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.guestView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
    ]];

    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:kTermXStateChanged
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        [weakSelf refresh];
        [weakSelf maybePresentTerminal];
    }];
}

- (void)dealloc {
    [self.pollTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startPollTimer];
    [self refresh];
    // A new Running state may auto-present the terminal once; coming
    // back from the terminal must not re-trigger it.
    if ([KernEngine shared].state != TermXStateRunning) {
        self.terminalPresented = NO;
    }
    [self maybePresentTerminal];
    // The automatic boot lives in refresh() (see maybeAutoBoot),
    // which just ran above: on launch with the guest installed
    // there is nothing else to do first, and the progress is
    // visible here from the first byte.
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (UIView *)makeRowWithTitle:(NSString *)title {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *icon = [[UIView alloc] init];
    icon.layer.cornerRadius = 14;
    icon.layer.borderWidth = 2;
    icon.layer.borderColor = [[UIColor colorWithWhite:0.5 alpha:1.0] CGColor];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:28].active = YES;
    [icon.heightAnchor constraintEqualToConstant:28].active = YES;

    UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
    check.tintColor = [UIColor whiteColor];
    check.contentMode = UIViewContentModeScaleAspectFit;
    check.hidden = YES;
    check.translatesAutoresizingMaskIntoConstraints = NO;
    [icon addSubview:check];
    [NSLayoutConstraint activateConstraints:@[
        [check.centerXAnchor constraintEqualToAnchor:icon.centerXAnchor],
        [check.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [check.widthAnchor constraintEqualToConstant:16],
        [check.heightAnchor constraintEqualToConstant:16],
    ]];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = TXStartupTeal();
    spinner.hidden = YES;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [icon addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:icon.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
    ]];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont boldSystemFontOfSize:17];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.text = title;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.font = [UIFont systemFontOfSize:14];
    detailLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, detailLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 2;
    labels.translatesAutoresizingMaskIntoConstraints = NO;

    [row addSubview:icon];
    [row addSubview:labels];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:20],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [labels.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:16],
        [labels.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-20],
        [labels.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    [self.rowIcons addObject:icon];
    [self.rowChecks addObject:check];
    [self.rowSpinners addObject:spinner];
    [self.rowTitles addObject:titleLabel];
    [self.rowDetails addObject:detailLabel];
    return row;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    button.layer.cornerRadius = 12;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:48].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)startPollTimer {
    [self.pollTimer invalidate];
    __weak typeof(self) weakSelf = self;
    // Half a second: the download watcher reports every 0.25 s,
    // and the elapsed timer wants a fresh second anyway.
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf refresh];
    }];
}

- (void)refresh {
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:self.startTime];
    self.timerLabel.text = [NSString stringWithFormat:@"%lu:%02lu",
                            (unsigned long)(elapsed / 60), (unsigned long)((NSInteger)elapsed % 60)];
    [self refreshHeader];
    [self refreshRows];
    [self refreshButtons];
    self.progressView.progress = (float)[KernEngine shared].bootProgress;
    // The automatic flow lives here, so every path that updates the
    // screen also considers it: install completing, a cold launch,
    // and the poll tick after returning to the foreground when the
    // install finished while backgrounded.
    [self maybeAutoBoot];
    [self maybeScheduleBootRetry];
}

// The one button follows the engine state, and only the state:
// Install when nothing is installed (or the last step failed),
// Start when the guest is installed but powered off, disabled with
// the live phase while something is in flight. The boot itself is
// automatic (see maybeAutoBoot) — there is no Boot button to tap.
// Erase is live only when nothing is running.
- (void)refreshButtons {
    KernEngine *engine = [KernEngine shared];
    switch (engine.state) {
        case TermXStateIdle:
        case TermXStateFailed:
            [self.actionButton setTitle:@"Install" forState:UIControlStateNormal];
            self.actionButton.enabled = YES;
            break;
        case TermXStateStopped:
            [self.actionButton setTitle:@"Start" forState:UIControlStateNormal];
            self.actionButton.enabled = YES;
            break;
        case TermXStateReady:
            [self.actionButton setTitle:@"Starting…" forState:UIControlStateNormal];
            self.actionButton.enabled = NO;
            break;
        case TermXStateDownloading:
            [self.actionButton setTitle:@"Downloading…" forState:UIControlStateNormal];
            self.actionButton.enabled = NO;
            break;
        case TermXStateBooting:
            [self.actionButton setTitle:@"Starting…" forState:UIControlStateNormal];
            self.actionButton.enabled = NO;
            break;
        case TermXStateRunning:
            [self.actionButton setTitle:@"Running" forState:UIControlStateNormal];
            self.actionButton.enabled = NO;
            break;
    }
    self.eraseButton.enabled = (engine.state != TermXStateDownloading &&
                                engine.state != TermXStateBooting &&
                                engine.state != TermXStateRunning);
}

- (void)refreshHeader {
    KernEngine *engine = [KernEngine shared];
    NSString *text = @"Ready";
    UIColor *dot = [UIColor colorWithWhite:0.5 alpha:1.0];
    UIColor *labelColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    switch (engine.state) {
        case TermXStateDownloading:
            text = @"Downloading"; dot = TXStartupTeal(); labelColor = TXStartupTeal();
            break;
        case TermXStateBooting:
            text = @"Starting"; dot = TXStartupTeal(); labelColor = TXStartupTeal();
            break;
        case TermXStateRunning:
            text = @"Running"; dot = [UIColor systemGreenColor]; labelColor = [UIColor systemGreenColor];
            break;
        case TermXStateFailed:
            text = @"Failed"; dot = [UIColor systemRedColor]; labelColor = [UIColor systemRedColor];
            break;
        case TermXStateReady:
        case TermXStateStopped:
        case TermXStateIdle:
            text = @"Ready"; dot = [UIColor colorWithWhite:0.5 alpha:1.0]; labelColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            break;
    }
    self.statusLabel.text = text;
    self.statusLabel.textColor = labelColor;
    self.statusDot.backgroundColor = dot;

    // The honest reason, only when a step failed. While it is
    // downloading, booting or running there is nothing to say.
    NSString *reason = nil;
    if (engine.state == TermXStateFailed) {
        reason = engine.statusText ?: @"Something failed — check the log for the exact reason.";
    }
    self.reasonLabel.hidden = (reason == nil);
    self.reasonLabel.text = reason ?: @"";
}

// Each row is driven only by what the engine really reports.
// System image is Done when the image exists on disk with the
// right hash (KernEngine.guestInstalled); Linux kernel is Done
// when init is running (the UML_BOOT_SWITCH_ROOT marker, i.e.
// bootPhase Services or Ready); Storage is Done when the persistent
// data disk was created or reused for this boot; Startup is Done
// when the login prompt was seen (state Running). A row is Done only
// when its step really finished, never on a guess.
- (void)refreshRows {
    KernEngine *engine = [KernEngine shared];
    BOOL failed = engine.state == TermXStateFailed;
    NSInteger failedStep = engine.failedStep;
    NSString *status = engine.statusText ?: @"";

    // System image.
    if (failed && failedStep == TXBootStepImage) {
        [self setRow:TXBootStepImage state:TXStartupRowFailed detail:status];
    } else if ([engine guestInstalled]) {
        [self setRow:TXBootStepImage state:TXStartupRowDone detail:engine.imageDetail];
    } else if (engine.state == TermXStateDownloading) {
        [self setRow:TXBootStepImage state:TXStartupRowActive detail:[self downloadDetail]];
    } else {
        [self setRow:TXBootStepImage state:TXStartupRowPending detail:@"Debian trixie slim · 116 MB"];
    }

    // Linux kernel.
    if (failed && failedStep == TXBootStepKernel) {
        [self setRow:TXBootStepKernel state:TXStartupRowFailed detail:status];
    } else if (engine.bootPhase == TXBootPhaseServices || engine.bootPhase == TXBootPhaseReady ||
               engine.state == TermXStateRunning) {
        [self setRow:TXBootStepKernel state:TXStartupRowDone detail:engine.kernelDetail];
    } else if (engine.state == TermXStateBooting) {
        [self setRow:TXBootStepKernel state:TXStartupRowActive detail:@"Booting kernel…"];
    } else {
        [self setRow:TXBootStepKernel state:TXStartupRowPending detail:engine.kernelDetail];
    }

    // Storage.
    if (failed && failedStep == TXBootStepStorage) {
        [self setRow:TXBootStepStorage state:TXStartupRowFailed detail:status];
    } else if (engine.dataDiskReady) {
        NSString *detail = [NSString stringWithFormat:@"%@ of %@",
                            TXFormatBytes(engine.storageUsedBytes),
                            TXFormatBytes(engine.storageTotalBytes)];
        [self setRow:TXBootStepStorage state:TXStartupRowDone detail:detail];
    } else if (engine.state == TermXStateBooting) {
        [self setRow:TXBootStepStorage state:TXStartupRowActive detail:@"Opening data disk…"];
    } else {
        [self setRow:TXBootStepStorage state:TXStartupRowPending detail:@"8 GiB data disk · persists across boots"];
    }

    // Startup.
    if (failed && failedStep == TXBootStepStartup) {
        [self setRow:TXBootStepStartup state:TXStartupRowFailed detail:status];
    } else if (engine.state == TermXStateRunning) {
        [self setRow:TXBootStepStartup state:TXStartupRowDone detail:@"Shell ready · logged in as termux"];
    } else if (engine.state == TermXStateBooting) {
        // The live phase, in teal: "Starts services" once init is
        // running, the engine status before that.
        NSString *detail = engine.bootPhase == TXBootPhaseServices ? @"Starts services" : status;
        [self setRow:TXBootStepStartup state:TXStartupRowActive detail:detail];
    } else {
        [self setRow:TXBootStepStartup state:TXStartupRowPending detail:@"Starts services"];
    }
}

// "Downloading… 42% · 56 MB of 116 MB · 2.1 MB/s", from the real
// byte counts the download watcher reports. The rate is measured
// between poll ticks; it is omitted until two ticks exist.
- (NSString *)downloadDetail {
    KernEngine *engine = [KernEngine shared];
    int64_t received = engine.downloadReceived;
    int64_t expected = engine.downloadExpected;
    if (expected <= 0) return engine.statusText ?: @"Downloading…";
    double pct = (double)received / (double)expected * 100.0;
    NSDate *now = [NSDate date];
    if (self.lastRateTime && received > self.lastReceived) {
        NSTimeInterval dt = [now timeIntervalSinceDate:self.lastRateTime];
        if (dt > 0) self.lastRate = (double)(received - self.lastReceived) / dt;
    }
    self.lastReceived = received;
    self.lastRateTime = now;
    NSString *base = [NSString stringWithFormat:@"Downloading… %.0f%% · %@ of %@",
                      pct, TXFormatBytes((unsigned long long)received),
                      TXFormatBytes((unsigned long long)expected)];
    if (self.lastRate > 0) {
        return [base stringByAppendingFormat:@" · %@/s", TXFormatBytes((unsigned long long)self.lastRate)];
    }
    return base;
}

- (void)setRow:(NSInteger)row state:(TXStartupRowState)state detail:(NSString *)detail {
    UIView *icon = self.rowIcons[(NSUInteger)row];
    UIImageView *check = self.rowChecks[(NSUInteger)row];
    UIActivityIndicatorView *spinner = self.rowSpinners[(NSUInteger)row];
    UILabel *title = self.rowTitles[(NSUInteger)row];
    UILabel *detailLabel = self.rowDetails[(NSUInteger)row];
    detailLabel.text = detail;
    switch (state) {
        case TXStartupRowDone:
            icon.backgroundColor = TXStartupTeal();
            icon.layer.borderWidth = 0;
            check.hidden = NO;
            [spinner stopAnimating];
            spinner.hidden = YES;
            title.textColor = [UIColor whiteColor];
            detailLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            break;
        case TXStartupRowActive:
            icon.backgroundColor = [UIColor clearColor];
            icon.layer.borderWidth = 0;
            check.hidden = YES;
            spinner.hidden = NO;
            [spinner startAnimating];
            title.textColor = [UIColor whiteColor];
            detailLabel.textColor = TXStartupTeal();
            break;
        case TXStartupRowFailed:
            icon.backgroundColor = [UIColor clearColor];
            icon.layer.borderWidth = 2;
            icon.layer.borderColor = [[UIColor systemRedColor] CGColor];
            check.hidden = YES;
            [spinner stopAnimating];
            spinner.hidden = YES;
            title.textColor = [UIColor whiteColor];
            detailLabel.textColor = [UIColor systemRedColor];
            break;
        case TXStartupRowPending:
            icon.backgroundColor = [UIColor clearColor];
            icon.layer.borderWidth = 2;
            icon.layer.borderColor = [[UIColor colorWithWhite:0.5 alpha:1.0] CGColor];
            check.hidden = YES;
            [spinner stopAnimating];
            spinner.hidden = YES;
            title.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
            detailLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            break;
    }
}

// Automatic boot: one tap on Install is the whole flow. When the
// engine reaches Ready — the install just finished, or a cold launch
// with the guest already installed — boot at once, once per launch.
// Only while the app is in the foreground: booting while
// backgrounded would fight iOS for CPU it will not give. If the
// install finished while backgrounded, the flag stays clear and the
// poll tick after the return to the foreground boots instead.
- (void)maybeAutoBoot {
    KernEngine *engine = [KernEngine shared];
    if (engine.state != TermXStateReady) return;
    if (self.autoBootDone) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    self.autoBootDone = YES;
    TXLogEngine(@"Auto-boot: guest is ready, starting the engine");
    [engine bootOnView:self.guestView];
}

// One automatic retry if a boot fails: a failed kernel or storage
// step is often transient (a bad first dlopen, a disk still
// settling). An install failure (failedStep Image) is not retried
// here — the image itself is the problem, and Install is the tap
// for that. If the retry also fails, the Install button is the
// fallback: it re-checks the image (cheap when it is already
// verified) and boots again.
- (void)maybeScheduleBootRetry {
    KernEngine *engine = [KernEngine shared];
    if (engine.state != TermXStateFailed) {
        self.bootRetryScheduled = NO;
        return;
    }
    if (engine.failedStep == TXBootStepImage) return;
    if (self.bootRetryScheduled || self.bootRetryUsed) return;
    self.bootRetryScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.bootRetryScheduled = NO;
        KernEngine *engine2 = [KernEngine shared];
        if (engine2.state != TermXStateFailed) return;
        if (engine2.failedStep == TXBootStepImage) return;
        if (strongSelf.bootRetryUsed) return;
        strongSelf.bootRetryUsed = YES;
        TXLogEngine(@"Boot failed — retrying automatically");
        [engine2 bootOnView:strongSelf.guestView];
    });
}

// Present the terminal once the shell is really ready. A short
// beat at full green first, so the user sees every check done. If
// the log screen is open on top, wait until it closes instead of
// yanking it away. Coming back from the terminal (swipe down from
// the top edge) does not re-trigger this: the user chose to return.
- (void)maybePresentTerminal {
    if ([KernEngine shared].state != TermXStateRunning) return;
    if (self.terminalPresented) return;
    self.terminalPresented = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.presentedViewController) {
            strongSelf.presentAfterLogCloses = YES;
            return;
        }
        [strongSelf presentTerminal];
    });
}

- (void)presentTerminal {
    TerminalViewController *terminal = [[TerminalViewController alloc] init];
    terminal.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:terminal animated:YES completion:nil];
}

- (void)actionTapped {
    KernEngine *engine = [KernEngine shared];
    if (engine.state == TermXStateStopped) {
        // The guest is installed but powered off: start it. A manual
        // start earns a fresh automatic retry if this boot fails.
        self.bootRetryUsed = NO;
        self.bootRetryScheduled = NO;
        [engine bootOnView:self.guestView];
        return;
    }
    if (engine.state == TermXStateIdle || engine.state == TermXStateFailed) {
        // A manual Install resets the automatic flow, so the Ready
        // state it ends in boots by itself (see maybeAutoBoot), and
        // a boot failure after it gets its one automatic retry.
        self.autoBootDone = NO;
        self.bootRetryUsed = NO;
        self.bootRetryScheduled = NO;
        [engine installGuestWithCompletion:nil];
        return;
    }
}

- (void)eraseTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Erase data disk?"
                                                                   message:@"This deletes everything saved in the guest — installed packages, files, all of it. The Debian system image is untouched, and the next boot starts with a fresh, empty data disk."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Erase" style:UIAlertActionStyleDestructive handler:^(__kindof UIAlertAction *action) {
        (void)action;
        NSString *error = nil;
        if (![[KernEngine shared] eraseDataDiskWithError:&error]) {
            TXLogEngine(@"Erase data disk failed: %@", error ?: @"?");
        }
        [weakSelf refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)logTapped {
    TXLogViewController *logVC = [[TXLogViewController alloc] init];
    logVC.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(logDoneTapped)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logVC];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)logDoneTapped {
    __weak typeof(self) weakSelf = self;
    [self dismissViewControllerAnimated:YES completion:^{
        // The shell came up while the log was open: go to the
        // terminal now.
        if (weakSelf.presentAfterLogCloses) {
            weakSelf.presentAfterLogCloses = NO;
            [weakSelf presentTerminal];
        }
    }];
}

@end
