// TerminalViewController implementation. See the header.
//
// The terminal screen follows NewTerm 3's model (hbang/NewTerm, Apache-2.0):
// a scrolling terminal, system monospace font, and the keyboard toolbar
// above the software keyboard: Ctrl (toggle), Alt (toggle), Esc, Tab,
// More (toggle), Paste, and four separate arrow keys on the primary row;
// Home, End, PgUp, PgDn, Del, Copy and Fn (toggle) on the secondary row;
// F1-F12 on a horizontally scrolling Fn row. Alt prefixes ESC to the
// next input, the standard terminal behaviour (Emacs, tmux, readline).
// The terminal itself is Ghostty (libghostty) now, not the old hand-
// rolled vt.c + UITextView: TXGhosttyView owns the Ghostty surface and
// renders it with Metal, so rich TUIs (OpenCode, tmux, vim) render
// correctly. The shell itself lives in the guest, never on iOS: typed
// input goes through Ghostty to the guest console, guest output feeds
// the Ghostty surface.
// The engine buffers console output from boot and the terminal replays
// it on presentation, so the boot log and the login prompt are visible
// even though the terminal only exists 0.7 s after the shell is ready.
// There is no top bar and no control button on this screen at all: the
// startup screen is the control centre, and a swipe down from the top
// edge returns to it.
//
// The look is the shared TXTheme: a pure black background with
// soft-white text, and one 14 pt monospace font.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TerminalViewController.h"

#import "KernEngine.h"
#import "TXConfig.h"
#import "TXGhosttyView.h"
#import "TXLog.h"
#import "TXTheme.h"

@interface TerminalViewController () <KernEngineDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate>
@end

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

// Label with text insets, for the guest-dead notice pill: the text
// sits 12 pt from the sides and 8 pt from the top and bottom instead
// of flush against the pill's edges.
@interface TXPaddedLabel : UILabel
@end

@implementation TXPaddedLabel
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(8, 12, 8, 12))];
}
- (CGSize)intrinsicContentSize {
    CGSize size = [super intrinsicContentSize];
    return CGSizeMake(size.width + 24, size.height + 16);
}
@end

