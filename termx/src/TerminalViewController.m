// TerminalViewController implementation. See the header.
//
// The terminal screen follows NewTerm 3's model (hbang/NewTerm, Apache-2.0):
// a scrolling line-based terminal, 80x25, xterm-256color, system monospace
// font, black background, and the keyboard toolbar above the software
// keyboard: Ctrl (toggle), Esc, Tab, More (toggle) and butterfly arrows on
// the primary row; Home, End, PgUp, PgDn, Del and Fn (toggle) on the
// secondary row; F1-F12 on a horizontally scrolling Fn row. The VT
// emulation is our own vt.c (NewTerm uses SwiftTerm, which is Swift and
// cannot build here); the key bytes match NewTerm's TerminalConstants
// exactly. The shell itself lives in the guest, never on iOS: typed input
// goes to the guest console, guest output feeds the terminal view.
// Scrolling follows the rule every mobile terminal uses (NewTerm,
// Blink, Termius): output follows the bottom only while the user is
// pinned there; once they scroll up into the scrollback the view stays
// exactly where they put it, and a floating button takes them back down.
// The engine buffers console output from boot and the terminal replays
// it on presentation, so the boot log and the login prompt are visible
// even though the terminal only exists 0.7 s after the shell is ready.
// There is no top bar and no control button on this screen at all: the
// startup screen is the control centre, and a swipe down from the top
// edge — only when already at the very top of the scrollback — returns
// to it.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TerminalViewController.h"

#import "KernEngine.h"
#import "vt.h"

@interface TerminalViewController () <KernEngineDelegate, UITextFieldDelegate, UITextViewDelegate, UIGestureRecognizerDelegate>
@end

// xterm 256-colour palette: 0-15 the standard colours, 16-231 the 6x6x6
// cube (levels 0, 95, 135, 175, 215, 255), 232-255 the grey ramp.
static UIColor *XTermColor(int index) {
    static const uint8_t base[16][3] = {
        {0,0,0}, {205,0,0}, {0,205,0}, {205,205,0},
        {0,0,238}, {205,0,205}, {0,205,205}, {229,229,229},
        {127,127,127}, {255,0,0}, {0,255,0}, {255,255,0},
        {92,92,255}, {255,0,255}, {0,255,255}, {255,255,255}
    };
    uint8_t r, g, b;
    if (index < 16) {
        r = base[index][0]; g = base[index][1]; b = base[index][2];
    } else if (index < 232) {
        int n = index - 16;
        static const uint8_t levels[6] = {0, 95, 135, 175, 215, 255};
        r = levels[n / 36]; g = levels[(n / 6) % 6]; b = levels[n % 6];
    } else {
        r = g = b = (uint8_t)(8 + (index - 232) * 10);
    }
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0];
}

static const uint8_t kFnBytes[12][6] = {
    {0x1B, 'O', 'P'}, {0x1B, 'O', 'Q'}, {0x1B, 'O', 'R'}, {0x1B, 'O', 'S'},
    {0x1B, '[', '1', '5', '~'}, {0x1B, '[', '1', '7', '~'},
    {0x1B, '[', '1', '8', '~'}, {0x1B, '[', '1', '9', '~'},
    {0x1B, '[', '2', '0', '~'}, {0x1B, '[', '2', '1', '~'},
    {0x1B, '[', '2', '3', '~'}, {0x1B, '[', '2', '4', '~'},
};
static const size_t kFnLens[12] = {3, 3, 3, 3, 5, 5, 5, 5, 5, 5, 5, 5};

// The hidden field that owns the software keyboard. A plain
// UITextField swallows the delete key when it is empty: UIKit calls
// deleteBackward on the field instead of consulting the delegate,
// and the default implementation has nothing to delete, so no byte
// ever reaches the guest. This app never stores text in the field
// (the delegate returns NO for every change), so the field is always
// empty and backspace silently did nothing. The subclass intercepts
// deleteBackward and reports it, so one keypress sends exactly one
// DEL (0x7F, the Linux console erase character).
@interface TXTerminalInputField : UITextField
@property (nonatomic, copy) void (^onDeleteBackward)(void);
@end

