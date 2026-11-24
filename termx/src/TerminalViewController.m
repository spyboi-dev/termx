// TerminalViewController implementation. See the header.
//
// The terminal screen follows NewTerm 3's model (hbang/NewTerm, Apache-2.0):
// a scrolling line-based terminal, 80x25, xterm-256color, system monospace
// font, and the keyboard toolbar above the software keyboard: Ctrl
// (toggle), Alt (toggle), Esc, Tab, More (toggle), Paste, and four
// separate arrow keys on the primary row; Home, End, PgUp, PgDn, Del,
// Copy and Fn (toggle) on the secondary row; F1-F12 on a horizontally
// scrolling Fn row. Alt prefixes ESC to the next input, the standard
// terminal behaviour (Emacs, tmux, readline). The block cursor blinks
// while the terminal is focused. The VT emulation is our own vt.c
// (NewTerm uses SwiftTerm, which is Swift and cannot build here); the
// key bytes match NewTerm's TerminalConstants exactly. The shell itself
// lives in the guest, never on iOS: typed input goes to the guest
// console, guest output feeds the terminal view.
// Scrolling follows the rule every mobile terminal uses (NewTerm,
// Blink, Termius): output follows the bottom only while the user is
// pinned there; once they scroll up into the scrollback the view stays
// exactly where they put it, and scrolling back to the bottom re-pins
// it so output follows again.
// The engine buffers console output from boot and the terminal replays
// it on presentation, so the boot log and the login prompt are visible
// even though the terminal only exists 0.7 s after the shell is ready.
// There is no top bar and no control button on this screen at all: the
// startup screen is the control centre, and a swipe down from the top
// edge — only when already at the very top of the scrollback — returns
// to it.
//
// The look is the shared TXTheme: a pure black background with
// soft-white text, and one 14 pt monospace font used by the text view,
// the placeholder, and the flush renderer alike. xterm black as a
// foreground renders as a dim grey (pure black text is invisible on
// a black background); as a background it is pure black, so black
// cells blend in instead of reading as holes.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TerminalViewController.h"

#import "KernEngine.h"
#import "TXConfig.h"
#import "TXLog.h"
#import "TXTheme.h"
#import "vt.h"

@interface TerminalViewController () <KernEngineDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate>
@end

// xterm 256-colour palette: 0-15 the standard colours, 16-231 the 6x6x6
// cube (levels 0, 95, 135, 175, 215, 255), 232-255 the grey ramp.
// Colour 0 is pure black, the theme background: a cell with a black
// background must blend into the screen, not read as a hole.
// (Colour 0 as a foreground is handled in colorForCell, which renders
// it as a dim grey — pure black text is invisible on a black screen.)
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

// The one paragraph style for terminal text, built for the current
// font size: line spacing scales with the size (2 pt at the 14 pt
// default, ~1.4 pt at 10, ~3.4 pt at 24), so a pinch-zoomed terminal
// keeps the same proportions instead of the lines crowding together
// at large sizes or spreading apart at small ones. It is built once
// and shared by the scrollback attributes and every grid run — a
// spacing set in only one place would make the two halves of the
// screen sit on different baselines. Cached for the last size built:
// the flush calls this on every run, and rebuilding the style object
// each time would be wasteful.
static NSParagraphStyle *TXTermParagraphStyleForSize(CGFloat size) {
    static NSParagraphStyle *style = nil;
    static CGFloat styleSize = 0;
    if (!style || styleSize != size) {
        NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
        para.lineSpacing = size * TXConfigTermLineSpacingPt / TXConfigTermFontSizeDefault;
        // Clip, never wrap: the layout manager takes the paragraph
        // style's line-break mode over the text container's, and the
        // default is word-wrapping — so a container set to Clipping
        // still wrapped at the view width on device (fastfetch's
        // two-column lines interleaved). With Clipping here too, a
        // long line is one visual line that scrolls horizontally.
        para.lineBreakMode = NSLineBreakByClipping;
        style = [para copy];
        styleSize = size;
    }
    return style;
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

// The terminal text view. A non-editable but selectable UITextView
// shows the iOS edit menu on long-press, but as a non-editable view
// it offers no Paste — so a long-press on the terminal text gave no
// way to paste, unlike any other input box. This subclass adds Paste
// (Copy and Select All keep working through super, which already
// offers them for selectable text): the menu appears on a long-press
// over the visible terminal text, and Paste sends the clipboard to
// the guest exactly like the Paste button. The view controller
// supplies the handler, which also refocuses the hidden input field
// so the keyboard comes back — the long-press moves first-responder
// status to this view, which shows no keyboard.
@interface TXTerminalTextView : UITextView
@property (nonatomic, copy) void (^pasteHandler)(void);
// Scroll offset at the instant the finger landed, recorded in
// touchesBegan (before the finger moves). The exit-pan gesture only
// reaches Began after movement, so by then a drag that started
// slightly scrolled may already be at offset 0.
@property (nonatomic, assign) CGFloat touchDownContentOffsetY;
@end

@implementation TXTerminalTextView
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(paste:)) return YES;
    return [super canPerformAction:action withSender:sender];
}

- (void)paste:(id)sender {
    if (self.pasteHandler) self.pasteHandler();
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.touchDownContentOffsetY = self.contentOffset.y;
    [super touchesBegan:touches withEvent:event];
}
@end