@implementation TerminalViewController {
    KernEngine *_engine;
    TXGhosttyView *_output;
    TXTerminalInputField *_input;
    UIButton *_ctrlButton;
    UIButton *_altButton;
    UIButton *_moreButton;
    UIButton *_fnButton;
    BOOL _ctrlLatched;
    BOOL _altLatched;
    UIStackView *_secondaryRow;
    UIScrollView *_fnRow;
    NSLayoutConstraint *_toolbarBottom;
    BOOL _didClearScreenOnBoot; // clear-on-boot already done for this terminal instance
    CGPoint _exitPanStart; // where the top-edge exit drag began
    NSTimer *_repeatTimer; // arrow key repeat (NewTerm 2.4: hold to repeat)
    ghostty_input_key_e _repeatKey; // the arrow key being repeated
    UIImpactFeedbackGenerator *_keyHaptic;  // light tap on key presses
    UIImpactFeedbackGenerator *_bellHaptic; // medium tap when the guest rings BEL
    UIButton *_copyButton; // secondary-row Copy, kept so onCopyAll can show "Copied"
    UILabel *_guestStatusLabel; // "Guest stopped/failed" notice over the terminal
    NSUInteger _copyFeedbackGeneration; // Copy taps, so a later tap's "Copied" is not cut short by an earlier tap's timer
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = TXThemeBackgroundColor();
    _keyHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [_keyHaptic prepare];
    _bellHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [_bellHaptic prepare];

    _engine = [KernEngine shared];

    // The terminal itself: a Ghostty surface. Ghostty renders with
    // Metal into this view, so there is no text view, no flush timer
    // and no VT grid here any more — the old vt.c rendering is gone.
    // It starts at the top of the screen: there is no bar above it
    // any more.
    _output = [[TXGhosttyView alloc] init];
    _output.translatesAutoresizingMaskIntoConstraints = NO;
    // VoiceOver: the output is the terminal itself, not a text field.
    _output.accessibilityLabel = @"Terminal output";
    _output.accessibilityHint = @"Shows the terminal output. Tap to focus the keyboard.";
    // Bytes the terminal wants to send to the guest go to the
    // engine. The engine is a singleton, so capturing it (not self)
    // cannot make a retain cycle.
    KernEngine *engine = _engine;
    _output.onOutput = ^(NSData *data) {
        [engine sendConsoleInput:data];
    };
    __weak typeof(self) weakSelf = self;
    _output.onBell = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_bellHaptic impactOccurred];
        [strongSelf->_bellHaptic prepare];
    };
    [self.view addSubview:_output];

    // Replay the console output from before this screen existed, and
    // take over live delivery, in one atomic step: the engine sets
    // the delegate and returns the buffered output under the same
    // lock, so a chunk arriving in this window is fed exactly once.
    // The old order (set the delegate, then read the snapshot) fed
    // such a chunk twice — once live, once in the snapshot.
    NSData *backlog = [_engine beginConsoleDeliveryWithDelegate:self];
    // Replay the console output from before this screen existed: the
    // engine's delegate is nil until here, so the boot log and the
    // login prompt printed during boot would otherwise never reach
    // the view and the terminal would start black. Ghostty takes the
    // whole buffer in one feed; output fed before the surface is
    // sized is buffered by the view and flushed on first layout.
    // Replay, not live: the boot log holds DSR/DA queries the guest
    // sent while booting, and answering them live sends a second set
    // of CPR/DA replies that land in the shell as typed input.
    if (backlog.length) {
        [_output feedGuestOutputReplay:backlog];
    }

    // Hidden field that owns the software keyboard.
    _input = [[TXTerminalInputField alloc] init];
    _input.onDeleteBackward = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf sendBackspace];
    };
    _input.delegate = self;
    _input.autocorrectionType = UITextAutocorrectionTypeNo;
    _input.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _input.returnKeyType = UIReturnKeyDefault;
    [self.view addSubview:_input];

    // The keyboard toolbar, NewTerm's model: a solid black bar with
    // the key rows, riding above the software keyboard. Pure black,
    // not a blur: the bar is continuous with the terminal above it,
    // so the whole screen reads as one black surface, and a blur
    // would smear the terminal text scrolling behind it. It is a
    // container, not an element: VoiceOver reads the key buttons
    // inside it, not the bar.
    UIView *toolbar = [[UIView alloc] init];
    toolbar.backgroundColor = TXThemeBackgroundColor();
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.isAccessibilityElement = NO;
    [self.view addSubview:toolbar];

    UIStackView *rows = [[UIStackView alloc] init];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 6;
    [toolbar addSubview:rows];

    // Fn row (hidden until Fn is toggled): F1-F12, horizontally scrolling.
    _fnRow = [[UIScrollView alloc] init];
    _fnRow.translatesAutoresizingMaskIntoConstraints = NO;
    _fnRow.showsHorizontalScrollIndicator = NO;
    UIStackView *fnStack = [[UIStackView alloc] init];
    fnStack.translatesAutoresizingMaskIntoConstraints = NO;
    fnStack.axis = UILayoutConstraintAxisHorizontal;
    fnStack.spacing = 6;
    fnStack.distribution = UIStackViewDistributionFillEqually;
    [_fnRow addSubview:fnStack];
    for (int i = 0; i < 12; i++) {
        NSString *title = [NSString stringWithFormat:@"f%d", i + 1];
        UIButton *b = [self keyButton:title];
        NSData *data = [NSData dataWithBytes:kFnBytes[i] length:kFnLens[i]];
        [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            (void)action;
            // Weak capture: the button retains the action, the action
            // retains this block, and a strong self here would retain
            // the VC — a cycle dealloc never breaks. Same pattern as
            // the arrow-repeat timer.
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf sendTextData:data];
        }] forControlEvents:UIControlEventTouchUpInside];
        [fnStack addArrangedSubview:b];
    }
    // Pin to the content layout guide, not the frame: the twelve
    // F-keys are wider than the screen (~462 pt), so pinning to the
    // frame forced the stack to the scroll view's width and squeezed
    // every key. Pinned to the content guide the stack sizes to its
    // buttons and the row scrolls horizontally, which is what the
    // scroll view is for.
    [NSLayoutConstraint activateConstraints:@[
        [fnStack.leadingAnchor constraintEqualToAnchor:_fnRow.contentLayoutGuide.leadingAnchor constant:6],
        [fnStack.trailingAnchor constraintEqualToAnchor:_fnRow.contentLayoutGuide.trailingAnchor constant:-6],
        [fnStack.topAnchor constraintEqualToAnchor:_fnRow.contentLayoutGuide.topAnchor],
        [fnStack.bottomAnchor constraintEqualToAnchor:_fnRow.contentLayoutGuide.bottomAnchor],
        [fnStack.heightAnchor constraintEqualToConstant:TXConfigKeyRowHeightPt],
    ]];
    _fnRow.hidden = YES;
    [rows addArrangedSubview:_fnRow];

    // Secondary row (hidden until More is toggled): Home End PgUp PgDn Del Copy Fn.
    // Same layout as the primary row: equal widths at 3 pt spacing,
    // so its keys line up with the primary row's. The spacer views
    // are gone: under FillEqually they would take an equal share
    // each and shrink the keys.
    _secondaryRow = [[UIStackView alloc] init];
    _secondaryRow.translatesAutoresizingMaskIntoConstraints = NO;
    _secondaryRow.axis = UILayoutConstraintAxisHorizontal;
    _secondaryRow.spacing = 6;
    _secondaryRow.distribution = UIStackViewDistributionFillEqually;
    [self addKey:_secondaryRow title:@"home" bytes:"\x1B[H" length:3];
    [self addKey:_secondaryRow title:@"end" bytes:"\x1B[F" length:3];
    [self addKey:_secondaryRow title:@"pgup" bytes:"\x1B[5~" length:4];
    [self addKey:_secondaryRow title:@"pgdn" bytes:"\x1B[6~" length:4];
    [self addKey:_secondaryRow title:@"del" bytes:"\x1B[3~" length:4];
    // Copy: the visible screen to the clipboard, so copying does not
    // depend only on a long-press menu. (The old whole-transcript
    // copy needs the scrollback, which Ghostty does not expose yet;
    // see onCopyAll.)
    _copyButton = [self keyButton:@"copy"];
    // Not "Sends this key to the terminal": Copy sends nothing, it
    // copies the visible screen to the clipboard.
    _copyButton.accessibilityHint = @"Copies the visible screen.";
    [_copyButton addTarget:self action:@selector(onCopyAll) forControlEvents:UIControlEventTouchUpInside];
    [_secondaryRow addArrangedSubview:_copyButton];
    _fnButton = [self keyButton:@"fn"];
    [_fnButton addTarget:self action:@selector(onFn) forControlEvents:UIControlEventTouchUpInside];
    _fnButton.accessibilityHint = @"Shows or hides the function key row.";
    [_secondaryRow addArrangedSubview:_fnButton];
    _secondaryRow.hidden = YES;
    [rows addArrangedSubview:_secondaryRow];

    // Primary row: Ctrl Alt Esc Tab More Paste ... four arrows ...
    // hide-keyboard. All eleven keys are the same width: the row
    // distributes equally, so the arrows are as wide as the text
    // keys instead of squeezed into the leftover space, and the icon
    // keys (paste, hide-keyboard) are as wide as the rest instead of
    // narrow. On a 430 pt screen each key is ~33 pt at 6 pt spacing —
    // the four-letter labels shrink slightly to fit (see keyButton).
    // Paste is a clipboard icon, not the word: the word took the
    // most width in the row, and the icon reads just as clearly.
    UIStackView *primary = [[UIStackView alloc] init];
    primary.translatesAutoresizingMaskIntoConstraints = NO;
    primary.axis = UILayoutConstraintAxisHorizontal;
    primary.spacing = 6;
    primary.distribution = UIStackViewDistributionFillEqually;
    _ctrlButton = [self keyButton:@"ctrl"];
    [_ctrlButton addTarget:self action:@selector(onCtrl) forControlEvents:UIControlEventTouchUpInside];
    _ctrlButton.accessibilityHint = @"Toggles the Control modifier for the next key.";
    [primary addArrangedSubview:_ctrlButton];
    _altButton = [self keyButton:@"alt"];
    [_altButton addTarget:self action:@selector(onAlt) forControlEvents:UIControlEventTouchUpInside];
    _altButton.accessibilityHint = @"Toggles the Alt modifier for the next key. Alt plus a key sends Escape followed by that key.";
    [primary addArrangedSubview:_altButton];
    [self addGhosttyKey:primary title:@"esc" key:GHOSTTY_KEY_ESCAPE];
    [self addGhosttyKey:primary title:@"tab" key:GHOSTTY_KEY_TAB];
    _moreButton = [self keyButton:@"more"];
    [_moreButton addTarget:self action:@selector(onMore) forControlEvents:UIControlEventTouchUpInside];
    _moreButton.accessibilityHint = @"Shows or hides the second key row.";
    [primary addArrangedSubview:_moreButton];
    // Paste as a clipboard icon: keyButton:@"paste" gives it the
    // "Paste" VoiceOver label, then the title is swapped for the
    // SF Symbol so it takes one key's width like everything else.
    // Same action, same chunked paste, same haptics as before.
    // Paste is the Font Awesome solid clipboard icon, at the
    // user's direction — not the SF Symbol doc.on.clipboard, which
    // is a document with a badge. The icon is a bundled PNG
    // (FAClipboard, rendered from the Font Awesome Free 6.7.2
    // clipboard SVG, CC BY 4.0), white on transparent, so it
    // renders as a template in the button's white tint. The
    // icon's holes (the clip ring and the text line) are
    // transparent, so the key's grey shows through them, the way
    // the Font Awesome icon is drawn.
    UIButton *pasteButton = [self keyButton:@"paste"];
    [pasteButton setTitle:nil forState:UIControlStateNormal];
    UIImage *pasteImage = [[UIImage imageNamed:@"FAClipboard"]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [pasteButton setImage:pasteImage forState:UIControlStateNormal];
    pasteButton.tintColor = [UIColor whiteColor];
    pasteButton.accessibilityHint = @"Pastes the clipboard into the terminal.";
    [pasteButton addTarget:self action:@selector(onPaste) forControlEvents:UIControlEventTouchUpInside];
    [primary addArrangedSubview:pasteButton];
    // Arrows: four separate full-height buttons, left right up down,
    // each with its own touch target and its own equal share of the
    // row — they used to share one nested stack squeezed into the
    // leftover width, which made them the smallest keys in the row.
    // All four repeat while held. The tag is the direction (0 left,
    // 1 up, 2 down, 3 right), not the position, so the order here
    // is visual only: left/right next to each other, then up/down.
    [self addArrowKey:primary title:@"←" tag:0];
    [self addArrowKey:primary title:@"→" tag:3];
    [self addArrowKey:primary title:@"↑" tag:1];
    [self addArrowKey:primary title:@"↓" tag:2];
    UIButton *kbd = [self keyButton:@"⌨"];
    kbd.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    kbd.accessibilityHint = @"Hides the keyboard. Tap the terminal to show it again.";
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
        [rows.topAnchor constraintEqualToAnchor:toolbar.topAnchor constant:8],
        [rows.bottomAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:-4],
        [_fnRow.heightAnchor constraintEqualToConstant:TXConfigKeyRowHeightPt],
        [_secondaryRow.heightAnchor constraintEqualToConstant:TXConfigKeyRowHeightPt],
        [primary.heightAnchor constraintEqualToConstant:TXConfigKeyRowHeightPt],
    ]];
    // The toolbar rides above the software keyboard when it appears.
    _toolbarBottom = [toolbar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4];
    _toolbarBottom.active = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
    // Tap the terminal to focus the keyboard. (Tap-a-URL is gone
    // with the text view: Ghostty does not expose the text under a
    // tap yet; see the follow-ups.)
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onTapTerminal:)];
    [_output addGestureRecognizer:tap];

    // The way back to the startup screen: a downward drag that
    // starts in the top strip of the terminal. A scroll through the
    // scrollback starts anywhere and goes either way; this one only
    // fires for a drag that begins at the very top and moves
    // decisively down, so ordinary scrolling never triggers it.
    // (There is no scrollback scrolling yet — Ghostty owns the
    // scrollback and no scroll gesture is wired — so the drag only
    // needs the top strip and the distance, not a scroll offset.)
    UIPanGestureRecognizer *exitPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onExitPan:)];
    exitPan.delegate = self;
    // One finger only: without this the recognizer can see a
    // two-finger pinch as well (it recognises simultaneously with
    // the terminal's gestures), so a pinch starting in the top
    // strip and travelling down could dismiss the terminal.
    exitPan.maximumNumberOfTouches = 1;
    [_output addGestureRecognizer:exitPan];

    // Guest-dead notice: if the guest fails or stops while the
    // terminal is open, the screen would otherwise just go dead
    // with no explanation. A small label at the top says what
    // happened and how to get back (see termXEngineDidChangeState:);
    // it never dismisses the terminal and sends nothing to the
    // guest. Taps pass through it to the terminal below. Hidden
    // while the guest runs.
    _guestStatusLabel = [[TXPaddedLabel alloc] init];
    _guestStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _guestStatusLabel.backgroundColor = TXThemePillBackground();
    _guestStatusLabel.textColor = TXThemeForegroundColor();
    _guestStatusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _guestStatusLabel.textAlignment = NSTextAlignmentCenter;
    _guestStatusLabel.numberOfLines = 3;
    _guestStatusLabel.layer.cornerRadius = TXThemeCornerRadiusPill;
    _guestStatusLabel.clipsToBounds = YES;
    _guestStatusLabel.userInteractionEnabled = NO;
    _guestStatusLabel.hidden = YES;
    [self.view addSubview:_guestStatusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_guestStatusLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [_guestStatusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_guestStatusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];

    [self termXEngineDidChangeState:_engine.state status:_engine.statusText];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_output setFocused:YES];
    // Clear on boot, once: if the startup screen asked for it, wipe
    // the boot log from the display and ask the guest for a fresh
    // prompt, so the user opens on a clean prompt instead of the
    // systemd boot log. Only once per terminal instance, and only
    // when clearScreenOnBoot is YES — returning to the terminal
    // later never wipes scrollback. The log itself is not lost: it
    // stays in guest.log and engine.log.
    if (self.clearScreenOnBoot && !_didClearScreenOnBoot) {
        _didClearScreenOnBoot = YES;
        // No command is typed into the terminal at boot: auto-running
        // commands after boot is not wanted, so the width is not
        // injected here. It is still covered by the image itself
        // (the shell startup sets stty cols 48 + COLUMNS=48 at
        // login).
        //
        // The clear and the fresh prompt run async on the main queue,
        // not synchronously here. Console output arrives on the
        // runtime thread and is fed to Ghostty via dispatch_async to
        // the main queue, so a prompt that was already queued lands
        // AFTER a synchronous clear — the clear wipes the replayed
        // prompt, the queued prompt reappears, and the newline below
        // prints a second one, which is the double prompt the user
        // saw. Queuing the clear after the pending output means the
        // clear wipes everything.
        //
        // Whether the newline is sent is decided from what the guest
        // has already printed, not from a timer. A quiet period
        // cannot tell a finished login from a slow one: bash can sit
        // silent for longer than 300 ms while it starts, so the
        // gated check fired the newline and the late prompt arrived
        // after it — two prompts, every cold boot. Instead, the
        // console buffer is checked at the clear: if it holds the
        // shell prompt (termx@iphone:), the guest is already at its
        // shell and idle, so one newline elicits exactly one fresh
        // prompt and no other prompt is coming. If it does not, the
        // guest is still logging in, so no newline is sent and its
        // prompt arrives live and prints once. Either way, one
        // prompt. A bare newline is not a command, it only requests
        // the prompt, and the byte must be exactly LF.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            // Home + erase: ESC[2J alone erases but leaves the
            // cursor where the replay left it — on the bottom row
            // after a full boot log — so the fresh prompt lands on
            // the bottom row, with the whole screen empty above it.
            // ESC[H first puts the cursor at the top-left, so the
            // prompt opens at the top, the way Termux opens.
            static const uint8_t clearSeq[] = { 0x1B, '[', 'H', 0x1B, '[', '2', 'J' };
            [strongSelf->_output feedGuestOutput:[NSData dataWithBytes:clearSeq length:sizeof(clearSeq)]];
            // The shell prompt is only ever printed by the shell
            // itself, never by the boot log, so "@iphone:" in the
            // buffer means the guest reached the shell and is idle
            // at the prompt.
            NSData *buffer = [strongSelf->_engine bufferedConsoleOutput];
            NSData *marker = [NSData dataWithBytes:"@iphone:" length:8];
            BOOL hasPrompt = buffer.length >= marker.length &&
                [buffer rangeOfData:marker options:0
                              range:NSMakeRange(0, buffer.length)].location != NSNotFound;
            if (hasPrompt) {
                uint8_t nl = '\n';
                [strongSelf->_engine sendConsoleInput:[NSData dataWithBytes:&nl length:1]];
            }
        });
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_output setFocused:NO];
}