@implementation TXTerminalInputField
- (void)deleteBackward {
    // No [super deleteBackward]: the field is intentionally kept
    // empty, so there is nothing for super to delete, and calling it
    // would route through the delegate's backspace branch as well and
    // send a second DEL for the same keypress.
    if (self.onDeleteBackward) self.onDeleteBackward();
}
@end

@implementation TerminalViewController {
    KernEngine *_engine;
    vt_t _vt;
    UITextView *_output;
    TXTerminalInputField *_input;
    UIButton *_ctrlButton;
    UIButton *_moreButton;
    UIButton *_fnButton;
    BOOL _ctrlLatched;
    UIStackView *_secondaryRow;
    UIScrollView *_fnRow;
    NSTimer *_flushTimer;
    NSLayoutConstraint *_toolbarBottom;
    CGPoint _exitPanStart; // where the top-edge exit drag began
    BOOL _exitPanAtTop;    // scrollback already at its top when the drag began
    UIButton *_jumpToBottomButton; // shown only while scrolled up (Blink/Termius pattern)
    NSTimer *_repeatTimer; // arrow key repeat (NewTerm 2.4: hold to repeat)
    NSData *_repeatData;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    vt_init(&_vt);

    _engine = [KernEngine shared];
    _engine.delegate = self;

    // Replay the console output from before this screen existed: the
    // engine's delegate is nil until here, so the boot log and the
    // login prompt printed during boot would otherwise never reach
    // the view and the terminal would start black. Feed it in small
    // chunks, the way the runtime delivers live output — the parser
    // keeps its state across calls, so chunked feeding renders
    // exactly what one big feed would, and the single 128 KiB call
    // is a code path live delivery never exercises. The whole buffer
    // is still replayed: only the earliest kernel lines would be
    // beyond the scrollback anyway.
    NSData *backlog = [_engine bufferedConsoleOutput];
    if (backlog.length) {
        const uint8_t *bytes = backlog.bytes;
        size_t remaining = backlog.length;
        while (remaining > 0) {
            size_t chunk = remaining > 1024 ? 1024 : remaining;
            vt_feed(&_vt, bytes, chunk);
            bytes += chunk;
            remaining -= chunk;
        }
    }

    // The terminal itself: NewTerm's defaults — black, #f2f2f2 text,
    // system monospace. Lines never wrap: the text container is wider
    // than the screen, so long lines scroll horizontally. It starts
    // at the top of the screen: there is no bar above it any more.
    _output = [[UITextView alloc] init];
    _output.translatesAutoresizingMaskIntoConstraints = NO;
    _output.editable = NO;
    _output.selectable = YES;
    _output.backgroundColor = [UIColor blackColor];
    _output.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _output.textContainer.lineBreakMode = NSLineBreakByClipping;
    _output.textContainer.size = CGSizeMake(10000, CGFLOAT_MAX);
    _output.textContainerInset = UIEdgeInsetsMake(6, 6, 6, 6);
    _output.autocorrectionType = UITextAutocorrectionTypeNo;
    // The text view ends at the toolbar, and the toolbar already rides
    // above the keyboard, so the keyboard never overlaps this view and
    // it needs no bottom inset at all. A keyboard-height inset used to
    // be set here in keyboardWillChange:, and it created ~346 pt of
    // phantom scrollable padding below the real content: scroll-to-
    // bottom then landed past the last line of text, and the terminal
    // opened black until the user swiped down. The inset is gone; the
    // toolbar constraint is what clears the keyboard. Never re-add it:
    // every bottom computation (pinned check, scroll-to-bottom, flush
    // restore) reads contentInset.bottom, so any inset here shifts the
    // "bottom" past the text by exactly that amount.
    _output.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _output.contentInset = UIEdgeInsetsZero;
    _output.scrollIndicatorInsets = UIEdgeInsetsZero;
    // Explicit attributes: a bare string renders in the text view's
    // default colour, which is black-on-black in dark mode.
    _output.attributedText = [[NSAttributedString alloc] initWithString:@"TermX\n" attributes:@{
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.92 alpha:1.0],
    }];
    _output.delegate = self; // scrollViewDidScroll: drives the jump-to-bottom button
    [self.view addSubview:_output];

    // Hidden field that owns the software keyboard.
    _input = [[TXTerminalInputField alloc] init];
    __weak typeof(self) weakSelf = self;
    _input.onDeleteBackward = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf sendBackspace];
    };
    _input.delegate = self;
    _input.autocorrectionType = UITextAutocorrectionTypeNo;
    _input.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _input.returnKeyType = UIReturnKeyDefault;
    [self.view addSubview:_input];

    // The keyboard toolbar, NewTerm's model: a blurred bar with the key
    // rows, riding above the software keyboard.
    UIVisualEffectView *toolbar = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:toolbar];

    UIStackView *rows = [[UIStackView alloc] init];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 4;
    [toolbar.contentView addSubview:rows];

    // Fn row (hidden until Fn is toggled): F1-F12, horizontally scrolling.
    _fnRow = [[UIScrollView alloc] init];
    _fnRow.translatesAutoresizingMaskIntoConstraints = NO;
    _fnRow.showsHorizontalScrollIndicator = NO;
    UIStackView *fnStack = [[UIStackView alloc] init];
    fnStack.translatesAutoresizingMaskIntoConstraints = NO;
    fnStack.axis = UILayoutConstraintAxisHorizontal;
    fnStack.spacing = 6;
    [_fnRow addSubview:fnStack];
    for (int i = 0; i < 12; i++) {
        NSString *title = [NSString stringWithFormat:@"f%d", i + 1];
        UIButton *b = [self keyButton:title];
        NSData *data = [NSData dataWithBytes:kFnBytes[i] length:kFnLens[i]];
        [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            (void)action;
            [self sendKeyData:data];
        }] forControlEvents:UIControlEventTouchUpInside];
        [fnStack addArrangedSubview:b];
    }
    [NSLayoutConstraint activateConstraints:@[
        [fnStack.leadingAnchor constraintEqualToAnchor:_fnRow.leadingAnchor constant:6],
        [fnStack.trailingAnchor constraintEqualToAnchor:_fnRow.trailingAnchor constant:-6],
        [fnStack.topAnchor constraintEqualToAnchor:_fnRow.topAnchor],
        [fnStack.bottomAnchor constraintEqualToAnchor:_fnRow.bottomAnchor],
        [fnStack.heightAnchor constraintEqualToConstant:34],
    ]];
    _fnRow.hidden = YES;
    [rows addArrangedSubview:_fnRow];

    // Secondary row (hidden until More is toggled): Home End PgUp PgDn Del Fn.
    _secondaryRow = [[UIStackView alloc] init];
    _secondaryRow.translatesAutoresizingMaskIntoConstraints = NO;
    _secondaryRow.axis = UILayoutConstraintAxisHorizontal;
    _secondaryRow.spacing = 6;
    [self addKey:_secondaryRow title:@"home" bytes:"\x1B[H" length:3];
    [self addKey:_secondaryRow title:@"end" bytes:"\x1B[F" length:3];
    UIView *sp1 = [[UIView alloc] init];
    [_secondaryRow addArrangedSubview:sp1];
    [self addKey:_secondaryRow title:@"pgup" bytes:"\x1B[5~" length:4];
    [self addKey:_secondaryRow title:@"pgdn" bytes:"\x1B[6~" length:4];
    UIView *sp2 = [[UIView alloc] init];
    [_secondaryRow addArrangedSubview:sp2];
    [self addKey:_secondaryRow title:@"del" bytes:"\x1B[3~" length:4];
    UIView *sp3 = [[UIView alloc] init];
    [_secondaryRow addArrangedSubview:sp3];
    _fnButton = [self keyButton:@"fn"];
    [_fnButton addTarget:self action:@selector(onFn) forControlEvents:UIControlEventTouchUpInside];
    [_secondaryRow addArrangedSubview:_fnButton];
    _secondaryRow.hidden = YES;
    [rows addArrangedSubview:_secondaryRow];

    // Primary row: Ctrl Esc Tab More ... butterfly arrows.
    UIStackView *primary = [[UIStackView alloc] init];
    primary.translatesAutoresizingMaskIntoConstraints = NO;
    primary.axis = UILayoutConstraintAxisHorizontal;
    primary.spacing = 6;
    _ctrlButton = [self keyButton:@"ctrl"];
    [_ctrlButton addTarget:self action:@selector(onCtrl) forControlEvents:UIControlEventTouchUpInside];
    [primary addArrangedSubview:_ctrlButton];
    [self addKey:primary title:@"esc" bytes:"\x1B" length:1];
    [self addKey:primary title:@"tab" bytes:"\t" length:1];
    _moreButton = [self keyButton:@"more"];
    [_moreButton addTarget:self action:@selector(onMore) forControlEvents:UIControlEventTouchUpInside];
    [primary addArrangedSubview:_moreButton];
    UIView *spacer = [[UIView alloc] init];
    [primary addArrangedSubview:spacer];
    // Butterfly arrows: left, up/down stacked, right. The up/down pair
    // are half-height buttons (16 pt each + 2 pt spacing = 34 pt, the
    // row height); a full keyButton is ~29 pt tall, so two of those in
    // a 34 pt row were compressed and their glyphs overflowed and drew
    // on top of each other. All four arrows repeat while held.
    [self addArrowKey:primary title:@"←" tag:0 halfHeight:NO];
    UIStackView *ud = [[UIStackView alloc] init];
    ud.axis = UILayoutConstraintAxisVertical;
    ud.spacing = 2;
    ud.distribution = UIStackViewDistributionFillEqually;
    [self addArrowKey:ud title:@"↑" tag:1 halfHeight:YES];
    [self addArrowKey:ud title:@"↓" tag:2 halfHeight:YES];
    [primary addArrangedSubview:ud];
    [self addArrowKey:primary title:@"→" tag:3 halfHeight:NO];
    UIButton *kbd = [self keyButton:@"⌨"];
    kbd.titleLabel.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightMedium];
    [kbd.widthAnchor constraintEqualToConstant:44].active = YES;
    [kbd addTarget:self action:@selector(onKeyboard) forControlEvents:UIControlEventTouchUpInside];
    [primary addArrangedSubview:kbd];
    [rows addArrangedSubview:primary];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_output.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_output.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_output.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_output.bottomAnchor constraintEqualToAnchor:toolbar.topAnchor],
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [rows.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor constant:4],
        [rows.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor constant:-4],
        [rows.topAnchor constraintEqualToAnchor:toolbar.topAnchor constant:5],
        [rows.bottomAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:-4],
        [_fnRow.heightAnchor constraintEqualToConstant:34],
        [_secondaryRow.heightAnchor constraintEqualToConstant:34],
        [primary.heightAnchor constraintEqualToConstant:34],
    ]];
    // The toolbar rides above the software keyboard when it appears.
    _toolbarBottom = [toolbar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4];
    _toolbarBottom.active = YES;

    // Jump-to-bottom button (Blink/Termius pattern): appears only
    // while the user has scrolled up into the scrollback, and takes
    // them back to the live prompt. It rides just above the toolbar.
    _jumpToBottomButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _jumpToBottomButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_jumpToBottomButton setTitle:@"↓ Bottom" forState:UIControlStateNormal];
    _jumpToBottomButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [_jumpToBottomButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _jumpToBottomButton.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.9];
    _jumpToBottomButton.layer.cornerRadius = 14;
    _jumpToBottomButton.contentEdgeInsets = UIEdgeInsetsMake(4, 12, 4, 12);
    _jumpToBottomButton.hidden = YES;
    [_jumpToBottomButton addTarget:self action:@selector(onJumpToBottom) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_jumpToBottomButton];
    [NSLayoutConstraint activateConstraints:@[
        [_jumpToBottomButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [_jumpToBottomButton.bottomAnchor constraintEqualToAnchor:toolbar.topAnchor constant:-8],
        [_jumpToBottomButton.heightAnchor constraintEqualToConstant:28],
    ]];

    // Render the terminal at most every 60 ms; the guest sends a few bytes
    // at a time and redrawing on every one would thrash.
    _flushTimer = [NSTimer scheduledTimerWithTimeInterval:0.06 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [self flushTerminal];
    }];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onTapTerminal)];
    [_output addGestureRecognizer:tap];

    // The way back to the startup screen: a downward drag that
    // starts in the top strip of the terminal. A scroll through the
    // scrollback starts anywhere and goes either way; this one only
    // fires for a drag that begins at the very top and moves
    // decisively down, so ordinary scrolling never triggers it.
    UIPanGestureRecognizer *exitPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onExitPan:)];
    exitPan.delegate = self;
    [_output addGestureRecognizer:exitPan];

    [self termXEngineDidChangeState:_engine.state status:_engine.statusText];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // First render with final geometry: the 60 ms timer will flush
    // anyway, but this guarantees the view starts pinned to the live
    // line (not to a stale offset from before layout) the moment it
    // is on screen. Harmless when nothing has arrived yet: the flush
    // returns early while the VT is clean and scroll-to-bottom is a
    // no-op on short content.
    [self.view layoutIfNeeded];
    [self flushTerminal];
    if ([self isPinnedToBottom]) [self scrollToBottomAnimated:NO];
}