@implementation TerminalViewController {
    KernEngine *_engine;
    vt_t _vt;
    TXTerminalTextView *_output;
    TXTerminalInputField *_input;
    UIButton *_ctrlButton;
    UIButton *_altButton;
    UIButton *_moreButton;
    UIButton *_fnButton;
    BOOL _ctrlLatched;
    BOOL _altLatched;
    UIStackView *_secondaryRow;
    UIScrollView *_fnRow;
    NSTimer *_flushTimer;
    NSLayoutConstraint *_toolbarBottom;
    BOOL _didClearScreenOnBoot; // clear-on-boot already done for this terminal instance
    // Gated fresh prompt (see viewDidAppear): the clear wipes the
    // replayed prompt, and a newline is only sent once the guest has
    // been quiet for a while and the VT is still empty — so a prompt
    // still in flight is not doubled by the newline. _clearOnBootDate
    // is when the clear ran; _lastConsoleOutputDate is the last
    // console byte on the main thread (also the clear time until any
    // output arrives, so "quiet" is measured from the clear);
    // _clearOnBootNewlineSent marks the decision made, either way.
    NSDate *_clearOnBootDate;
    NSDate *_lastConsoleOutputDate;
    BOOL _clearOnBootNewlineSent;
    CGPoint _exitPanStart; // where the top-edge exit drag began
    BOOL _exitPanAtTop;    // scrollback already at its top when the drag began
    CGFloat _pinchStartSize; // font size when the current pinch began (Termux-style zoom)
    NSTimer *_repeatTimer; // arrow key repeat (NewTerm 2.4: hold to repeat)
    NSData *_repeatData;
    // Incremental rendering (see flushTerminal): what the text view
    // already shows, so a flush only appends the scrollback lines
    // that arrived since the last render and re-renders the 25 grid
    // rows, instead of rebuilding the whole 2000-line string.
    NSUInteger _renderedScrollbackCount; // scrollback lines in the text view
    uint64_t _renderedScrollbackSeq;     // seq of the last rendered scrollback line
    uint64_t _renderedScrollbackDropped; // dropped count at the last render
    NSUInteger _scrollbackTextLength;    // chars of the text view that are scrollback
    BOOL _fullRebuildNeeded; // font size changed, or the render state is stale
    // Cursor blink: a timer toggles _cursorBlinkOn, and the next flush
    // re-renders the grid with the cursor shown or hidden. The flag
    // _cursorBlinkChanged is what wakes the flush when nothing else
    // arrived; it is cleared only by a flush that actually ran, so a
    // blink tick during a drag is not lost.
    NSTimer *_blinkTimer;
    BOOL _cursorBlinkOn;
    BOOL _cursorBlinkChanged;
    UIImpactFeedbackGenerator *_keyHaptic;  // light tap on key presses
    UIImpactFeedbackGenerator *_bellHaptic; // medium tap when the guest rings BEL
    UIButton *_copyButton; // secondary-row Copy, kept so onCopyAll can show "Copied"
    UILabel *_guestStatusLabel; // "Guest stopped/failed" notice over the terminal
    // Font-size ratio for the next rebuild (new size / old size, 1 when
    // no size change is pending): a pinch zoom or double-tap reset
    // rebuilds the text at a new size, and the saved scroll offset in
    // points has to be scaled by this or the view lands on a
    // different line. Consumed (reset to 1) by restoreTerminalPosition.
    CGFloat _rebuildOffsetScale;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = TXThemeBackgroundColor();
    vt_init(&_vt);
    _cursorBlinkOn = YES; // the cursor starts visible; the blink timer toggles it
    _fullRebuildNeeded = YES; // first render builds the whole string (see flushTerminal)
    _rebuildOffsetScale = 1; // no size change pending (see the ivar comment)
    _keyHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [_keyHaptic prepare];
    _bellHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [_bellHaptic prepare];

    _engine = [KernEngine shared];
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
    // the view and the terminal would start black. Feed it in small
    // chunks, the way the runtime delivers live output — the parser
    // keeps its state across calls, so chunked feeding renders
    // exactly what one big feed would, and the single 128 KiB call
    // is a code path live delivery never exercises. The whole buffer
    // is still replayed: only the earliest kernel lines would be
    // beyond the scrollback anyway.
    if (backlog.length) {
        const uint8_t *bytes = backlog.bytes;
        size_t remaining = backlog.length;
        while (remaining > 0) {
            size_t chunk = remaining > TXConfigReplayChunkBytes ? TXConfigReplayChunkBytes : remaining;
            vt_feed(&_vt, bytes, chunk);
            bytes += chunk;
            remaining -= chunk;
        }
    }

    // The terminal itself: the shared theme — refined dark background,
    // soft-white text, the one 14 pt monospace font. Lines never wrap:
    // the text container is wider than the screen, so long lines scroll
    // horizontally. That takes three layers, because 1b01285's single
    // widthTracksTextView = NO did not hold on device and fastfetch
    // still wrapped at ~48 columns: tracking OFF before the size is
    // set, the paragraph style's line-break mode is Clipping too
    // (the layout manager prefers it over the container's, and its
    // default is word-wrapping), and viewDidLayoutSubviews re-asserts
    // the configured width on every layout. A wrapped line splits a
    // two-column layout (fastfetch's logo/info, apt's progress bars)
    // and the halves interleave, so the wrap must never happen.
    // It starts at the top of the screen: there is no bar above it
    // any more.
    _output = [[TXTerminalTextView alloc] init];
    _output.translatesAutoresizingMaskIntoConstraints = NO;
    _output.editable = NO;
    _output.selectable = YES;
    _output.backgroundColor = TXThemeBackgroundColor();
    _output.font = TXTermFont();
    _output.textContainer.lineBreakMode = NSLineBreakByClipping;
    // Do not let the container track the view width (see above): with
    // tracking on, the configured width is thrown away on layout and
    // every long line wraps at the screen edge instead of scrolling.
    // Set tracking OFF *before* the size: setting the size while
    // tracking is still on lets the next layout throw it away, and
    // 1b01285 (size first, tracking off after) did not hold on device
    // — fastfetch still wrapped at ~48 columns.
    _output.textContainer.widthTracksTextView = NO;
    _output.textContainer.size = CGSizeMake(TXConfigTextContainerWidthPt, CGFLOAT_MAX);
    // A real margin, not the old 6 pt: the text sat flush against the
    // screen edges. 12 pt each side, 8 pt above, 6 pt below the text.
    _output.textContainerInset = UIEdgeInsetsMake(8, 12, 6, 12);
    _output.autocorrectionType = UITextAutocorrectionTypeNo;
    // VoiceOver: the output is the terminal itself, not a text field.
    _output.accessibilityLabel = @"Terminal output";
    _output.accessibilityHint = @"Shows the terminal output. Tap to focus the keyboard; tap a web address to open it.";
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
    // default colour, which is black-on-black in dark mode. The view
    // starts empty: the replay in viewDidLoad feeds the boot log and
    // the prompt into the VT, and the flush renders it within 60 ms.
    // It used to start with a "TermX" placeholder line, which read
    // as the terminal showing the app name instead of a prompt.
    _output.attributedText = [[NSAttributedString alloc] initWithString:@"" attributes:@{
        NSFontAttributeName: TXTermFont(),
        NSForegroundColorAttributeName: TXThemeForegroundColor(),
        NSParagraphStyleAttributeName: TXTermParagraphStyleForSize(TXTermFontSize()),
    }];
    [self.view addSubview:_output];

    // Hidden field that owns the software keyboard.
    _input = [[TXTerminalInputField alloc] init];
    __weak typeof(self) weakSelf = self;
    _input.onDeleteBackward = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf sendBackspace];
    };
    _input.delegate = self;
    // Long-press Paste on the terminal text: same as the Paste button
    // (clipboard as-is, empty clipboard is a no-op), then refocus the
    // hidden field so the keyboard comes back after the menu dismisses.
    _output.pasteHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf onPaste];
        [strongSelf->_input becomeFirstResponder];
    };
    _input.autocorrectionType = UITextAutocorrectionTypeNo;
    _input.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _input.returnKeyType = UIReturnKeyDefault;
    [self.view addSubview:_input];

    // The keyboard toolbar, NewTerm's model: a blurred bar with the key
    // rows, riding above the software keyboard. It is a container, not
    // an element: VoiceOver reads the key buttons inside it, not the bar.
    UIVisualEffectView *toolbar = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.isAccessibilityElement = NO;
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
    fnStack.spacing = 5;
    [_fnRow addSubview:fnStack];
    for (int i = 0; i < 12; i++) {
        NSString *title = [NSString stringWithFormat:@"f%d", i + 1];
        UIButton *b = [self keyButton:title];
        NSData *data = [NSData dataWithBytes:kFnBytes[i] length:kFnLens[i]];
        [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            (void)action;
            // Weak capture: the button retains the action, the action
            // retains this block, and a strong self here would retain
            // the VC — a cycle dealloc (which frees the VT) never
            // breaks. Same pattern as the blink and arrow-repeat timers.
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf sendKeyData:data];
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
    _secondaryRow = [[UIStackView alloc] init];
    _secondaryRow.translatesAutoresizingMaskIntoConstraints = NO;
    _secondaryRow.axis = UILayoutConstraintAxisHorizontal;
    _secondaryRow.spacing = 5;
    [self addKey:_secondaryRow title:@"home" bytes:"\x1B[H" length:3];
    [self addKey:_secondaryRow title:@"end" bytes:"\x1B[F" length:3];
    UIView *sp1 = [[UIView alloc] init];
    [_secondaryRow addArrangedSubview:sp1];
    [self addKey:_secondaryRow title:@"pgup" bytes:"\x1B[5~" length:4];
    [self addKey:_secondaryRow title:@"pgdn" bytes:"\x1B[6~" length:4];
    UIView *sp2 = [[UIView alloc] init];
    [_secondaryRow addArrangedSubview:sp2];
    [self addKey:_secondaryRow title:@"del" bytes:"\x1B[3~" length:4];
    // Copy: the whole transcript (scrollback plus grid) to the
    // clipboard, so copying does not depend only on the long-press
    // menu — which is awkward while output streams, because the
    // flush rebuilds the text under the selection.
    _copyButton = [self keyButton:@"copy"];
    // Not "Sends this key to the terminal": Copy sends nothing, it
    // copies the transcript to the clipboard.
    _copyButton.accessibilityHint = @"Copies the whole transcript.";
    [_copyButton addTarget:self action:@selector(onCopyAll) forControlEvents:UIControlEventTouchUpInside];
    [_secondaryRow addArrangedSubview:_copyButton];
    UIView *sp3 = [[UIView alloc] init];
    [_secondaryRow addArrangedSubview:sp3];
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
    // narrow. On a 430 pt screen each key is ~35 pt — the
    // four-letter labels shrink slightly to fit (see keyButton).
    // Paste is a clipboard icon, not the word: the word took the
    // most width in the row, and the icon reads just as clearly.
    UIStackView *primary = [[UIStackView alloc] init];
    primary.translatesAutoresizingMaskIntoConstraints = NO;
    primary.axis = UILayoutConstraintAxisHorizontal;
    primary.spacing = 3;
    primary.distribution = UIStackViewDistributionFillEqually;
    _ctrlButton = [self keyButton:@"ctrl"];
    [_ctrlButton addTarget:self action:@selector(onCtrl) forControlEvents:UIControlEventTouchUpInside];
    _ctrlButton.accessibilityHint = @"Toggles the Control modifier for the next key.";
    [primary addArrangedSubview:_ctrlButton];
    _altButton = [self keyButton:@"alt"];
    [_altButton addTarget:self action:@selector(onAlt) forControlEvents:UIControlEventTouchUpInside];
    _altButton.accessibilityHint = @"Toggles the Alt modifier for the next key. Alt plus a key sends Escape followed by that key.";
    [primary addArrangedSubview:_altButton];
    [self addKey:primary title:@"esc" bytes:"\x1B" length:1];
    [self addKey:primary title:@"tab" bytes:"\t" length:1];
    _moreButton = [self keyButton:@"more"];
    [_moreButton addTarget:self action:@selector(onMore) forControlEvents:UIControlEventTouchUpInside];
    _moreButton.accessibilityHint = @"Shows or hides the second key row.";
    [primary addArrangedSubview:_moreButton];
    // Paste as a clipboard icon: keyButton:@"paste" gives it the
    // "Paste" VoiceOver label, then the title is swapped for the
    // SF Symbol so it takes one key's width like everything else.
    // Same action, same chunked paste, same haptics as before.
    UIButton *pasteButton = [self keyButton:@"paste"];
    [pasteButton setTitle:nil forState:UIControlStateNormal];
    [pasteButton setImage:[UIImage systemImageNamed:@"doc.on.clipboard"
                                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium]]
                 forState:UIControlStateNormal];
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
    kbd.titleLabel.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightMedium];
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
        [rows.topAnchor constraintEqualToAnchor:toolbar.topAnchor constant:5],
        [rows.bottomAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:-4],
        [_fnRow.heightAnchor constraintEqualToConstant:TXConfigKeyRowHeightPt],
        [_secondaryRow.heightAnchor constraintEqualToConstant:TXConfigKeyRowHeightPt],
        [primary.heightAnchor constraintEqualToConstant:TXConfigKeyRowHeightPt],
    ]];
    // The toolbar rides above the software keyboard when it appears.
    _toolbarBottom = [toolbar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4];
    _toolbarBottom.active = YES;

    // Render the terminal at most every 60 ms; the guest sends a few bytes
    // at a time and redrawing on every one would thrash.
    // Weak capture: the run loop retains the timer, the timer retains
    // this block, and a strong self here would retain the VC — a cycle
    // dealloc (which invalidates the timer and frees the VT) never
    // breaks. Same pattern as the blink and arrow-repeat timers.
    _flushTimer = [NSTimer scheduledTimerWithTimeInterval:TXConfigTerminalFlushIntervalSec repeats:YES block:^(NSTimer *t) {
        (void)t;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf flushTerminal];
    }];
    // The flush must run while the user holds a key (tracking mode),
    // or output would not render until the finger lifts. It is added
    // to the common modes so it fires during tracking; flushTerminal
    // itself refuses to rebuild while the user is dragging, so the
    // scroll is never disturbed.
    [[NSRunLoop mainRunLoop] addTimer:_flushTimer forMode:NSRunLoopCommonModes];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
    // Tap the terminal to focus the keyboard — or to open a web
    // address, when the tap lands on one (see onTapTerminal:).
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onTapTerminal:)];
    [_output addGestureRecognizer:tap];

    // Double-tap resets the pinch zoom to the default 14 pt. It does
    // not replace the single tap: a double-tap also fires two single
    // taps, which focus the keyboard — harmless. The text view's own
    // double-tap (word selection) still fires alongside it, so a
    // double-tap selects a word and resets the size together.
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onDoubleTapTerminal:)];
    doubleTap.numberOfTapsRequired = 2;
    [_output addGestureRecognizer:doubleTap];

    // The way back to the startup screen: a downward drag that
    // starts in the top strip of the terminal. A scroll through the
    // scrollback starts anywhere and goes either way; this one only
    // fires for a drag that begins at the very top and moves
    // decisively down, so ordinary scrolling never triggers it.
    UIPanGestureRecognizer *exitPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onExitPan:)];
    exitPan.delegate = self;
    // One finger only: without this the recognizer can see a
    // two-finger pinch as well (it recognises simultaneously with
    // the text view's gestures), so a pinch starting in the top
    // strip and travelling down could dismiss the terminal.
    exitPan.maximumNumberOfTouches = 1;
    [_output addGestureRecognizer:exitPan];

    // Pinch to zoom, Termux-style: two fingers change the font size,
    // so the user can zoom out to fit a wide line (fastfetch in
    // portrait) or zoom in to read small text. The size persists
    // across launches. The pinch and the exit pan are different
    // gestures (two fingers vs one), so they never fight.
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(onPinch:)];
    [_output addGestureRecognizer:pinch];

    // Guest-dead notice: if the guest fails or stops while the
    // terminal is open, the screen would otherwise just go dead
    // with no explanation. A small label at the top says what
    // happened and how to get back (see termXEngineDidChangeState:);
    // it never dismisses the terminal and sends nothing to the
    // guest. Taps pass through it to the terminal below. Hidden
    // while the guest runs.
    _guestStatusLabel = [[UILabel alloc] init];
    _guestStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _guestStatusLabel.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.92];
    _guestStatusLabel.textColor = TXThemeForegroundColor();
    _guestStatusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _guestStatusLabel.textAlignment = NSTextAlignmentCenter;
    _guestStatusLabel.numberOfLines = 2;
    _guestStatusLabel.layer.cornerRadius = 8;
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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Re-assert the wide text container on every layout. 1b01285 set
    // widthTracksTextView = NO, but fastfetch still wrapped on device,
    // so something in layout resets the container to the view width;
    // this puts it back to the configured width before the next flush
    // renders. The guard breaks the loop: setting the size triggers
    // one more layout, which sees the configured width and does nothing.
    if (_output.textContainer.size.width != TXConfigTextContainerWidthPt) {
        _output.textContainer.size = CGSizeMake(TXConfigTextContainerWidthPt, CGFLOAT_MAX);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Clear on boot, once: if the startup screen asked for it, wipe
    // the boot log from the display and ask the guest for a fresh
    // prompt, so the user opens on a clean prompt instead of the
    // systemd boot log. Only once per terminal instance, and only
    // when clearScreenOnBoot is YES — returning to the terminal
    // later never wipes scrollback. The log itself is not lost: it
    // stays in guest.log and engine.log.
    if (self.clearScreenOnBoot && !_didClearScreenOnBoot) {
        _didClearScreenOnBoot = YES;
        // No command is typed into the terminal at boot — the width
        // (stty cols / COLUMNS) and the device-info files used to be
        // injected here, but auto-running commands at boot is not
        // wanted, so both injections are gone. The width is still
        // covered by the image itself (the shell startup sets stty
        // cols 48 + COLUMNS=48 at login), but the device-info files
        // are no longer written, so fastfetch falls back to Unknown
        // for Host, CPU and GPU. There is no way to pass the device
        // to the guest without typing a command: the runtime boot
        // struct has no kernel command line field, so the guest
        // cannot read it at its own boot either.
        //
        // The clear and the fresh prompt run async on the main queue,
        // not synchronously here. Console output arrives on the
        // runtime thread and is fed to the VT via dispatch_async to
        // the main queue, so a prompt that was already queued lands
        // AFTER a synchronous clear — the clear wipes the replayed
        // prompt, the queued prompt reappears, and the newline below
        // prints a second one, which is the double prompt the user
        // saw. Queuing the clear after the pending output means the
        // clear wipes everything.
        //
        // The newline is NOT sent here. The guest's own first bash
        // prompt can still be in flight when the clear runs (login
        // slower than the 0.7 s present delay, most likely on a cold
        // boot or the first boot after an image update), and a
        // newline sent now sits in the tty input buffer: the prompt
        // arrives as prompt one, bash reads the newline as an empty
        // command and prints prompt two. Instead the newline is
        // gated (see checkClearOnBootPrompt): after a short quiet
        // period with no new console output, the VT is checked — a
        // prompt already on screen means no newline, and only a
        // quiet, empty VT gets one newline to elicit a fresh prompt.
        // A fixed delay would only move the race to a slower login.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            static const uint8_t ed2[] = { 0x1B, '[', '2', 'J' };
            vt_feed(&strongSelf->_vt, ed2, sizeof(ed2));
            // The quiet clock starts at the clear: no output has
            // arrived since it yet, so "quiet for 300 ms" is first
            // true 300 ms from here unless output arrives.
            strongSelf->_clearOnBootDate = [NSDate date];
            strongSelf->_lastConsoleOutputDate = strongSelf->_clearOnBootDate;
            strongSelf->_clearOnBootNewlineSent = NO;
            [strongSelf flushTerminal];
            if ([strongSelf isPinnedToBottom]) [strongSelf scrollToBottomAnimated:NO];
            [strongSelf scheduleClearOnBootPromptCheck];
        });
    }
    // First render with final geometry: the 60 ms timer will flush
    // anyway, but this guarantees the view starts pinned to the live
    // line (not to a stale offset from before layout) the moment it
    // is on screen. Harmless when nothing has arrived yet: the flush
    // returns early while the VT is clean and scroll-to-bottom is a
    // no-op on short content.
    [self.view layoutIfNeeded];
    [self flushTerminal];
    if ([self isPinnedToBottom]) [self scrollToBottomAnimated:NO];
    [self startBlinkTimer];
}