// The one key background colour, for every state a key can be in.
// A toggle's ON colour lives on the button's `selected` property, so
// the pressed-state handlers and setToggle below can both ask this
// one function instead of each remembering the colours — the old
// code had setToggle restore white 0.16 while keyButton used 0.30,
// so a toggled-off key came back visibly darker than its siblings.
static UIColor *TXKeyBackground(BOOL on, BOOL pressed) {
    if (pressed) {
        // Pressed ON is a lighter teal, so the press still reads on
        // a latched toggle; pressed OFF is the same light grey as before.
        return on ? [UIColor colorWithRed:0.35 green:0.80 blue:0.72 alpha:1.0]
                  : [UIColor colorWithWhite:0.35 alpha:1.0];
    }
    // ON is the app accent teal (#2AB3A3, TXThemeAccentColor), not
    // blue: a blue toggle on a teal-accent app reads as a different
    // app's colour.
    return on ? TXThemeAccentColor()
              : TXThemeKeyBackground();
}

// VoiceOver label for a key title: the glyphs and abbreviations
// ("←", "⌨", "ctrl", "pgup") read as nothing useful on their own.
static NSString *TXKeyAccessibilityLabel(NSString *title) {
    if ([title isEqualToString:@"←"]) return @"Left arrow";
    if ([title isEqualToString:@"→"]) return @"Right arrow";
    if ([title isEqualToString:@"↑"]) return @"Up arrow";
    if ([title isEqualToString:@"↓"]) return @"Down arrow";
    if ([title isEqualToString:@"⌨"]) return @"Hide keyboard";
    if ([title isEqualToString:@"ctrl"]) return @"Control";
    if ([title isEqualToString:@"alt"]) return @"Alt";
    if ([title isEqualToString:@"esc"]) return @"Escape";
    if ([title isEqualToString:@"tab"]) return @"Tab";
    if ([title isEqualToString:@"more"]) return @"More keys";
    if ([title isEqualToString:@"paste"]) return @"Paste";
    if ([title isEqualToString:@"copy"]) return @"Copy all";
    if ([title isEqualToString:@"fn"]) return @"Function keys";
    if ([title isEqualToString:@"home"]) return @"Home";
    if ([title isEqualToString:@"end"]) return @"End";
    if ([title isEqualToString:@"pgup"]) return @"Page up";
    if ([title isEqualToString:@"pgdn"]) return @"Page down";
    if ([title isEqualToString:@"del"]) return @"Delete";
    if (title.length == 2 && [title hasPrefix:@"f"]) return [title uppercaseString]; // f1..f12
    return title;
}