- (UIButton *)keyButton:(NSString *)title {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    b.layer.cornerRadius = 7;
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
    return b;
}

- (void)sendKeyData:(NSData *)data {
    [[UIDevice currentDevice] playInputClick];
    [_engine sendConsoleInput:data];
}

// Backspace: DEL (0x7F), the Linux console erase character. One
// place for both callers: the deleteBackward override on the empty
// field, and the delegate's backspace branch for the (currently
// impossible) case where the field holds text.
- (void)sendBackspace {
    uint8_t backspace = 0x7F;
    [_engine sendConsoleInput:[NSData dataWithBytes:&backspace length:1]];
}

- (void)addKey:(UIStackView *)row title:(NSString *)title bytes:(const char *)bytes length:(size_t)length {
    UIButton *b = [self keyButton:title];
    NSData *data = [NSData dataWithBytes:bytes length:length];
    [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [self sendKeyData:data];
    }] forControlEvents:UIControlEventTouchUpInside];
    [row addArrangedSubview:b];
}

// Half-height arrow button for the up/down pair: two of these plus
// the 2 pt stack spacing fit the 34 pt primary row exactly (16+2+16).
// An 11 pt glyph fits the 16 pt height with no vertical insets.
- (UIButton *)arrowButton:(NSString *)title {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    b.layer.cornerRadius = 6;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
    [b.heightAnchor constraintEqualToConstant:16].active = YES;
    return b;
}

