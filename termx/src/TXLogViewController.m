// TXLogViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXLogViewController.h"
#import "TXLog.h"
#import "TXTheme.h"

@interface TXLogViewController ()
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UIButton *shareLogButton;
@property (nonatomic, strong, nullable) NSTimer *refreshTimer;
// Generation counter for the "Copied" feedback: each Copy tap
// bumps it, and the delayed reset only runs if its generation is
// still current, so a second tap's feedback runs its full duration
// instead of being cut short by the first tap's reset.
@property (nonatomic) NSUInteger copyFeedbackGeneration;
// Serial queue for the log-file reads: TXLogFullText() reads up to
// 1 MB (two 512 KB capped files), so it runs here instead of on the
// main thread, where it stalled scrolling every tick. Serial, so
// reads stay in order — a newer read can never be overwritten by an
// older one finishing late.
@property (nonatomic, strong) dispatch_queue_t logReadQueue;
// Length and hash of the text currently shown, so the refresh can
// tell on the main thread whether new text differs without laying
// out up to 1 MB of text again. Both are main-thread only: written
// when the text view is set, read in the refresh's main-queue hop.
@property (nonatomic) NSUInteger displayedLogLength;
@property (nonatomic) NSUInteger displayedLogHash;
@end

@implementation TXLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.logReadQueue = dispatch_queue_create("app.termx.ios.log-read", DISPATCH_QUEUE_SERIAL);
    self.title = @"Logs";
    self.view.backgroundColor = TXThemeBackgroundColor();

    self.logTextView = [[UITextView alloc] init];
    self.logTextView.font = TXTermFont();
    self.logTextView.textColor = TXThemeForegroundColor();
    self.logTextView.backgroundColor = TXThemeCardBackground();
    self.logTextView.layer.cornerRadius = TXThemeCornerRadiusLog;
    self.logTextView.layer.masksToBounds = YES;
    self.logTextView.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    self.logTextView.editable = NO;
    self.logTextView.selectable = YES;
    self.logTextView.translatesAutoresizingMaskIntoConstraints = NO;

    self.shareLogButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.shareLogButton setTitle:@"Copy log" forState:UIControlStateNormal];
    self.shareLogButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.shareLogButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.shareLogButton.backgroundColor = TXThemeButtonBackground();
    self.shareLogButton.layer.cornerRadius = TXThemeCornerRadiusButton;
    self.shareLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.shareLogButton.heightAnchor constraintEqualToConstant:TXThemePrimaryButtonHeightPt].active = YES;
    [self.shareLogButton addTarget:self action:@selector(copyTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.logTextView, self.shareLogButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
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
        // The log fills the available height: scroll top/bottom
        // insets (16 + 16) + stack spacing (16) + Copy button (48).
        [self.logTextView.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor constant:-96],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshLog];
    [self startRefreshTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)startRefreshTimer {
    [self.refreshTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf refreshLog];
    }];
}

// Only auto-scrolls to the newest lines if the user is already
// near the bottom, so reading an earlier line is not yanked away.
// The file read runs on logReadQueue (up to 1 MB off the main
// thread); only the compare-and-display runs on the main thread.
// The text view is rebuilt only when the new text differs — judged
// by length plus hash, both computed off the main thread — so an
// unchanged tick costs no layout of up to 1 MB of text. Equal
// strings have equal hashes, so a length + hash match means the
// display is already current; a hash collision would only skip one
// tick, and the next append changes the length and the display
// catches up.
- (void)refreshLog {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.logReadQueue, ^{
        NSString *text = TXLogFullText();
        NSUInteger length = text.length;
        NSUInteger hash = text.hash;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (length == strongSelf.displayedLogLength && hash == strongSelf.displayedLogHash) return;
            CGFloat bottom = strongSelf.logTextView.contentOffset.y + strongSelf.logTextView.bounds.size.height;
            BOOL nearBottom = (strongSelf.logTextView.contentSize.height - bottom) < 60;
            strongSelf.logTextView.text = text;
            strongSelf.displayedLogLength = length;
            strongSelf.displayedLogHash = hash;
            if (nearBottom) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSRange end = NSMakeRange(strongSelf.logTextView.text.length, 0);
                    [strongSelf.logTextView scrollRangeToVisible:end];
                });
            }
        });
    });
}

- (void)copyTapped {
    [UIPasteboard generalPasteboard].string = self.logTextView.text ?: @"";
    [self.shareLogButton setTitle:@"Copied" forState:UIControlStateNormal];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Log copied");
    self.copyFeedbackGeneration++;
    NSUInteger generation = self.copyFeedbackGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.copyFeedbackGeneration != generation) return;
        [strongSelf.shareLogButton setTitle:@"Copy log" forState:UIControlStateNormal];
    });
}

@end