- (UIButton *)keyButton:(NSString *)title {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    // The key design from the user's mockup: a dark grey key with
    // white sans-serif text and a thin light border, not the old
    // flat mid-grey key with monospaced text. The border is what
    // makes the key read as a key against the black toolbar — a
    // flat fill with no edge blends into the black. The fill is
    // white 0.22, darker than the old 0.30, and the corner radius
    // is 9 pt, rounder than the old 6 pt, so the keys match the
    // mockup's pill-like roundness. The small shadow below the key
    // gives the same depth the mockup's keys have.
    b.backgroundColor = TXKeyBackground(NO, NO);
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateSelected];
    b.layer.cornerRadius = TXThemeCornerRadiusKey;
    b.layer.borderWidth = 1;
    b.layer.borderColor = TXThemeKeyBorderColor().CGColor;
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOffset = CGSizeMake(0, 1);
    b.layer.shadowRadius = 1;
    b.layer.shadowOpacity = 0.35;
    // Slim horizontal insets: the primary row holds eleven equal
    // keys at 6 pt spacing, and wider insets would overflow a 430 pt
    // screen. The titles shrink to fit instead of clipping: with
    // equal widths the widest four-letter label ("more", ~36 pt at
    // 16 pt sans-serif) is wider than its key, so the title scales
    // down rather than truncating. 1 pt insets and a 0.5 floor keep
    // it fitting even on a 320 pt screen: each key is ~22.9 pt,
    // leaving ~20.9 pt for the label, and 36 pt at 0.5 scale is
    // 18 pt. The three-letter keys stay at full size.
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 1, 6, 1);
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.5;
    // Pressed state: the key lightens while the finger is down, on
    // top of the default title dim. TouchDown fires before the
    // key's own action, TouchUp restores the colour before the
    // action's toggle (if any) sets the new one — the order is the
    // order the targets were added, and keyButton's targets are
    // added first, at creation.
    [b addTarget:self action:@selector(keyButtonPressed:) forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:@selector(keyButtonReleased:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    // VoiceOver: a glyph or abbreviation alone reads as nothing.
    b.accessibilityLabel = TXKeyAccessibilityLabel(title);
    b.accessibilityHint = @"Sends this key to the terminal.";
    b.accessibilityTraits = UIAccessibilityTraitButton;
    return b;
}

// A press lightens the key; releasing restores the colour for its
// toggle state (selected = a latched Ctrl/Alt or an open More/Fn row).
- (void)keyButtonPressed:(UIButton *)button {
    button.backgroundColor = TXKeyBackground(button.selected, YES);
}

- (void)keyButtonReleased:(UIButton *)button {
    button.backgroundColor = TXKeyBackground(button.selected, NO);
}

// A light tap for a key press. The generator is prepared again
// after each impact, so the next press is ready.
- (void)keyHaptic {
    [_keyHaptic impactOccurred];
    [_keyHaptic prepare];
}

// The latched modifiers as a Ghostty modifier mask, for the key
// calls below. A latched Ctrl or Alt applies to the next key press
// and releases — the release paths in sendGhosttyKey/sendTextData/
// sendBackspace and the typing delegate use releaseCtrl/releaseAlt
// below, not the button actions.
- (ghostty_input_mods_e)latchedMods {
    ghostty_input_mods_e mods = GHOSTTY_MODS_NONE;
    if (_ctrlLatched) mods |= GHOSTTY_MODS_CTRL;
    if (_altLatched) mods |= GHOSTTY_MODS_ALT;
    return mods;
}

// A special key (arrows, Esc, Tab, Backspace, Enter) through
// Ghostty, with the latched modifiers as Ghostty mods, then the
// latches release. Ghostty produces the right sequence for the
// key + modifiers (Ctrl+Up is CSI 1;5A, Alt+Up is ESC + Up), so
// the sequences are correct for the modifiers instead of the old
// plain sequence with the latch silently dropped. The feedback
// (click + haptic) is only for a real press: the arrow repeat timer
// sends with feedback NO, or holding an arrow would buzz the haptic
// at 12 Hz.
- (void)sendGhosttyKey:(ghostty_input_key_e)key {
    [self sendGhosttyKey:key withFeedback:YES];
}

- (void)sendGhosttyKey:(ghostty_input_key_e)key withFeedback:(BOOL)feedback {
    if (feedback) {
        [[UIDevice currentDevice] playInputClick];
        [self keyHaptic];
    }
    [_output sendKey:key mods:[self latchedMods]];
    [self releaseAlt];
    [self releaseCtrl];
}

// A key button's bytes as text through Ghostty (Home, End, PgUp,
// PgDn, Del, F1-F12): the legacy byte sequences are preserved
// exactly, and Ghostty forwards them to the guest. Alt prefixes
// ESC to the next input (the standard terminal Alt behaviour), and
// a latched Ctrl releases here, or it would leak into the next
// typed letter and turn it into a control byte the user never
// asked for. (Typing a letter goes through the text-field delegate,
// not here, so the Ctrl+letter path is untouched.)
- (void)sendTextData:(NSData *)data {
    [self sendTextData:data withFeedback:YES];
}

- (void)sendTextData:(NSData *)data withFeedback:(BOOL)feedback {
    if (feedback) {
        [[UIDevice currentDevice] playInputClick];
        [self keyHaptic];
    }
    if (_altLatched) {
        [_output sendText:@"\x1B"];
        [self releaseAlt];
    }
    [self releaseCtrl];
    if (!data.length) return;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length) [_output sendText:text];
}