// Arrow keys by tag: 0 left, 1 up, 2 down, 3 right (xterm sequences).
- (NSData *)arrowDataForTag:(NSInteger)tag {
    static const char *bytes[4] = {"\x1B[D", "\x1B[A", "\x1B[B", "\x1B[C"};
    if (tag < 0 || tag > 3) return nil;
    return [NSData dataWithBytes:bytes[tag] length:3];
}

- (void)addArrowKey:(UIStackView *)row title:(NSString *)title tag:(NSInteger)tag halfHeight:(BOOL)halfHeight {
    UIButton *b = halfHeight ? [self arrowButton:title] : [self keyButton:title];
    b.tag = tag;
    [b addTarget:self action:@selector(arrowTouchDown:) forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:@selector(arrowTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [row addArrangedSubview:b];
}

// Arrow key repeat (NewTerm 2.4): a tap sends once, holding repeats
// after 0.4 s at 12 Hz, so scrolling through shell history does not
// need a tap per line.
- (void)arrowTouchDown:(UIButton *)sender {
    NSData *data = [self arrowDataForTag:sender.tag];
    if (data) [self startKeyRepeat:data];
}

- (void)arrowTouchUp:(UIButton *)sender {
    (void)sender;
    [self stopKeyRepeat];
}

- (void)startKeyRepeat:(NSData *)data {
    [self stopKeyRepeat];
    _repeatData = data;
    [self sendKeyData:data];
    __weak typeof(self) weakSelf = self;
    _repeatTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer *t) {
        (void)t;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { [t invalidate]; return; }
        [strongSelf sendKeyData:strongSelf->_repeatData];
    }];
    [_repeatTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
}

- (void)stopKeyRepeat {
    [_repeatTimer invalidate];
    _repeatTimer = nil;
    _repeatData = nil;
}

- (void)setToggle:(UIButton *)button on:(BOOL)on {
    button.backgroundColor = on
        ? [UIColor colorWithRed:0.2 green:0.45 blue:0.85 alpha:1.0]
        : [UIColor colorWithWhite:0.16 alpha:1.0];
}

#pragma mark - Actions

- (void)onCtrl {
    _ctrlLatched = !_ctrlLatched;
    [self setToggle:_ctrlButton on:_ctrlLatched];
}

- (void)onMore {
    _secondaryRow.hidden = !_secondaryRow.hidden;
    [self setToggle:_moreButton on:!_secondaryRow.hidden];
    if (_secondaryRow.hidden && !_fnRow.hidden) {
        _fnRow.hidden = YES;
        [self setToggle:_fnButton on:NO];
    }
}

- (void)onFn {
    _fnRow.hidden = !_fnRow.hidden;
    [self setToggle:_fnButton on:!_fnRow.hidden];
}

- (void)onKeyboard {
    // Dismiss only, never toggle back on: endEditing resigns
    // whichever field actually owns the keyboard (the hidden _input).
    // Tapping the terminal brings the keyboard back.
    [self.view endEditing:YES];
}

- (void)onTapTerminal {
    [_input becomeFirstResponder];
}

// The exit drag: a downward pan that began in the top strip of the
// terminal returns to the startup screen, where Stop, Logs, Install
// and Boot live. It only fires when the scrollback is already at its
// very top: anywhere else, a downward drag is the user scrolling
// through the output, not asking to leave.
- (void)onExitPan:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _exitPanStart = [pan locationInView:_output];
            _exitPanAtTop = _output.contentOffset.y <= 1;
            break;
        case UIGestureRecognizerStateEnded: {
            CGPoint translation = [pan translationInView:_output];
            if (_exitPanAtTop && _exitPanStart.y < 44 && translation.y > 80 &&
                fabs(translation.y) > fabs(translation.x)) {
                [self dismissViewControllerAnimated:YES completion:nil];
            }
            break;
        }
        default:
            break;
    }
}