// Gated fresh prompt after the clear-on-boot (see viewDidAppear):
// the newline is only sent once the guest has been quiet and the VT
// is still empty. Three cases, all ending in exactly one prompt:
//   - the prompt is already on screen (it arrived after the clear):
//     no newline, the prompt stands.
//   - the guest is still printing (output within the quiet period):
//     wait for a full quiet period, up to the cap, so a prompt
//     still in flight is not doubled.
//   - quiet and empty (the prompt was wiped by the clear and
//     nothing is coming): one newline elicits a fresh prompt.
// A bare newline is not a command, it only requests the prompt.
// Everything here runs on the main queue, like the clear and the
// console feed, so the timestamps and the VT cannot race.
- (void)scheduleClearOnBootPromptCheck {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(TXConfigClearOnBootQuietPeriodSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf checkClearOnBootPrompt];
    });
}

- (void)checkClearOnBootPrompt {
    if (_clearOnBootNewlineSent) return; // the decision is made, either way
    NSDate *now = [NSDate date];
    NSTimeInterval sinceOutput = [now timeIntervalSinceDate:_lastConsoleOutputDate];
    NSTimeInterval sinceClear = [now timeIntervalSinceDate:_clearOnBootDate];
    // Still printing: wait for a full quiet period before deciding,
    // up to the cap, so a slow login is not cut off mid-print.
    if (sinceOutput < TXConfigClearOnBootQuietPeriodSec &&
        sinceClear < TXConfigClearOnBootMaxWaitSec) {
        [self scheduleClearOnBootPromptCheck];
        return;
    }
    // Quiet now. If the VT shows anything, the prompt is already
    // there — the guest printed it after the clear.
    if (!vt_is_empty(&_vt)) {
        _clearOnBootNewlineSent = YES;
        return;
    }
    // Quiet and empty: the prompt was wiped by the clear and nothing
    // is coming. One newline asks bash for a fresh prompt.
    uint8_t nl = '\n';
    [_engine sendConsoleInput:[NSData dataWithBytes:&nl length:1]];
    _clearOnBootNewlineSent = YES;
    [self flushTerminal];
    if ([self isPinnedToBottom]) [self scrollToBottomAnimated:NO];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopBlinkTimer];
}