// Backspace: the Backspace key through Ghostty, with a latched Alt
// as the Alt modifier (readline deletes the previous word). A
// latched Ctrl releases here, or it would stay latched and turn
// the next typed letter into a control byte.
- (void)sendBackspace {
    [_output sendKey:GHOSTTY_KEY_BACKSPACE mods:[self latchedMods]];
    [self releaseAlt];
    [self releaseCtrl];
}

// A key button that sends its bytes as text (Home, End, PgUp,
// PgDn, Del). Esc and Tab are not here: they go through
// addGhosttyKey, so Ghostty produces their sequences.
- (void)addKey:(UIStackView *)row title:(NSString *)title bytes:(const char *)bytes length:(size_t)length {
    UIButton *b = [self keyButton:title];
    NSData *data = [NSData dataWithBytes:bytes length:length];
    // Weak capture: the button retains the action, the action retains
    // this block, and a strong self here would retain the VC — a cycle
    // dealloc never breaks. Same pattern as the arrow-repeat timer.
    __weak typeof(self) weakSelf = self;
    [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf sendTextData:data];
    }] forControlEvents:UIControlEventTouchUpInside];
    [row addArrangedSubview:b];
}

// A key button that sends a Ghostty key (Esc, Tab).
- (void)addGhosttyKey:(UIStackView *)row title:(NSString *)title key:(ghostty_input_key_e)key {
    UIButton *b = [self keyButton:title];
    __weak typeof(self) weakSelf = self;
    [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf sendGhosttyKey:key];
    }] forControlEvents:UIControlEventTouchUpInside];
    [row addArrangedSubview:b];
}