// Let the exit pan watch touches alongside the text view's own
// scrolling, so a drag can be both a scroll and a candidate exit.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer; (void)otherGestureRecognizer;
    return YES;
}

#pragma mark - Engine delegate

- (void)termXEngineDidChangeState:(TermXState)state status:(NSString *)status {
    (void)status;
    // The only thing the terminal itself does with state: focus the
    // keyboard once the shell is up, so the user can type at once.
    if (state == TermXStateRunning) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_input becomeFirstResponder];
        });
    }
}

- (void)kernEngineDidReceiveConsoleOutput:(NSData *)data {
    // The runtime calls this on its own thread, but the VT (grid,
    // scrollback and its file-static parser state in vt.c) is only
    // ever touched on the main thread, where the flush timer also
    // runs — feeding it from here would race the flush.
    dispatch_async(dispatch_get_main_queue(), ^{
        vt_feed(&_vt, data.bytes, data.length);
    });
}

- (UIColor *)colorForCell:(vt_cell)cell isForeground:(BOOL)isFg {
    int16_t index = isFg ? cell.fg : cell.bg;
    if (index < 0) {
        return isFg ? [UIColor colorWithRed:0xF2 / 255.0 green:0xF2 / 255.0 blue:0xF2 / 255.0 alpha:1.0]
                    : [UIColor blackColor];
    }
    // Bold text in colours 0-7 renders as the bright variant, as xterm does.
    if (isFg && cell.bold && index < 8) index += 8;
    return XTermColor((int)index);
}