// The block cursor blinks at ~530 ms on, ~530 ms off (the common
// terminal default). The timer runs in the common modes so a blink
// tick is not starved by a key hold, and it only toggles a flag:
// the flush does the re-render, so the blink never fights the
// 60 ms flush timer. It pauses while the terminal is not focused
// (the keyboard is dismissed) or the app is in the background, and
// the cursor shows solid then — a blinking cursor on a screen the
// user is not typing in is noise, and a blink tick must not wake
// the app from the background to re-render.
- (void)startBlinkTimer {
    [self stopBlinkTimer];
    _cursorBlinkOn = YES;
    __weak typeof(self) weakSelf = self;
    _blinkTimer = [NSTimer scheduledTimerWithTimeInterval:0.53 repeats:YES block:^(NSTimer *t) {
        (void)t;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf onBlinkTimer];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_blinkTimer forMode:NSRunLoopCommonModes];
}

- (void)stopBlinkTimer {
    [_blinkTimer invalidate];
    _blinkTimer = nil;
}

- (void)onBlinkTimer {
    BOOL focused = [_input isFirstResponder];
    BOOL active = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    if (!focused || !active) {
        // Paused: show the cursor solid. Only wake a flush if the
        // cursor was actually hidden, or every background tick would
        // re-render for nothing.
        if (!_cursorBlinkOn) {
            _cursorBlinkOn = YES;
            _cursorBlinkChanged = YES;
            [self flushTerminal];
        }
        return;
    }
    _cursorBlinkOn = !_cursorBlinkOn;
    _cursorBlinkChanged = YES;
    [self flushTerminal];
}

// The cursor blink restarts visible on input: typing while the
// cursor is in its hidden phase would otherwise leave it invisible
// for up to another half second. Only wakes a flush when the cursor
// was actually hidden, so a keypress during the visible phase costs
// nothing. Called from every input funnel (sendKeyData, sendBackspace,
// the typing delegate, onPaste).
- (void)resetCursorBlink {
    if (!_cursorBlinkOn) {
        _cursorBlinkOn = YES;
        _cursorBlinkChanged = YES;
    }
}

// BEL: a short vibration, no sound. The guest rings the bell for
// tab completion with no matches, a backspace at an empty line, and
// similar "no" answers — a sound would be intrusive in a terminal,
// and a haptic is felt without being heard.
- (void)ringBell {
    [_bellHaptic impactOccurred];
    [_bellHaptic prepare];
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
                  : [UIColor colorWithWhite:0.45 alpha:1.0];
    }
    // ON is the app accent teal (#2AB3A3, TXThemeAccentColor), not
    // blue: a blue toggle on a teal-accent app reads as a different
    // app's colour.
    return on ? TXThemeAccentColor()
              : [UIColor colorWithWhite:0.30 alpha:1.0];
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
    b.titleLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    // Match the iOS keyboard keys: a medium grey key with white text
    // and a rounded corner, not the old dark key with blue text. The
    // keyboard letter keys are a mid grey over a near-black board;
    // white 0.30 lands on the same grey, and white text reads as a
    // key label instead of a link. The corner radius matches the
    // keyboard's, and the small shadow below the key gives the same
    // depth the keyboard keys have.
    b.backgroundColor = TXKeyBackground(NO, NO);
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateSelected];
    b.layer.cornerRadius = 6;
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOffset = CGSizeMake(0, 1);
    b.layer.shadowRadius = 1;
    b.layer.shadowOpacity = 0.35;
    // Slim horizontal insets: the primary row holds eleven equal
    // keys, and 10 pt insets overflowed a 430 pt screen once Paste
    // joined it. The titles shrink to fit instead of clipping: with
    // equal widths a four-letter label ("ctrl", "more", ~33.2 pt at
    // 14 pt) is wider than its key, so the title scales down rather
    // than truncating. 2 pt insets and a 0.6 floor keep it fitting
    // even on a 320 pt screen: each key is ~25.6 pt, leaving ~21.6 pt
    // for the label, and 33.2 pt at 0.6 scale is ~19.9 pt. The
    // three-letter keys stay at full size.
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 2, 6, 2);
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6;
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

- (void)sendKeyData:(NSData *)data {
    [self sendKeyData:data withFeedback:YES];
}

// A key button's bytes, with the latched modifiers applied. The
// feedback (click + haptic) is only for a real press: the arrow
// repeat timer sends with feedback NO, or holding an arrow would
// buzz the haptic at 12 Hz.
- (void)sendKeyData:(NSData *)data withFeedback:(BOOL)feedback {
    [self resetCursorBlink]; // input restarts the blink visible (see resetCursorBlink)
    if (feedback) {
        [[UIDevice currentDevice] playInputClick];
        [self keyHaptic];
    }
    // Alt prefixes ESC to the next input (the standard terminal Alt
    // behaviour: Alt+x sends ESC then x). A key button is not a
    // letter, so a latched Alt applies to this press and releases —
    // Alt+Up is ESC followed by the Up sequence, Alt+Esc is ESC ESC.
    if (_altLatched) {
        uint8_t esc = 0x1B;
        [_engine sendConsoleInput:[NSData dataWithBytes:&esc length:1]];
        [self releaseAlt];
    }
    // A key button is not a letter: if Ctrl is latched and the user
    // taps Esc, Tab, an arrow, Paste or an F-key instead of typing,
    // release the latch here, or it would leak into the next typed
    // character and turn it into a control byte the user never asked
    // for. (Typing a letter goes through the text-field delegate,
    // not here, so the Ctrl+letter path is untouched.)
    [self releaseCtrl];
    [_engine sendConsoleInput:data];
}