// Arrow keys by tag: 0 left, 1 up, 2 down, 3 right.
- (ghostty_input_key_e)arrowKeyForTag:(NSInteger)tag {
    switch (tag) {
        case 0: return GHOSTTY_KEY_ARROW_LEFT;
        case 1: return GHOSTTY_KEY_ARROW_UP;
        case 2: return GHOSTTY_KEY_ARROW_DOWN;
        case 3: return GHOSTTY_KEY_ARROW_RIGHT;
        default: return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

// An arrow key: a full-height keyButton like every other key, with
// its own touch target and hold-to-repeat. A single glyph needs less
// side padding than a word, so the arrows take 5 pt insets, and the
// glyph is 18 pt so it fills the taller 42 pt key the way the
// keyboard's own symbols do. They sit directly in the primary row
// now, one equal share each — the nested stack that used to squeeze
// them into the leftover width is gone.
- (void)addArrowKey:(UIStackView *)row title:(NSString *)title tag:(NSInteger)tag {
    UIButton *b = [self keyButton:title];
    b.tag = tag;
    b.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 5, 6, 5);
    [b addTarget:self action:@selector(arrowTouchDown:) forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:@selector(arrowTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [row addArrangedSubview:b];
}

// Arrow key repeat (NewTerm 2.4): a tap sends once, holding repeats
// after 0.4 s at 12 Hz, so scrolling through shell history does not
// need a tap per line.
- (void)arrowTouchDown:(UIButton *)sender {
    [self startKeyRepeat:[self arrowKeyForTag:sender.tag]];
}

- (void)arrowTouchUp:(UIButton *)sender {
    (void)sender;
    [self stopKeyRepeat];
}

- (void)startKeyRepeat:(ghostty_input_key_e)key {
    [self stopKeyRepeat];
    _repeatKey = key;
    [self sendGhosttyKey:key];
    __weak typeof(self) weakSelf = self;
    _repeatTimer = [NSTimer scheduledTimerWithTimeInterval:TXConfigArrowRepeatIntervalSec repeats:YES block:^(NSTimer *t) {
        (void)t;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { [t invalidate]; return; }
        // No feedback on repeats: a press clicks and taps once, and
        // the hold repeats silently (see sendGhosttyKey:withFeedback:).
        [strongSelf sendGhosttyKey:strongSelf->_repeatKey withFeedback:NO];
    }];
    // The timer must fire while the button is held: a hold puts the
    // run loop in tracking mode, and a timer in the default mode
    // never fires there, so hold-to-repeat silently sent once.
    [[NSRunLoop mainRunLoop] addTimer:_repeatTimer forMode:NSRunLoopCommonModes];
    [_repeatTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:TXConfigArrowRepeatInitialDelaySec]];
}

- (void)stopKeyRepeat {
    [_repeatTimer invalidate];
    _repeatTimer = nil;
}

- (void)setToggle:(UIButton *)button on:(BOOL)on {
    // The toggle state lives on `selected`, so the pressed-state
    // handlers can restore the right colour without knowing which
    // toggle this is. VoiceOver reads the value as On/Off.
    button.selected = on;
    button.backgroundColor = TXKeyBackground(on, NO);
    button.accessibilityValue = on ? @"On" : @"Off";
}

#pragma mark - Actions

// The toggles: tap to latch, tap again (or use it) to release. The
// release paths in sendGhosttyKey/sendTextData/sendBackspace/onPaste
// and the typing delegate use releaseCtrl/releaseAlt below, not
// these — these are the button actions, and they also give the haptic.
- (void)onCtrl {
    _ctrlLatched = !_ctrlLatched;
    [self setToggle:_ctrlButton on:_ctrlLatched];
    [self keyHaptic];
}

- (void)releaseCtrl {
    if (!_ctrlLatched) return;
    _ctrlLatched = NO;
    [self setToggle:_ctrlButton on:NO];
}

- (void)onAlt {
    _altLatched = !_altLatched;
    [self setToggle:_altButton on:_altLatched];
    [self keyHaptic];
}

- (void)releaseAlt {
    if (!_altLatched) return;
    _altLatched = NO;
    [self setToggle:_altButton on:NO];
}

- (void)onMore {
    _secondaryRow.hidden = !_secondaryRow.hidden;
    [self setToggle:_moreButton on:!_secondaryRow.hidden];
    [self keyHaptic];
    if (_secondaryRow.hidden && !_fnRow.hidden) {
        _fnRow.hidden = YES;
        [self setToggle:_fnButton on:NO];
    }
}

- (void)onFn {
    _fnRow.hidden = !_fnRow.hidden;
    [self setToggle:_fnButton on:!_fnRow.hidden];
    [self keyHaptic];
}

// Paste: the clipboard text goes to the guest exactly as if typed,
// newlines included. An empty clipboard is a no-op (nil.length is 0).
// Ghostty's paste wraps the text in bracketed paste when the
// terminal has that mode on, so a paste into a shell does not run
// until the user confirms, and a paste into a TUI is one operation.
// The guest tty input buffer is 4096 bytes, so a paste larger than
// that loses its tail if it goes in one write: split it into 512
// character chunks, one per run-loop turn, so the line discipline
// drains between writes. The chunk boundary never splits a UTF-16
// surrogate pair. The Ctrl latch releases once, on the first chunk,
// the way sendGhosttyKey does for a key button — not once per chunk.
- (void)onPaste {
    NSString *text = [UIPasteboard generalPasteboard].string;
    if (text.length == 0) return;
    // A paste is not a key: a latched modifier releases once, on
    // the first chunk, the way sendGhosttyKey does for a key button —
    // not once per chunk.
    [self releaseCtrl];
    [self releaseAlt];
    [[UIDevice currentDevice] playInputClick];
    [self keyHaptic];
    [self sendPasteChunk:text offset:0];
}

// Copy: the visible screen to the clipboard. Ghostty does not
// expose the scrollback through this API yet, so the old whole-
// transcript copy is not possible here; the visible screen is what
// Copy can reach today. (Full-transcript copy is a follow-up.)
- (void)onCopyAll {
    NSString *transcript = [_output visibleScreenText] ?: @"";
    // Ghostty's screen text ends in a run of newlines for the blank
    // rows at the bottom. Trim the trailing newlines here, in the
    // transcript only.
    while ([transcript hasSuffix:@"\n"]) {
        transcript = [transcript substringToIndex:transcript.length - 1];
    }
    [UIPasteboard generalPasteboard].string = transcript;
    [[UIDevice currentDevice] playInputClick];
    [self keyHaptic];
    // Brief confirmation, the Log screen's pattern (TXLogViewController
    // copyTapped): the button reads "Copied" for 1.5 s, then goes
    // back to "copy". The button itself is the feedback — a toast
    // would need a new view for one word.
    [_copyButton setTitle:@"Copied" forState:UIControlStateNormal];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Copied");
    // Generation token: a second tap must not have its "Copied"
    // cut short by the first tap's timer. Only the latest tap's
    // timer restores the title, so it runs its full 1.5 s.
    NSUInteger generation = ++_copyFeedbackGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf->_copyFeedbackGeneration) return;
        [strongSelf->_copyButton setTitle:@"copy" forState:UIControlStateNormal];
    });
}