- (void)flushTerminal {
    if (!_vt.dirty) return;
    // The 60 ms timer rebuilds the whole attributed string every
    // flush. Setting attributedText resets the scroll position, so the
    // old code yanked the view to the bottom on every flush and a
    // swipe down was undone 60 ms later — "it go up again and again".
    // The fix is the rule every mobile terminal uses: follow the
    // bottom only while the user is already pinned there; when they
    // have scrolled up into the scrollback, put the view back exactly
    // where they left it. _vt.dirty is cleared here and set again by
    // vt_feed on new output, so an idle terminal does no work at all
    // (before this the flag was never cleared and every flush rebuilt
    // the string forever, even with no new output).
    _vt.dirty = 0;
    BOOL pinned = [self isPinnedToBottom];
    BOOL userScrolling = _output.isTracking || _output.isDragging || _output.isDecelerating;
    CGPoint savedOffset = _output.contentOffset;
    UIFont *font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    // Scrollback stays plain text (vt.c keeps no colours for it).
    NSDictionary *plain = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.92 alpha:1.0],
    };
    for (int i = 0; i < _vt.scrollback_count; i++) {
        NSString *line = [NSString stringWithUTF8String:_vt.scrollback[i]];
        if (!line) continue;
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:[line stringByAppendingString:@"\n"] attributes:plain]];
    }
    // The grid renders with per-cell colours, grouped into runs.
    for (int r = 0; r < VT_ROWS; r++) {
        int last = VT_COLS - 1;
        while (last >= 0 && _vt.grid[r][last].ch == 0) last--;
        if (r == _vt.cy && _vt.cx > last) last = _vt.cx; // keep the cursor cell
        NSMutableString *runText = [NSMutableString string];
        vt_cell runCell = _vt.grid[r][0];
        BOOL haveRun = NO;
        for (int c = 0; c <= last; c++) {
            vt_cell cell = _vt.grid[r][c];
            BOOL isCursor = (r == _vt.cy && c == _vt.cx);
            if (haveRun && (cell.fg != runCell.fg || cell.bg != runCell.bg ||
                            cell.bold != runCell.bold || isCursor)) {
                [self appendRun:out text:runText cell:runCell font:font cursor:NO];
                [runText setString:@""];
                haveRun = NO;
            }
            if (!haveRun) { runCell = cell; haveRun = YES; }
            if (cell.ch == 0) [runText appendString:@" "];
            else if (cell.ch < 0x10000) [runText appendFormat:@"%C", (unichar)cell.ch];
            else {
                // Astral plane: emit the UTF-16 surrogate pair.
                uint32_t v = cell.ch - 0x10000;
                unichar pair[2] = { (unichar)(0xD800 + (v >> 10)), (unichar)(0xDC00 + (v & 0x3FF)) };
                [runText appendString:[NSString stringWithCharacters:pair length:2]];
            }
            if (isCursor) {
                [self appendRun:out text:runText cell:runCell font:font cursor:YES];
                [runText setString:@""];
                haveRun = NO;
            }
        }
        if (haveRun) [self appendRun:out text:runText cell:runCell font:font cursor:NO];
        if (r < VT_ROWS - 1) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:plain]];
    }
    _output.attributedText = out;
    [_output layoutIfNeeded]; // contentSize is current before we measure it
    if (!userScrolling) {
        if (pinned) [self scrollToBottomAnimated:NO];
        else {
            // Restore the saved offset, clamped to the new content
            // height (a clear-screen can shrink it under the old one).
            CGFloat maxOffset = _output.contentSize.height + _output.contentInset.bottom - _output.bounds.size.height;
            CGFloat minY = -_output.contentInset.top;
            CGPoint restored = savedOffset;
            restored.y = MIN(MAX(restored.y, minY), MAX(maxOffset, minY));
            _output.contentOffset = restored;
        }
    }
    [self updateJumpToBottomButton];
}

