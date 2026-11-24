// TXLogViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXLogViewController.h"
#import "TXLog.h"
#import "TXTheme.h"

@interface TXLogViewController ()
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UIButton *shareLogButton;
@property (nonatomic, strong, nullable) NSTimer *refreshTimer;
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

    UILabel *header = [[UILabel alloc] init];
    header.font = [UIFont boldSystemFontOfSize:17];
    header.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    header.text = @"Engine log + guest console";
    header.translatesAutoresizingMaskIntoConstraints = NO;

    self.logTextView = [[UITextView alloc] init];
    self.logTextView.font = TXTermFont();
    self.logTextView.textColor = TXThemeForegroundColor();
    self.logTextView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    self.logTextView.layer.cornerRadius = 18;
    self.logTextView.layer.masksToBounds = YES;
    self.logTextView.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    self.logTextView.editable = NO;
    self.logTextView.selectable = YES;
    self.logTextView.translatesAutoresizingMaskIntoConstraints = NO;

    self.shareLogButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.shareLogButton setTitle:@"Copy log" forState:UIControlStateNormal];
    self.shareLogButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.shareLogButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.shareLogButton.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    self.shareLogButton.layer.cornerRadius = 12;
    self.shareLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.shareLogButton.heightAnchor constraintEqualToConstant:48].active = YES;
    [self.shareLogButton addTarget:self action:@selector(copyTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header, self.logTextView, self.shareLogButton]];
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
        [self.logTextView.heightAnchor constraintEqualToConstant:420],
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.shareLogButton setTitle:@"Copy log" forState:UIControlStateNormal];
    });
}

@end