// Backspace: DEL (0x7F), the Linux console erase character. One
// place for both callers: the deleteBackward override on the empty
// field, and the delegate's backspace branch for the (currently
// impossible) case where the field holds text. Alt+Backspace is ESC
// then DEL (readline deletes the previous word). Backspace is not a
// letter, so the delegate's Ctrl+letter path never runs for it:
// release a latched Ctrl here, or it would stay latched and turn the
// next typed letter into a control byte.
- (void)sendBackspace {
    [self resetCursorBlink]; // input restarts the blink visible (see resetCursorBlink)
    if (_altLatched) {
        uint8_t esc = 0x1B;
        [_engine sendConsoleInput:[NSData dataWithBytes:&esc length:1]];
        [self releaseAlt];
    }
    [self releaseCtrl];
    uint8_t backspace = 0x7F;
    [_engine sendConsoleInput:[NSData dataWithBytes:&backspace length:1]];
}

- (void)addKey:(UIStackView *)row title:(NSString *)title bytes:(const char *)bytes length:(size_t)length {
    UIButton *b = [self keyButton:title];
    NSData *data = [NSData dataWithBytes:bytes length:length];
    // Weak capture: the button retains the action, the action retains
    // this block, and a strong self here would retain the VC — a cycle
    // dealloc (which frees the VT) never breaks. Same pattern as the
    // blink and arrow-repeat timers.
    __weak typeof(self) weakSelf = self;
    [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf sendKeyData:data];
    }] forControlEvents:UIControlEventTouchUpInside];
    [row addArrangedSubview:b];
}

// Arrow keys by tag: 0 left, 1 up, 2 down, 3 right (xterm sequences).
- (NSData *)arrowDataForTag:(NSInteger)tag {
    static const char *bytes[4] = {"\x1B[D", "\x1B[A", "\x1B[B", "\x1B[C"};
    if (tag < 0 || tag > 3) return nil;
    return [NSData dataWithBytes:bytes[tag] length:3];
}

// An arrow key: a full-height keyButton like every other key, with
// its own touch target and hold-to-repeat. A single glyph needs less
// side padding than a word, so the arrows take 5 pt insets. They sit
// directly in the primary row now, one equal share each — the nested
// stack that used to squeeze them into the leftover width is gone.
- (void)addArrowKey:(UIStackView *)row title:(NSString *)title tag:(NSInteger)tag {
    UIButton *b = [self keyButton:title];
    b.tag = tag;
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 5, 6, 5);
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
    _repeatTimer = [NSTimer scheduledTimerWithTimeInterval:TXConfigArrowRepeatIntervalSec repeats:YES block:^(NSTimer *t) {
        (void)t;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { [t invalidate]; return; }
        // No feedback on repeats: a press clicks and taps once, and
        // the hold repeats silently (see sendKeyData:withFeedback:).
        [strongSelf sendKeyData:strongSelf->_repeatData withFeedback:NO];
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
    _repeatData = nil;
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
// release paths in sendKeyData/sendBackspace/onPaste and the typing
// delegate use releaseCtrl/releaseAlt below, not these — these are
// the button actions, and they also give the haptic.
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
// The guest tty input buffer is 4096 bytes, so a paste larger than
// that loses its tail if it goes in one write: split it into 1 KiB
// chunks, one per run-loop turn, so the line discipline drains
// between writes. The Ctrl latch releases once, on the first chunk,
// the way sendKeyData does for a key button — not once per chunk.
- (void)onPaste {
    NSString *text = [UIPasteboard generalPasteboard].string;
    if (text.length == 0) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    [self resetCursorBlink]; // input restarts the blink visible (see resetCursorBlink)
    // A paste is not a key: a latched modifier releases once, on
    // the first chunk, the way sendKeyData does for a key button —
    // not once per chunk.
    [self releaseCtrl];
    [self releaseAlt];
    [[UIDevice currentDevice] playInputClick];
    [self keyHaptic];
    [self sendPasteChunk:data offset:0];
}

// Copy all: the whole transcript (scrollback plus grid, plain text)
// to the clipboard. vt_render is the plain-text transcript; it is
// built from cells, so it is always valid UTF-8.
- (void)onCopyAll {
    char *text = vt_render(&_vt);
    if (!text) return;
    NSString *transcript = [NSString stringWithUTF8String:text];
    free(text);
    if (!transcript) transcript = @"";
    // vt_render emits a "\n" for every row, so a transcript whose
    // last rows are blank ends in a run of newlines — up to 24 of
    // them on an empty screen. Trim the trailing newlines here, in
    // the transcript only: vt_render's output is untouched, so no
    // other caller sees a difference.
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
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_copyButton setTitle:@"copy" forState:UIControlStateNormal];
    });
}

// One 1 KiB chunk of a paste, then the next chunk on the next
// run-loop turn (dispatch_async on the main queue). Sending the whole
// paste in one write overflows the guest tty's 4096-byte input buffer.
- (void)sendPasteChunk:(NSData *)data offset:(NSUInteger)offset {
    if (offset >= data.length) return;
    NSUInteger len = MIN(TXConfigPasteChunkBytes, data.length - offset);
    [_engine sendConsoleInput:[data subdataWithRange:NSMakeRange(offset, len)]];
    if (offset + len < data.length) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) [strongSelf sendPasteChunk:data offset:offset + len];
        });
    }
}

- (void)onKeyboard {
    // Dismiss only, never toggle back on: endEditing resigns
    // whichever field actually owns the keyboard (the hidden _input).
    // Tapping the terminal brings the keyboard back.
    [self.view endEditing:YES];
}

- (void)onTapTerminal:(UITapGestureRecognizer *)tap {
    // A tap on a web address opens it; anywhere else focuses the
    // keyboard. The URL check comes first, or the tap would both
    // open the browser and show the keyboard.
    NSURL *url = [self urlAtPoint:[tap locationInView:_output]];
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }
    [_input becomeFirstResponder];
}

// The web address under a tap, or nil. Only the tapped line is
// scanned (running a detector over the whole transcript on every
// tap would be wasteful), and the tap must land on the link's own
// text — closestPositionToPoint snaps to the nearest text, so a tap
// in empty space below a URL-terminated line would otherwise count
// as a tap on the URL. Only http and https open from the terminal:
// a mailto or telephone link under a tap is too easy to hit by
// accident when the user only meant to focus the keyboard.
- (nullable NSURL *)urlAtPoint:(CGPoint)point {
    UITextPosition *pos = [_output closestPositionToPoint:point];
    if (!pos) return nil;
    NSInteger ch = [_output offsetFromPosition:_output.beginningOfDocument toPosition:pos];
    NSString *text = _output.text;
    if (ch < 0 || ch >= (NSInteger)text.length) return nil;
    NSRange lineRange = [text lineRangeForRange:NSMakeRange((NSUInteger)ch, 0)];
    NSString *line = [text substringWithRange:lineRange];
    // Cached: building a detector parses the data-detector rules,
    // and doing it on every tap is wasteful. A detector is stateless
    // once built, so one shared instance is safe (and urlAtPoint
    // only ever runs on the main thread).
    static NSDataDetector *detector = nil;
    static dispatch_once_t detectorOnce;
    dispatch_once(&detectorOnce, ^{
        detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];
    });
    if (!detector) return nil;
    NSArray<NSTextCheckingResult *> *matches = [detector matchesInString:line options:0 range:NSMakeRange(0, line.length)];
    for (NSTextCheckingResult *match in matches) {
        NSRange linkRange = NSMakeRange(match.range.location + lineRange.location, match.range.length);
        if (!NSLocationInRange((NSUInteger)ch, linkRange)) continue;
        NSURL *url = match.URL;
        if (!url || (![url.scheme isEqualToString:@"http"] && ![url.scheme isEqualToString:@"https"])) continue;
        UITextPosition *start = [_output positionFromPosition:_output.beginningOfDocument offset:(NSInteger)linkRange.location];
        UITextPosition *end = start ? [_output positionFromPosition:start offset:(NSInteger)linkRange.length] : nil;
        UITextRange *linkTextRange = (start && end) ? [_output textRangeFromPosition:start toPosition:end] : nil;
        if (!linkTextRange) continue;
        CGRect rect = [_output firstRectForRange:linkTextRange];
        if (CGRectContainsPoint(CGRectInset(rect, -8, -4), point)) return url;
    }
    return nil;
}

