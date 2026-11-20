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
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TerminalViewController.h"

#import "KernEngine.h"
#import "vt.h"
#import <MetalKit/MetalKit.h>

@interface TerminalViewController () <KernEngineDelegate, UITextFieldDelegate>
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

@implementation TerminalViewController {
    KernEngine *_engine;
    MTKView *_guestView; // the guest framebuffer; hidden behind the terminal
    vt_t _vt;
    UITextView *_output;
    UITextField *_input;
    UILabel *_status;
    UIButton *_mainButton;
    UIButton *_stopButton;
    UIButton *_ctrlButton;
    UIButton *_moreButton;
    UIButton *_fnButton;
    BOOL _ctrlLatched;
    UIStackView *_secondaryRow;
    UIScrollView *_fnRow;
    NSTimer *_flushTimer;
    NSLayoutConstraint *_toolbarBottom;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    vt_init(&_vt);

    _engine = [KernEngine shared];
    _engine.delegate = self;

    // The guest's Metal view sits behind the terminal, full screen. The
    // runtime refuses a null view, and the terminal view is opaque, so
    // the framebuffer is never seen: the console is the interface.
    _guestView = [[MTKView alloc] initWithFrame:self.view.bounds];
    _guestView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_guestView];

    // Top bar: status text on the left, Install-or-Boot / Stop on the right.
    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    _status = [[UILabel alloc] init];
    _status.translatesAutoresizingMaskIntoConstraints = NO;
    _status.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    _status.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _status.numberOfLines = 2;
    _status.text = @"Starting…";
    [bar addSubview:_status];

    _mainButton = [self barButton:@"Install" action:@selector(onMain)];
    _stopButton = [self barButton:@"Stop" action:@selector(onStop)];
    [bar addSubview:_mainButton];
    [bar addSubview:_stopButton];

    // The terminal itself: NewTerm's defaults — black, #f2f2f2 text,
    // system monospace. Lines never wrap: the text container is wider
    // than the screen, so long lines scroll horizontally.
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
    _output.attributedText = [[NSAttributedString alloc] initWithString:@"TermX\n"];
    [self.view addSubview:_output];

    // Hidden field that owns the software keyboard.
    _input = [[UITextField alloc] init];
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
    // Butterfly arrows: left, up/down stacked, right.
    [self addKey:primary title:@"←" bytes:"\x1B[D" length:3];
    UIStackView *ud = [[UIStackView alloc] init];
    ud.axis = UILayoutConstraintAxisVertical;
    ud.spacing = 2;
    [self addKey:ud title:@"↑" bytes:"\x1B[A" length:3];
    [self addKey:ud title:@"↓" bytes:"\x1B[B" length:3];
    [primary addArrangedSubview:ud];
    [self addKey:primary title:@"→" bytes:"\x1B[C" length:3];
    UIButton *kbd = [self keyButton:@"⌨"];
    [kbd addTarget:self action:@selector(onKeyboard) forControlEvents:UIControlEventTouchUpInside];
    [primary addArrangedSubview:kbd];
    [rows addArrangedSubview:primary];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_guestView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_guestView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_guestView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_guestView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [bar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [bar.heightAnchor constraintEqualToConstant:44],
        [_status.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [_status.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_status.trailingAnchor constraintEqualToAnchor:_mainButton.leadingAnchor constant:-8],
        [_mainButton.trailingAnchor constraintEqualToAnchor:_stopButton.leadingAnchor constant:-6],
        [_mainButton.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_stopButton.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [_stopButton.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_output.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:2],
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

    [self termXEngineDidChangeState:_engine.state status:_engine.statusText];
}

- (UIButton *)barButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
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

- (void)addKey:(UIStackView *)row title:(NSString *)title bytes:(const char *)bytes length:(size_t)length {
    UIButton *b = [self keyButton:title];
    NSData *data = [NSData dataWithBytes:bytes length:length];
    [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [self sendKeyData:data];
    }] forControlEvents:UIControlEventTouchUpInside];
    [row addArrangedSubview:b];
}

- (void)setToggle:(UIButton *)button on:(BOOL)on {
    button.backgroundColor = on
        ? [UIColor colorWithRed:0.2 green:0.45 blue:0.85 alpha:1.0]
        : [UIColor colorWithWhite:0.16 alpha:1.0];
}

#pragma mark - Actions

- (void)onMain {
    if (_engine.state == TermXStateReady || _engine.state == TermXStateStopped) {
        [_engine bootOnView:_guestView];
        return;
    }
    if (_engine.state == TermXStateIdle || _engine.state == TermXStateFailed) {
        [_engine installGuestWithCompletion:nil];
        return;
    }
}

- (void)onStop {
    [_engine stopGuest];
}

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
    if (_input.isFirstResponder) [_input resignFirstResponder];
    else [_input becomeFirstResponder];
}

- (void)onTapTerminal {
    [_input becomeFirstResponder];
}

#pragma mark - Engine delegate

- (void)termXEngineDidChangeState:(TermXState)state status:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_status.text = status;
        self->_stopButton.enabled = (state == TermXStateRunning || state == TermXStateBooting);
        switch (state) {
        case TermXStateReady:
        case TermXStateStopped:
            [self->_mainButton setTitle:@"Boot" forState:UIControlStateNormal];
            self->_mainButton.enabled = YES;
            break;
        case TermXStateIdle:
        case TermXStateFailed:
            [self->_mainButton setTitle:@"Install" forState:UIControlStateNormal];
            self->_mainButton.enabled = YES;
            break;
        default:
            self->_mainButton.enabled = NO;
            break;
        }
        if (state == TermXStateRunning) [self->_input becomeFirstResponder];
    });
}

- (void)kernEngineDidReceiveConsoleOutput:(NSData *)data {
    vt_feed(&_vt, data.bytes, data.length);
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
    BOOL atBottom = _output.contentOffset.y + _output.bounds.size.height >=
        _output.contentSize.height - 24;
    _output.attributedText = out;
    if (atBottom) {
        NSRange end = NSMakeRange(_output.attributedText.length, 0);
        [_output scrollRangeToVisible:end];
    }
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
        uint8_t backspace = 0x7F;
        [_engine sendConsoleInput:[NSData dataWithBytes:&backspace length:1]];
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
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inView = [self.view convertRect:end fromView:nil];
    CGFloat height = MAX(0, self.view.bounds.size.height - inView.origin.y);
    _toolbarBottom.constant = -4 - height;
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        [self.view layoutIfNeeded];
    }];
    _output.contentInset = UIEdgeInsetsMake(0, 0, height, 0);
    _output.scrollIndicatorInsets = _output.contentInset;
    if (height > 0) {
        NSRange endRange = NSMakeRange(_output.attributedText.length, 0);
        [_output scrollRangeToVisible:endRange];
    }
}

- (void)dealloc {
    [_flushTimer invalidate];
    vt_free(&_vt);
}

@end