// One chunk of a paste, then the next chunk on the next run-loop
// turn (dispatch_async on the main queue). Sending the whole paste
// in one write overflows the guest tty's 4096-byte input buffer.
- (void)sendPasteChunk:(NSString *)text offset:(NSUInteger)offset {
    if (offset >= text.length) return;
    NSUInteger len = MIN(512, text.length - offset);
    if (offset + len < text.length) {
        // Do not split a UTF-16 surrogate pair across chunks.
        unichar last = [text characterAtIndex:offset + len - 1];
        if (last >= 0xD800 && last <= 0xDBFF) len -= 1;
    }
    [_output pasteText:[text substringWithRange:NSMakeRange(offset, len)]];
    if (offset + len < text.length) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) [strongSelf sendPasteChunk:text offset:offset + len];
        });
    }
}

- (void)onKeyboard {
    // Dismiss only, never toggle back on: endEditing resigns
    // whichever field actually owns the keyboard (the hidden _input).
    // Tapping the terminal brings the keyboard back.
    [self.view endEditing:YES];
}

// Tap the terminal to focus the keyboard.
- (void)onTapTerminal:(UITapGestureRecognizer *)tap {
    (void)tap;
    [_input becomeFirstResponder];
}

// The exit drag: a downward pan that begins in the top strip of the
// terminal returns to the startup screen, where Stop, Logs, Install
// and Boot live. While the guest-dead notice is visible the top
// requirement is relaxed: the user is almost always pinned at the
// bottom when the guest dies, and the notice tells them to swipe
// down to return, so the drag must work from any scroll position
// then. (With no scrollback scrolling wired yet, there is no scroll
// offset to check; the top strip and the distance are the gate.)
- (void)onExitPan:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _exitPanStart = [pan locationInView:_output];
            break;
        case UIGestureRecognizerStateEnded: {
            CGPoint translation = [pan translationInView:_output];
            BOOL guestDead = _guestStatusLabel && !_guestStatusLabel.hidden;
            if ((_exitPanStart.y < TXConfigExitPanTopStripPt || guestDead) && translation.y > TXConfigExitPanTranslationThresholdPt &&
                fabs(translation.y) > fabs(translation.x)) {
                [self dismissViewControllerAnimated:YES completion:nil];
            }
            break;
        }
        default:
            break;
    }
}

// Let the exit pan watch touches alongside the terminal's own
// gestures, so a drag can be both a scroll and a candidate exit.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer; (void)otherGestureRecognizer;
    return YES;
}

#pragma mark - Engine delegate

- (void)termXEngineDidChangeState:(TermXState)state status:(NSString *)status {
    // The only thing the terminal itself does with state: focus the
    // keyboard once the shell is up, so the user can type at once.
    if (state == TermXStateRunning) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_guestStatusLabel.hidden = YES;
            [self->_input becomeFirstResponder];
        });
        return;
    }
    // Failed or Stopped while the terminal is open: without this the
    // screen just goes dead and the user has no idea why. Show a
    // label over the terminal with what happened and how to get back — never auto-dismiss (the user may want the scrollback)
    // and never send anything to the guest. The engine's statusText
    // is appended when it is short enough to read; a long one stays
    // in engine.log. (State changes can arrive off the main thread,
    // hence the dispatch.)
    if (state == TermXStateFailed || state == TermXStateStopped) {
        NSString *headline = state == TermXStateFailed
            ? @"Guest failed — swipe down to return"
            : @"Guest stopped — swipe down to return";
        NSString *detail = (status.length > 0 && status.length <= 100)
            ? [NSString stringWithFormat:@"\n%@", status] : @"";
        NSString *text = [headline stringByAppendingString:detail];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_guestStatusLabel.text = text;
            self->_guestStatusLabel.hidden = NO;
        });
    }
}