// Double-tap resets the pinch zoom to the default size.
- (void)onDoubleTapTerminal:(UITapGestureRecognizer *)tap {
    (void)tap;
    if (TXTermFontSize() == TXConfigTermFontSizeDefault) return;
    // The rebuild below re-renders at the new size: remember the
    // size ratio so the scroll position survives it (see
    // restoreTerminalPosition).
    _rebuildOffsetScale = TXConfigTermFontSizeDefault / TXTermFontSize();
    TXSetTermFontSize(TXConfigTermFontSizeDefault);
    _output.font = TXTermFont();
    _fullRebuildNeeded = YES; // the whole text re-renders at the new size
    [self flushTerminal];
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
            // Read the offset recorded at touch-down (touchesBegan on
            // the text view), not the live offset: the pan only
            // reaches Began after the finger moved, so a drag that
            // started slightly scrolled can already be at offset 0
            // by now and would wrongly count as starting at the top.
            _exitPanAtTop = _output.touchDownContentOffsetY <= 1;
            break;
        case UIGestureRecognizerStateEnded: {
            CGPoint translation = [pan translationInView:_output];
            if (_exitPanAtTop && _exitPanStart.y < TXConfigExitPanTopStripPt && translation.y > TXConfigExitPanTranslationThresholdPt &&
                fabs(translation.y) > fabs(translation.x)) {
                [self dismissViewControllerAnimated:YES completion:nil];
            }
            break;
        }
        default:
            break;
    }
}

// Pinch to zoom, Termux-style: two fingers scale the font size, so
// the user can zoom out to fit a wide line (fastfetch in portrait)
// or zoom in to read small text. The scale is relative to the size
// when the pinch began, not cumulative, so a slow pinch does not
// run away. The new size is saved at once, so it survives a relaunch
// and the next terminal opens at the same size. A pinch changes the
// display only, not the guest: there is no winsize channel to the
// guest (the runtime has no winsize API), so the guest still lays
// out for the width its shell set at login — zooming out shows more
// columns on screen than the guest thinks exist, and zooming in
// shows fewer. Do not "fix" this by typing stty into the terminal:
// auto-running commands at boot is not wanted. The flush re-renders
// the whole scrollback at the new size; the content and scroll
// position are preserved by flushTerminal.
- (void)onPinch:(UIPinchGestureRecognizer *)pinch {
    switch (pinch.state) {
        case UIGestureRecognizerStateBegan:
            _pinchStartSize = TXTermFontSize();
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat size = _pinchStartSize * pinch.scale;
            if (size < TXConfigTermFontSizeMin) size = TXConfigTermFontSizeMin;
            if (size > TXConfigTermFontSizeMax) size = TXConfigTermFontSizeMax;
            // A small dead zone keeps recognizer jitter from
            // re-rendering on every tiny movement; the old 0.5 pt
            // zone made small pinches feel unresponsive.
            if (fabs(size - TXTermFontSize()) < TXConfigPinchDeadZonePt) return;
            // The rebuild below re-renders at the new size: remember
            // the size ratio so the scroll position survives it (see
            // restoreTerminalPosition).
            _rebuildOffsetScale = size / TXTermFontSize();
            TXSetTermFontSize(size);
            _output.font = TXTermFont();
            _fullRebuildNeeded = YES; // the whole text re-renders at the new size
            [self flushTerminal];
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
    // label over the terminal with what happened and how to get
    // back — never auto-dismiss (the user may want the scrollback)
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
    // The runtime calls this on its own thread, but the VT (grid,
    // scrollback and its file-static parser state in vt.c) is only
    // ever touched on the main thread, where the flush timer also
    // runs — feeding it from here would race the flush.
    dispatch_async(dispatch_get_main_queue(), ^{
        // The arrival time, for the clear-on-boot gate: a prompt
        // that arrives after the clear means the guest is still
        // printing, so the gated newline must wait for quiet.
        self->_lastConsoleOutputDate = [NSDate date];
        vt_feed(&_vt, data.bytes, data.length);
    });
}

- (UIColor *)colorForCell:(vt_cell)cell isForeground:(BOOL)isFg {
    int16_t index = isFg ? cell.fg : cell.bg;
    if (index < 0) {
        return isFg ? TXThemeForegroundColor() : TXThemeBackgroundColor();
    }
    // Bold text in colours 0-7 renders as the bright variant, as xterm does.
    if (isFg && cell.bold && index < 8) index += 8;
    if (index == 0 && isFg) {
        // xterm black as a foreground is invisible on a dark
        // background, so render it as a dim grey. (As a background it
        // falls through to XTermColor, whose colour 0 is the theme
        // background, so the cell blends into the screen.)
        return [UIColor colorWithWhite:0.45 alpha:1.0];
    }
    return XTermColor((int)index);
}

- (void)flushTerminal {
    // Wake on new output or on a blink tick. The blink flag is
    // cleared only by a flush that actually ran (below, after the
    // drag check): a blink tick during a drag must not be lost, or
    // the cursor would stick in one phase until the next output.
    if (!_vt.dirty && !_cursorBlinkChanged) return;
    // Do not rebuild while the user is dragging or the view is still
    // decelerating: setting attributedText resets the scroll position,
    // and rebuilding mid-drag would yank the view. The dirty flag
    // stays set, so the next tick after the drag renders the output.
    // (The timer is in the common modes so it fires during a key
    // hold; a drag is the only time a flush is skipped.)
    if (_output.isTracking || _output.isDragging || _output.isDecelerating) return;
    // Do not rebuild while the user has text selected or the edit
    // menu is open: rebuilding the text storage clears the selection
    // and dismisses the Copy/Select menu, so copying while output
    // streams is impossible. The dirty flag (and the blink flag)
    // stay set, so nothing is lost — the next 60 ms tick after the
    // selection clears renders the output. The selection restore in
    // restoreTerminalPosition stays as a fallback for a selection
    // made between this check and the rebuild.
    if (_output.selectedRange.length > 0 || [[UIMenuController sharedMenuController] isMenuVisible]) return;
    _vt.dirty = 0;
    _cursorBlinkChanged = NO;
    // Full rebuild when the render state cannot be trusted: the font
    // size changed (every attribute changes), the scrollback shrank
    // (a clear), or the counters went backwards. Otherwise the
    // incremental path appends only what arrived since the last
    // render. A full rebuild is also the fallback inside the
    // incremental path if it finds an inconsistency mid-way.
    if (_fullRebuildNeeded ||
        (NSUInteger)_vt.scrollback_count < _renderedScrollbackCount ||
        _vt.scrollback_seq < _renderedScrollbackSeq ||
        _vt.scrollback_dropped < _renderedScrollbackDropped) {
        [self fullRebuildTerminal];
    } else {
        [self incrementalFlushTerminal];
    }
    // The bell rings after the render, so the output that caused it
    // is already on screen. vt->bell is cleared here, not in the
    // render paths: a flush that returns early (dragging) leaves it
    // set, so the bell is rung by the next flush instead of lost.
    if (_vt.bell) {
        _vt.bell = 0;
        [self ringBell];
    }
}

// The whole string, rebuilt from the VT: the known-good path, used
// for the first render, after a font-size change, after a clear, and
// as the fallback when the incremental path finds an inconsistency.
// The 60 ms timer used to rebuild the whole string on every flush,
// which dropped frames under heavy output; the incremental path
// below is the steady state, and this stays as the fallback.
- (void)fullRebuildTerminal {
    // This method rebuilds the whole attributed string from the VT.
    // Setting attributedText resets the scroll position, so the old
    // flush yanked the view to the bottom on every tick and a swipe
    // down was undone 60 ms later — "it go up again and again".
    // The fix is the rule every mobile terminal uses: follow the
    // bottom only while the user is already pinned there; when they
    // have scrolled up into the scrollback, put the view back exactly
    // where they left it.
    BOOL pinned = [self isPinnedToBottom];
    CGPoint savedOffset = _output.contentOffset;
    NSRange savedSelection = _output.selectedRange;
    BOOL hadSelection = savedSelection.length > 0;
    UIFont *font = TXTermFont();
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    NSAttributedString *newline = [[NSAttributedString alloc] initWithString:@"\n" attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: TXThemeForegroundColor(),
        NSParagraphStyleAttributeName: TXTermParagraphStyleForSize(font.pointSize),
    }];
    // Scrollback keeps its colours now (vt.c stores cells, not
    // plain text), so it renders through the same run grouping as
    // the grid — a coloured line looks the same scrolled up as it
    // did on the live screen.
    for (int i = 0; i < _vt.scrollback_count; i++) {
        [self appendScrollbackRow:i font:font newline:newline to:out];
    }
    NSUInteger scrollbackLength = out.length;
    [out appendAttributedString:[self gridAttributedStringWithFont:font]];
    _output.attributedText = out;
    // The render state now matches the VT exactly.
    _renderedScrollbackCount = (NSUInteger)_vt.scrollback_count;
    _renderedScrollbackSeq = _vt.scrollback_seq;
    _renderedScrollbackDropped = _vt.scrollback_dropped;
    _scrollbackTextLength = scrollbackLength;
    _fullRebuildNeeded = NO;
    [self restoreTerminalPosition:pinned savedOffset:savedOffset
                   savedSelection:savedSelection hadSelection:hadSelection
                    deletedLength:0 droppedLines:0 font:font];
}

