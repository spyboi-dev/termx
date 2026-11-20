// TXLogViewController - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXLogViewController.h"
#import "TXLog.h"

@interface TXLogViewController ()
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UIButton *shareLogButton;
@property (nonatomic, strong, nullable) NSTimer *refreshTimer;
@end

@implementation TXLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Logs";
    self.view.backgroundColor = [UIColor blackColor];

    UILabel *header = [[UILabel alloc] init];
    header.font = [UIFont boldSystemFontOfSize:17];
    header.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    header.text = @"Engine log + guest console";
    header.translatesAutoresizingMaskIntoConstraints = NO;

    self.logTextView = [[UITextView alloc] init];
    self.logTextView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logTextView.textColor = [UIColor colorWithRed:0xF2 / 255.0 green:0xF2 / 255.0 blue:0xF2 / 255.0 alpha:1.0];
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
- (void)refreshLog {
    NSString *text = TXLogFullText();
    if ([text isEqualToString:self.logTextView.text]) return;
    CGFloat bottom = self.logTextView.contentOffset.y + self.logTextView.bounds.size.height;
    BOOL nearBottom = (self.logTextView.contentSize.height - bottom) < 60;
    self.logTextView.text = text;
    if (nearBottom) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSRange end = NSMakeRange(self.logTextView.text.length, 0);
            [self.logTextView scrollRangeToVisible:end];
        });
    }
}

- (void)copyTapped {
    [UIPasteboard generalPasteboard].string = self.logTextView.text ?: @"";
    [self.shareLogButton setTitle:@"Copied" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.shareLogButton setTitle:@"Copy log" forState:UIControlStateNormal];
    });
}

@end