// Pinned means the last visible line is the live one: the bottom of
// the content is within one line of the bottom of the view.
// contentInset.bottom is zero by design (the toolbar clears the
// keyboard, so the text view takes no inset — see viewDidLoad), and
// this check reads it, so if an inset ever comes back the "bottom"
// moves past the text by exactly that amount and the terminal opens
// black. Keep it zero.
- (BOOL)isPinnedToBottom {
    CGFloat bottomOffset = _output.contentSize.height + _output.contentInset.bottom - _output.bounds.size.height;
    if (bottomOffset <= 0) return YES;
    return _output.contentOffset.y >= bottomOffset - 16.0;
}

- (void)scrollToBottomAnimated:(BOOL)animated {
    CGFloat maxOffset = _output.contentSize.height + _output.contentInset.bottom - _output.bounds.size.height;
    CGFloat y = MAX(maxOffset, -_output.contentInset.top);
    [_output setContentOffset:CGPointMake(_output.contentOffset.x, y) animated:animated];
}

- (void)updateJumpToBottomButton {
    _jumpToBottomButton.hidden = [self isPinnedToBottom];
}

- (void)onJumpToBottom {
    [self scrollToBottomAnimated:YES];
}

// UITextViewDelegate: keep the jump-to-bottom button in step with
// where the user actually is.
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    (void)scrollView;
    [self updateJumpToBottomButton];
}