// The steady state: only what changed since the last render.
// The scrollback is the expensive part (up to 2000 lines) and it
// only ever grows at the end and drops from the front, so the new
// lines are appended at the scrollback/grid boundary and the dropped
// ones are deleted from the front; the grid (25 rows) is re-rendered
// whole, which is cheap. Any inconsistency falls back to a full
// rebuild — a wrong render state must never produce a wrong screen.
- (void)incrementalFlushTerminal {
    BOOL pinned = [self isPinnedToBottom];
    CGPoint savedOffset = _output.contentOffset;
    NSRange savedSelection = _output.selectedRange;
    BOOL hadSelection = savedSelection.length > 0;
    UIFont *font = TXTermFont();
    NSAttributedString *newline = [[NSAttributedString alloc] initWithString:@"\n" attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: TXThemeForegroundColor(),
        NSParagraphStyleAttributeName: TXTermParagraphStyleForSize(font.pointSize),
    }];
    NSTextStorage *storage = _output.textStorage;
    NSUInteger deletedLength = 0;
    NSUInteger droppedLines = 0;
    [storage beginEditing];

    // Defensive: the dispatcher already routes a shrunk scrollback
    // to a full rebuild, but an out-of-range length here would read
    // or replace out of bounds — fall back instead of trusting it.
    if (_scrollbackTextLength > (NSUInteger)storage.length ||
        (NSUInteger)_vt.scrollback_count < _renderedScrollbackCount) {
        [storage endEditing];
        [self fullRebuildTerminal];
        return;
    }

    // 1. Drop the lines that fell off the front at the cap.
    uint64_t droppedDelta = _vt.scrollback_dropped - _renderedScrollbackDropped;
    if (droppedDelta > 0) {
        if (droppedDelta > _renderedScrollbackCount || _scrollbackTextLength > (NSUInteger)storage.length) {
            [storage endEditing];
            [self fullRebuildTerminal];
            return;
        }
        // Find the end of the droppedDelta-th line in the scrollback
        // portion (each line ends with "\n"). The scan is short: at
        // the cap one line drops per scroll.
        NSString *text = storage.string;
        NSUInteger pos = 0;
        NSUInteger found = 0;
        while (found < droppedDelta && pos < _scrollbackTextLength) {
            NSRange nl = [text rangeOfString:@"\n" options:0 range:NSMakeRange(pos, _scrollbackTextLength - pos)];
            if (nl.location == NSNotFound) break;
            pos = NSMaxRange(nl);
            found++;
        }
        if (found != droppedDelta) {
            [storage endEditing];
            [self fullRebuildTerminal];
            return;
        }
        [storage deleteCharactersInRange:NSMakeRange(0, pos)];
        deletedLength = pos;
        droppedLines = (NSUInteger)droppedDelta;
        _scrollbackTextLength -= pos;
        _renderedScrollbackCount -= (NSUInteger)droppedDelta;
        _renderedScrollbackDropped = _vt.scrollback_dropped;
    }

    // 2. Append the new scrollback lines at the scrollback/grid
    // boundary. The new lines are the last ones in the VT's
    // scrollback; the grid below them is pushed down, not rewritten.
    NSUInteger newCount = (NSUInteger)_vt.scrollback_count - _renderedScrollbackCount;
    if (newCount > 0) {
        NSMutableAttributedString *added = [[NSMutableAttributedString alloc] init];
        for (NSUInteger k = 0; k < newCount; k++) {
            int row = _vt.scrollback_count - (int)newCount + (int)k;
            [self appendScrollbackRow:row font:font newline:newline to:added];
        }
        [storage insertAttributedString:added atIndex:_scrollbackTextLength];
        _scrollbackTextLength += added.length;
        _renderedScrollbackCount += newCount;
        _renderedScrollbackSeq = _vt.scrollback_seq;
    }

    // 3. Re-render the grid (25 rows): replace everything after the
    // scrollback. This is what the blink tick exercises when no new
    // output arrived — only the cursor cell changes.
    NSRange gridRange = NSMakeRange(_scrollbackTextLength, (NSUInteger)storage.length - _scrollbackTextLength);
    [storage replaceCharactersInRange:gridRange withAttributedString:[self gridAttributedStringWithFont:font]];
    [storage endEditing];

    [self restoreTerminalPosition:pinned savedOffset:savedOffset
                   savedSelection:savedSelection hadSelection:hadSelection
                    deletedLength:deletedLength droppedLines:droppedLines font:font];
}

// After a render: restore the selection and the scroll position.
// Setting attributedText clears any active text selection, so the
// user cannot copy while output streams: save it (as an NSRange,
// which survives the rebuild) and restore it afterwards, clamped
// to the new text length. Lines dropped from the front shift the
// selection up by the deleted characters, and shift the scroll
// offset up by the dropped lines' height — without the offset
// shift the view would jump down by the dropped lines. Pinned
// means the last visible line is the live one: the bottom of the
// content is within one line of the bottom of the view.
- (void)restoreTerminalPosition:(BOOL)pinned savedOffset:(CGPoint)savedOffset
                 savedSelection:(NSRange)savedSelection hadSelection:(BOOL)hadSelection
                  deletedLength:(NSUInteger)deletedLength droppedLines:(NSUInteger)droppedLines
                           font:(UIFont *)font {
    [_output layoutIfNeeded]; // contentSize is current before we measure it
    if (hadSelection) {
        NSUInteger len = _output.textStorage.length;
        NSRange restored = savedSelection;
        if (deletedLength > 0) {
            if (restored.location >= deletedLength) {
                restored.location -= deletedLength;
            } else {
                // The selection started inside the deleted lines:
                // clamp it to the top, keeping what survived.
                NSUInteger cut = deletedLength - restored.location;
                restored.location = 0;
                restored.length = restored.length > cut ? restored.length - cut : 0;
            }
        }
        if (restored.location > len) restored.location = len;
        if (restored.location + restored.length > len) restored.length = len - restored.location;
        _output.selectedRange = restored;
    }
    if (pinned) {
        [self scrollToBottomAnimated:NO];
    } else {
        // Restore the saved offset, clamped to the new content
        // height (a clear-screen can shrink it under the old one).
        // contentInset.bottom is zero by design (the toolbar clears
        // the keyboard, so the text view takes no inset — see
        // viewDidLoad), and this check reads it, so if an inset ever
        // comes back the "bottom" moves past the text by exactly
        // that amount and the terminal opens black. Keep it zero.
        CGPoint restored = savedOffset;
        // A font-size change (pinch zoom, double-tap reset) rebuilt
        // the text at a new size, so the old offset in points no
        // longer points at the same line: line height scales with
        // the font size, so scale the offset by the size ratio (new
        // / old, set by onPinch/onDoubleTapTerminal). Pinned is
        // handled above by scrollToBottom, so only the scrolled-up
        // case needs this.
        if (_rebuildOffsetScale > 0 && _rebuildOffsetScale != 1) {
            restored.y *= _rebuildOffsetScale;
        }
        if (droppedLines > 0) {
            CGFloat lineHeight = font.lineHeight + TXTermParagraphStyleForSize(font.pointSize).lineSpacing;
            restored.y -= (CGFloat)droppedLines * lineHeight;
        }
        CGFloat maxOffset = _output.contentSize.height + _output.contentInset.bottom - _output.bounds.size.height;
        CGFloat minY = -_output.contentInset.top;
        restored.y = MIN(MAX(restored.y, minY), MAX(maxOffset, minY));
        _output.contentOffset = restored;
    }
    // The size ratio is consumed by this render, whichever branch
    // ran: a pinch while pinned still rebuilt at the new size, so a
    // stale ratio must not scale a later flush's offset.
    _rebuildOffsetScale = 1;
}