- (void)kernEngineDidReceiveConsoleOutput:(NSData *)data {
    // The runtime calls this on its own thread; Ghostty is only ever
    // fed on the main thread, so keep the whole block there.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_output feedGuestOutput:data];
    });
}

#pragma mark - Typing

// The software keyboard's Return reaches the delegate here, not
// through shouldChangeCharactersInRange: (a UITextField never
// inserts a newline). Without this method Return does nothing and
// the command never runs. Send Ghostty's Enter and keep the
// keyboard up.
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    (void)textField;
    [_output sendKey:GHOSTTY_KEY_ENTER mods:[self latchedMods]];
    [self releaseAlt];
    [self releaseCtrl];
    return NO;
}

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
    // Work out the key first, then apply the latched modifiers. A
    // lone newline is the software keyboard's Return: it must travel
    // the key path (Ghostty's Enter), not the text path — a text-path
    // newline inside bracketed paste becomes a literal insertion
    // instead of accepting the line. Both latches release on use.
    if ([string isEqualToString:@"\n"]) {
        [_output sendKey:GHOSTTY_KEY_ENTER mods:[self latchedMods]];
        [self releaseAlt];
        [self releaseCtrl];
        return NO;
    }
    if (_ctrlLatched) {
        // Ctrl plus a letter: send the key with the Ctrl modifier,
        // so Ghostty produces the control byte (Ctrl+A is 0x01).
        // The characters [ \ ] map to their keys directly; ^ and _
        // need Shift on their keys, so they fall through to the byte
        // path below (0x1E / 0x1F are not newlines, so the text path
        // forwards them exactly).
        unichar c = [string characterAtIndex:0];
        ghostty_input_key_e key = GHOSTTY_KEY_UNIDENTIFIED;
        if (c >= 'a' && c <= 'z') key = (ghostty_input_key_e)(GHOSTTY_KEY_A + (c - 'a'));
        else if (c >= 'A' && c <= 'Z') key = (ghostty_input_key_e)(GHOSTTY_KEY_A + (c - 'A'));
        else if (c == '[') key = GHOSTTY_KEY_BRACKET_LEFT;
        else if (c == '\\') key = GHOSTTY_KEY_BACKSLASH;
        else if (c == ']') key = GHOSTTY_KEY_BRACKET_RIGHT;
        if (key != GHOSTTY_KEY_UNIDENTIFIED) {
            [_output sendKey:key mods:GHOSTTY_MODS_CTRL | (_altLatched ? GHOSTTY_MODS_ALT : 0)];
            [self releaseAlt];
            [self releaseCtrl];
            return NO;
        }
        // No key mapping (a digit, a space, ^, _): Alt prefixes ESC
        // first, then the control byte — or the character as-is when
        // it has no control byte.
        if (_altLatched) [_output sendText:@"\x1B"];
        uint8_t control = [self controlByteForCharacter:c];
        if (control) {
            NSString *byte = [[NSString alloc] initWithBytes:&control length:1 encoding:NSUTF8StringEncoding];
            if (byte) [_output sendText:byte];
        } else {
            [_output sendText:string];
        }
        [self releaseAlt];
        [self releaseCtrl];
        return NO;
    }
    // No Ctrl: typed text on the key path (sendTypedText:), not
    // the text path. The text path is a paste: Ghostty wraps it in
    // bracketed paste, so each letter lands as pasted text instead
    // of a keystroke. Alt rides as a modifier on the key event —
    // Ghostty's encoder emits ESC plus the character — instead of
    // a separate ESC sent as text.
    [_output sendTypedText:string
                      mods:(_altLatched ? GHOSTTY_MODS_ALT : GHOSTTY_MODS_NONE)];
    [self releaseAlt];
    return NO;
}

// The control byte for a character with Ctrl held: a-z and A-Z map
// to 1-26, [ \ ] ^ _ to ESC FS GS RS US. Anything else has no
// control byte (0), and the character sends as-is.
- (uint8_t)controlByteForCharacter:(unichar)c {
    if (c >= 'a' && c <= 'z') return (uint8_t)(c - 'a' + 1);
    if (c >= 'A' && c <= 'Z') return (uint8_t)(c - 'A' + 1);
    if (c == '[') return 0x1B;
    if (c == '\\') return 0x1C;
    if (c == ']') return 0x1D;
    if (c == '^') return 0x1E;
    if (c == '_') return 0x1F;
    return 0;
}

#pragma mark - Keyboard

- (void)keyboardWillChange:(NSNotification *)note {
    // The keyboard showing or hiding moves the toolbar; the
    // terminal view resizes with it and Ghostty re-lays out. The
    // view itself takes no bottom inset — it ends at the toolbar,
    // which already rides above the keyboard (see viewDidLoad).
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inView = [self.view convertRect:end fromView:nil];
    // The toolbar is anchored to the safe-area bottom, but the
    // keyboard frame runs to the screen bottom (it covers the home
    // indicator). Counting the full keyboard height against the safe
    // area leaves a ~34 pt gap between the toolbar and the keyboard.
    // Count only the part of the keyboard above the safe-area bottom.
    CGFloat safeBottom = self.view.bounds.size.height - self.view.safeAreaInsets.bottom;
    CGFloat height = MAX(0, safeBottom - inView.origin.y);
    _toolbarBottom.constant = -4 - height;
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    // The keyboard's own animation curve: without it the toolbar
    // moves on the default ease-in-out while the keyboard moves on
    // its curve, and the two visibly separate. The curve value maps
    // to animation options by shifting it into the options field.
    NSInteger curveValue = [note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    UIViewAnimationOptions options = (UIViewAnimationOptions)(curveValue << 16);
    [UIView animateWithDuration:duration delay:0 options:options animations:^{
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)dealloc {
    // Observable in engine.log: with the timer cycles fixed, this
    // line proves the VC is actually freed when the terminal is
    // dismissed. Its absence after a dismiss means a retain cycle
    // is still holding it.
    TXLogEngine(@"TerminalViewController dealloc");
    [_repeatTimer invalidate];
}

@end