- (void)appendRun:(NSMutableAttributedString *)out text:(NSString *)text
             cell:(vt_cell)cell font:(UIFont *)font cursor:(BOOL)cursor {
    if (text.length == 0) return;
    UIColor *fg, *bg;
    if (cursor) {
        fg = [UIColor blackColor];
        bg = [UIColor colorWithWhite:0.92 alpha:1.0];
    } else {
        fg = [self colorForCell:cell isForeground:YES];
        bg = [self colorForCell:cell isForeground:NO];
    }
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: fg,
        NSBackgroundColorAttributeName: bg,
    };
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
}

#pragma mark - Typing

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range
    replacementString:(NSString *)string {
    (void)textField;
    if (string.length == 0 && range.length == 1) {
        // Delete with text in the field (only reachable if the field
        // ever holds text; it is normally empty, so the deleteBackward
        // override on TXTerminalInputField is the live path).
        [self sendBackspace];
        return NO;
    }
    if (string.length == 0) return NO;
    if ([string isEqualToString:@"\n"]) {
        // NewTerm sends carriage return, not line feed.
        uint8_t cr = '\r';
        [_engine sendConsoleInput:[NSData dataWithBytes:&cr length:1]];
        return NO;
    }
    if (_ctrlLatched) {
        // Ctrl plus a letter: send the control byte, then unlatch.
        unichar c = [string characterAtIndex:0];
        uint8_t control = 0;
        if (c >= 'a' && c <= 'z') control = (uint8_t)(c - 'a' + 1);
        else if (c >= 'A' && c <= 'Z') control = (uint8_t)(c - 'A' + 1);
        else if (c == '[') control = 0x1B;
        else if (c == '\\') control = 0x1C;
        else if (c == ']') control = 0x1D;
        else if (c == '^') control = 0x1E;
        else if (c == '_') control = 0x1F;
        if (control) {
            [_engine sendConsoleInput:[NSData dataWithBytes:&control length:1]];
            [self onCtrl];
            return NO;
        }
        [self onCtrl];
    }
    [_engine sendConsoleInput:[string dataUsingEncoding:NSUTF8StringEncoding]];
    return NO;
}

#pragma mark - Keyboard

- (void)keyboardWillChange:(NSNotification *)note {
    // Capture the pinned state before the layout changes: the
    // keyboard showing or hiding must not move a user who scrolled
    // up into the scrollback, and must keep a pinned user on the
    // live line as the toolbar moves. The text view itself takes no
    // bottom inset — it ends at the toolbar, which already rides
    // above the keyboard (see viewDidLoad); an inset here would only
    // add phantom scrollable padding below the text.
    BOOL wasPinned = [self isPinnedToBottom];
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inView = [self.view convertRect:end fromView:nil];
    CGFloat height = MAX(0, self.view.bounds.size.height - inView.origin.y);
    _toolbarBottom.constant = -4 - height;
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        [self.view layoutIfNeeded];
        if (wasPinned) [self scrollToBottomAnimated:NO];
    }];
}

- (void)dealloc {
    [_flushTimer invalidate];
    [_repeatTimer invalidate];
    vt_free(&_vt);
}

@end