// One scrollback row (cells) plus its newline. The row is trimmed
// to its last non-blank cell here, at render time — the same rule
// as a grid row.
- (void)appendScrollbackRow:(int)row font:(UIFont *)font newline:(NSAttributedString *)newline
                         to:(NSMutableAttributedString *)out {
    const vt_cell *cells = _vt.scrollback + (size_t)row * VT_COLS;
    int last = VT_COLS - 1;
    while (last >= 0 && cells[last].ch == 0) last--;
    if (last >= 0) {
        [self appendCellRow:cells count:last + 1 font:font cursorAt:-1 cursorVisible:NO to:out];
    }
    [out appendAttributedString:newline];
}

// The 25 grid rows as one attributed string (no trailing newline).
// The cursor cell is kept even past the last non-blank cell when the
// cursor is shown, so the block is always visible.
- (NSMutableAttributedString *)gridAttributedStringWithFont:(UIFont *)font {
    NSMutableAttributedString *grid = [[NSMutableAttributedString alloc] init];
    BOOL cursorShown = _vt.cursor_visible && _cursorBlinkOn;
    NSAttributedString *newline = [[NSAttributedString alloc] initWithString:@"\n" attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: TXThemeForegroundColor(),
        NSParagraphStyleAttributeName: TXTermParagraphStyleForSize(font.pointSize),
    }];
    for (int r = 0; r < VT_ROWS; r++) {
        int last = VT_COLS - 1;
        while (last >= 0 && _vt.grid[r][last].ch == 0) last--;
        // The cursor past the last column (cx == 80, deferred wrap
        // in vt_put_char) is not a cell that exists: extending the
        // row to column 80 would read cells[80] — the next row's
        // first cell for rows 0-23, and past the grid (into saved_cx,
        // saved_cy and the fields after it) for row 24. Clamp the
        // cursor to the last column instead, so the block renders on
        // the final cell and nothing is read out of bounds. vt.c's
        // deferred wrap is untouched: cx stays 80 until the next
        // printable char wraps.
        int cursorCol = (r == _vt.cy) ? MIN(_vt.cx, VT_COLS - 1) : -1;
        if (r == _vt.cy && _vt.cx > last && cursorShown) last = cursorCol; // keep the cursor cell
        if (last >= 0) {
            [self appendCellRow:_vt.grid[r] count:last + 1 font:font
                       cursorAt:cursorCol cursorVisible:cursorShown
                             to:grid];
        }
        if (r < VT_ROWS - 1) [grid appendAttributedString:newline];
    }
    return grid;
}

// Render one row of cells, grouping consecutive cells with the same
// fg/bg/bold into runs. The grid and the scrollback both render
// through here, so a colour means the same in both. cursorCol is the
// column of the block cursor (-1 for no cursor: scrollback rows
// never have one); when the cursor is shown its cell renders
// inverted and breaks the run.
- (void)appendCellRow:(const vt_cell *)cells count:(int)count font:(UIFont *)font
             cursorAt:(int)cursorCol cursorVisible:(BOOL)cursorVisible
                   to:(NSMutableAttributedString *)out {
    if (count <= 0) return;
    // A row is VT_COLS cells: never read past it. The grid path
    // clamps the cursor to the last column (see
    // gridAttributedStringWithFont), but a count past the row would
    // read the next row's first cell — or, on the last row, past the
    // grid entirely. Clamp here too, so no caller can ever drive
    // this loop out of bounds.
    if (count > VT_COLS) count = VT_COLS;
    NSMutableString *runText = [NSMutableString string];
    vt_cell runCell = cells[0];
    BOOL haveRun = NO;
    for (int c = 0; c < count; c++) {
        vt_cell cell = cells[c];
        BOOL isCursor = (cursorVisible && c == cursorCol);
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
    return _output.contentOffset.y >= bottomOffset - TXConfigPinnedToBottomThresholdPt;
}

- (void)scrollToBottomAnimated:(BOOL)animated {
    CGFloat maxOffset = _output.contentSize.height + _output.contentInset.bottom - _output.bounds.size.height;
    CGFloat y = MAX(maxOffset, -_output.contentInset.top);
    [_output setContentOffset:CGPointMake(_output.contentOffset.x, y) animated:animated];
}

- (void)appendRun:(NSMutableAttributedString *)out text:(NSString *)text
             cell:(vt_cell)cell font:(UIFont *)font cursor:(BOOL)cursor {
    if (text.length == 0) return;
    UIColor *fg, *bg;
    if (cursor) {
        // The block cursor: light block, theme-dark glyph, so it
        // reads on the refined dark background.
        fg = TXThemeBackgroundColor();
        bg = TXThemeForegroundColor();
    } else {
        fg = [self colorForCell:cell isForeground:YES];
        bg = [self colorForCell:cell isForeground:NO];
    }
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: fg,
        NSBackgroundColorAttributeName: bg,
        NSParagraphStyleAttributeName: TXTermParagraphStyleForSize(font.pointSize),
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
    // Work out the bytes for this key first, then apply the latched
    // modifiers: Ctrl turns a letter into its control byte (and
    // Return into Ctrl-J), Alt prefixes ESC to whatever the key
    // produces. Both latches release on use.
    // A typed key is input too, and it bypasses sendKeyData: (it
    // sends straight to the engine below), so the blink resets here
    // as well as in sendKeyData:.
    [self resetCursorBlink];
    NSData *toSend = nil;
    if ([string isEqualToString:@"\n"]) {
        // NewTerm sends carriage return, not line feed — unless Ctrl
        // is latched, in which case Return is Ctrl-J (line feed,
        // 0x0A) and the latch releases. Without this the newline
        // branch returns before the Ctrl check below, so Ctrl stays
        // latched and the next typed letter becomes a control byte.
        uint8_t b = _ctrlLatched ? 0x0A : '\r';
        toSend = [NSData dataWithBytes:&b length:1];
        [self releaseCtrl];
    } else if (_ctrlLatched) {
        // Ctrl plus a letter: send the control byte, then unlatch.
        // A character with no control mapping (a digit, a space)
        // sends as-is once the latch releases.
        uint8_t control = [self controlByteForCharacter:[string characterAtIndex:0]];
        [self releaseCtrl];
        if (control) toSend = [NSData dataWithBytes:&control length:1];
        else toSend = [string dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        toSend = [string dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (_altLatched) {
        // Alt prefixes ESC to the next input, whatever it is: Alt+x
        // is ESC x, Alt+Return is ESC CR, Alt+Ctrl+C is ESC ETX.
        uint8_t esc = 0x1B;
        [_engine sendConsoleInput:[NSData dataWithBytes:&esc length:1]];
        [self releaseAlt];
    }
    if (toSend.length) [_engine sendConsoleInput:toSend];
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
        if (wasPinned) [self scrollToBottomAnimated:NO];
    } completion:nil];
}

- (void)dealloc {
    // Observable in engine.log: with the flush-timer cycle fixed,
    // this line proves the VC (and its VT) is actually freed when
    // the terminal is dismissed. Its absence after a dismiss means
    // a retain cycle is still holding it.
    TXLogEngine(@"TerminalViewController dealloc");
    [_flushTimer invalidate];
    [_blinkTimer invalidate];
    [_repeatTimer invalidate];
    vt_free(&_vt);
}

@end
