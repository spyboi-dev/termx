// SPDX-License-Identifier: GPL-2.0-or-later
#import "GuestViewController.h"
#import "KernEngine.h"
#import <MetalKit/MetalKit.h>

// Linux evdev key codes (include/linux/input-event-codes.h).
#define KEY_ESC 1
#define KEY_1 2
#define KEY_2 3
#define KEY_3 4
#define KEY_4 5
#define KEY_5 6
#define KEY_6 7
#define KEY_7 8
#define KEY_8 9
#define KEY_9 10
#define KEY_0 11
#define KEY_MINUS 12
#define KEY_EQUAL 13
#define KEY_BACKSPACE 14
#define KEY_TAB 15
#define KEY_Q 16
#define KEY_W 17
#define KEY_E 18
#define KEY_R 19
#define KEY_T 20
#define KEY_Y 21
#define KEY_U 22
#define KEY_I 23
#define KEY_O 24
#define KEY_P 25
#define KEY_LEFTBRACE 26
#define KEY_RIGHTBRACE 27
#define KEY_ENTER 28
#define KEY_LEFTCTRL 29
#define KEY_A 30
#define KEY_S 31
#define KEY_D 32
#define KEY_F 33
#define KEY_G 34
#define KEY_H 35
#define KEY_J 36
#define KEY_K 37
#define KEY_L 38
#define KEY_SEMICOLON 39
#define KEY_APOSTROPHE 40
#define KEY_GRAVE 41
#define KEY_LEFTSHIFT 42
#define KEY_BACKSLASH 43
#define KEY_Z 44
#define KEY_X 45
#define KEY_C 46
#define KEY_V 47
#define KEY_B 48
#define KEY_N 49
#define KEY_M 50
#define KEY_COMMA 51
#define KEY_DOT 52
#define KEY_SLASH 53
#define KEY_SPACE 57
#define KEY_HOME 102
#define KEY_UP 103
#define KEY_PAGEUP 104
#define KEY_LEFT 105
#define KEY_RIGHT 106
#define KEY_END 107
#define KEY_DOWN 108
#define KEY_PAGEDOWN 109

@interface GuestViewController () <UITextFieldDelegate> {
    MTKView* _metalView;
    UILabel* _statusLabel;
    UIButton* _installButton;
    UIButton* _bootButton;
    UIButton* _stopButton;
    UIButton* _termuxButton;
    UIButton* _keyboardButton;
    UITextField* _hiddenField;
    NSMutableDictionary<NSValue*, NSNumber*>* _touchSlots;
    uint32_t _nextSlot;
    BOOL _ctrlLatched;
}
@end

@implementation GuestViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _touchSlots = [NSMutableDictionary dictionary];
    _nextSlot = 0;

    // --- status bar ---
    UIView* bar = [[UIView alloc] init];
    bar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    UILabel* title = [[UILabel alloc] init];
    title.text = @"KTerm";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:title];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.text = [KernEngine shared].statusText;
    _statusLabel.textColor = [UIColor lightGrayColor];
    _statusLabel.font = [UIFont systemFontOfSize:12];
    _statusLabel.numberOfLines = 2;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:_statusLabel];

    _installButton = [self makeButton:@"Install" action:@selector(onInstall)];
    _bootButton = [self makeButton:@"Boot" action:@selector(onBoot)];
    _stopButton = [self makeButton:@"Stop" action:@selector(onStop)];
    _termuxButton = [self makeButton:@"Termux" action:@selector(onTermux)];
    _keyboardButton = [self makeButton:@"⌨" action:@selector(onKeyboard)];
    UIStackView* buttons = [[UIStackView alloc]
        initWithArrangedSubviews:@[_installButton, _bootButton, _stopButton, _termuxButton, _keyboardButton]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 8;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:buttons];

    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [title.topAnchor constraintEqualToAnchor:bar.topAnchor constant:6],
        [title.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:12],
        [_statusLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:12],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-12],
        [buttons.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:6],
        [buttons.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:12],
        [buttons.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-8],
    ]];

    // --- guest display ---
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _metalView = [[MTKView alloc] initWithFrame:CGRectZero device:device];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    _metalView.backgroundColor = [UIColor blackColor];
    _metalView.framebufferOnly = NO;
    _metalView.enableSetNeedsDisplay = NO;
    _metalView.paused = NO;
    _metalView.multipleTouchEnabled = YES;
    [self.view addSubview:_metalView];
    [NSLayoutConstraint activateConstraints:@[
        [_metalView.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [_metalView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_metalView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_metalView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // --- hidden field for the software keyboard ---
    _hiddenField = [[UITextField alloc] initWithFrame:CGRectZero];
    _hiddenField.autocorrectionType = UITextAutocorrectionTypeNo;
    _hiddenField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _hiddenField.delegate = self;
    _hiddenField.inputAccessoryView = [self makeKeyRow];
    [self.view addSubview:_hiddenField];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshStatus)
                                                 name:@"KTermStateChanged" object:nil];
    [self refreshStatus];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIButton*)makeButton:(NSString*)title action:(SEL)action {
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    b.layer.cornerRadius = 8;
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView*)makeKeyRow {
    NSArray* keys = @[@"Esc", @"Tab", @"Ctrl", @"←", @"↑", @"↓", @"→",
                      @"Home", @"End", @"PgUp", @"PgDn", @"⏎"];
    UIStackView* row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6;
    row.distribution = UIStackViewDistributionFillEqually;
    row.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    for (NSString* k in keys) {
        UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:k forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15];
        [b addTarget:self action:@selector(onKeyRow:) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:b];
    }
    row.frame = CGRectMake(0, 0, self.view.bounds.size.width, 44);
    return row;
}

- (void)refreshStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        KernEngine* e = [KernEngine shared];
        self->_statusLabel.text = e.statusText;
        BOOL staged = [e guestStaged];
        BOOL running = e.state == KTermStateRunning || e.state == KTermStateBooting;
        self->_installButton.enabled = e.state != KTermStateDownloading && !staged;
        self->_bootButton.enabled = staged && !running;
        self->_stopButton.enabled = running;
        self->_termuxButton.enabled = running;
    });
}

// --- buttons ---

- (void)onInstall {
    [[KernEngine shared] installGuestWithCompletion:^(BOOL ok, NSString* error) {
        if (!ok) {
            UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Install failed"
                                                                       message:error
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        }
        [self refreshStatus];
    }];
}

- (void)onBoot {
    [[KernEngine shared] bootOnView:_metalView];
    [self refreshStatus];
}

- (void)onStop {
    [[KernEngine shared] stopGuest];
}

- (void)onTermux {
    _termuxButton.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        KernEngine* e = [KernEngine shared];
        if ([e termuxInstalled]) {
            [e launchTermuxWithCompletion:^(BOOL ok, NSString* error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_termuxButton.enabled = YES;
                    if (!ok) {
                        UIAlertController* a = [UIAlertController
                            alertControllerWithTitle:@"Could not open Termux"
                                            message:error
                                     preferredStyle:UIAlertControllerStyleAlert];
                        [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                                              style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:a animated:YES completion:nil];
                    }
                });
            }];
        } else {
            [e installTermuxWithCompletion:^(BOOL ok, NSString* error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_termuxButton.enabled = YES;
                    if (ok) {
                        [e launchTermuxWithCompletion:^(BOOL ok2, NSString* error2) {}];
                    } else {
                        UIAlertController* a = [UIAlertController
                            alertControllerWithTitle:@"Termux install failed"
                                            message:error
                                     preferredStyle:UIAlertControllerStyleAlert];
                        [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                                              style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:a animated:YES completion:nil];
                    }
                });
            }];
        }
    });
}

- (void)onKeyboard {
    if ([_hiddenField isFirstResponder]) {
        [_hiddenField resignFirstResponder];
    } else {
        [_hiddenField becomeFirstResponder];
    }
}

// --- key row ---

- (void)tapKey:(uint16_t)code {
    KernEngine* e = [KernEngine shared];
    if (_ctrlLatched) {
        [e sendKey:KEY_LEFTCTRL pressed:YES];
        [e sendKey:code pressed:YES];
        [e sendKey:code pressed:NO];
        [e sendKey:KEY_LEFTCTRL pressed:NO];
        _ctrlLatched = NO;
    } else {
        [e sendKey:code pressed:YES];
        [e sendKey:code pressed:NO];
    }
}

- (void)onKeyRow:(UIButton*)sender {
    NSString* k = sender.currentTitle;
    if ([k isEqualToString:@"Ctrl"]) {
        _ctrlLatched = !_ctrlLatched;
        sender.backgroundColor = _ctrlLatched ? [UIColor colorWithWhite:0.45 alpha:1.0] : nil;
        return;
    }
    if ([k isEqualToString:@"Esc"]) return [self tapKey:KEY_ESC];
    if ([k isEqualToString:@"Tab"]) return [self tapKey:KEY_TAB];
    if ([k isEqualToString:@"←"]) return [self tapKey:KEY_LEFT];
    if ([k isEqualToString:@"↑"]) return [self tapKey:KEY_UP];
    if ([k isEqualToString:@"↓"]) return [self tapKey:KEY_DOWN];
    if ([k isEqualToString:@"→"]) return [self tapKey:KEY_RIGHT];
    if ([k isEqualToString:@"Home"]) return [self tapKey:KEY_HOME];
    if ([k isEqualToString:@"End"]) return [self tapKey:KEY_END];
    if ([k isEqualToString:@"PgUp"]) return [self tapKey:KEY_PAGEUP];
    if ([k isEqualToString:@"PgDn"]) return [self tapKey:KEY_PAGEDOWN];
    if ([k isEqualToString:@"⏎"]) return [self tapKey:KEY_ENTER];
}

// --- typing through the hidden field ---

- (BOOL)textField:(UITextField*)textField
    shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString*)string {
    for (NSUInteger i = 0; i < string.length; i++) {
        [self typeChar:[string characterAtIndex:i]];
    }
    // Keep the field empty: it only carries keystrokes.
    textField.text = @"";
    return NO;
}

- (void)typeChar:(unichar)c {
    uint16_t code = 0;
    BOOL shift = NO;
    if (c >= 'a' && c <= 'z') {
        static const uint16_t map[26] = {KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G,
                                         KEY_H, KEY_I, KEY_J, KEY_K, KEY_L, KEY_M, KEY_N,
                                         KEY_O, KEY_P, KEY_Q, KEY_R, KEY_S, KEY_T, KEY_U,
                                         KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z};
        code = map[c - 'a'];
    } else if (c >= 'A' && c <= 'Z') {
        static const uint16_t map[26] = {KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G,
                                         KEY_H, KEY_I, KEY_J, KEY_K, KEY_L, KEY_M, KEY_N,
                                         KEY_O, KEY_P, KEY_Q, KEY_R, KEY_S, KEY_T, KEY_U,
                                         KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z};
        code = map[c - 'A'];
        shift = YES;
    } else if (c >= '1' && c <= '9') {
        static const uint16_t map[9] = {KEY_1, KEY_2, KEY_3, KEY_4, KEY_5,
                                        KEY_6, KEY_7, KEY_8, KEY_9};
        code = map[c - '1'];
    } else {
        switch (c) {
            case '0': code = KEY_0; break;
            case ' ': code = KEY_SPACE; break;
            case '\n': code = KEY_ENTER; break;
            case '-': code = KEY_MINUS; break;
            case '=': code = KEY_EQUAL; break;
            case '[': code = KEY_LEFTBRACE; break;
            case ']': code = KEY_RIGHTBRACE; break;
            case ';': code = KEY_SEMICOLON; break;
            case '\'': code = KEY_APOSTROPHE; break;
            case '`': code = KEY_GRAVE; break;
            case '\\': code = KEY_BACKSLASH; break;
            case ',': code = KEY_COMMA; break;
            case '.': code = KEY_DOT; break;
            case '/': code = KEY_SLASH; break;
            case '!': code = KEY_1; shift = YES; break;
            case '@': code = KEY_2; shift = YES; break;
            case '#': code = KEY_3; shift = YES; break;
            case '$': code = KEY_4; shift = YES; break;
            case '%': code = KEY_5; shift = YES; break;
            case '^': code = KEY_6; shift = YES; break;
            case '&': code = KEY_7; shift = YES; break;
            case '*': code = KEY_8; shift = YES; break;
            case '(': code = KEY_9; shift = YES; break;
            case ')': code = KEY_0; shift = YES; break;
            case '_': code = KEY_MINUS; shift = YES; break;
            case '+': code = KEY_EQUAL; shift = YES; break;
            case '{': code = KEY_LEFTBRACE; shift = YES; break;
            case '}': code = KEY_RIGHTBRACE; shift = YES; break;
            case ':': code = KEY_SEMICOLON; shift = YES; break;
            case '"': code = KEY_APOSTROPHE; shift = YES; break;
            case '~': code = KEY_GRAVE; shift = YES; break;
            case '|': code = KEY_BACKSLASH; shift = YES; break;
            case '<': code = KEY_COMMA; shift = YES; break;
            case '>': code = KEY_DOT; shift = YES; break;
            case '?': code = KEY_SLASH; shift = YES; break;
            default: return;
        }
    }
    KernEngine* e = [KernEngine shared];
    if (shift) [e sendKey:KEY_LEFTSHIFT pressed:YES];
    if (_ctrlLatched) {
        [e sendKey:KEY_LEFTCTRL pressed:YES];
        [e sendKey:code pressed:YES];
        [e sendKey:code pressed:NO];
        [e sendKey:KEY_LEFTCTRL pressed:NO];
        _ctrlLatched = NO;
    } else {
        [e sendKey:code pressed:YES];
        [e sendKey:code pressed:NO];
    }
    if (shift) [e sendKey:KEY_LEFTSHIFT pressed:NO];
}

// --- touch: forward to the guest's touchscreen (0..32767 both axes) ---

- (uint32_t)slotForTouch:(UITouch*)touch create:(BOOL)create {
    NSValue* key = [NSValue valueWithNonretainedObject:touch];
    NSNumber* slot = _touchSlots[key];
    if (slot) return slot.unsignedIntValue;
    if (!create || _nextSlot >= 10) return UINT32_MAX;
    uint32_t s = _nextSlot++;
    _touchSlots[key] = @(s);
    return s;
}

- (void)forwardTouch:(UITouch*)touch pressed:(BOOL)pressed {
    uint32_t slot = [self slotForTouch:touch create:pressed];
    if (slot == UINT32_MAX) return;
    CGPoint p = [touch locationInView:_metalView];
    uint32_t x = (uint32_t)(p.x / _metalView.bounds.size.width * 32767.0);
    uint32_t y = (uint32_t)(p.y / _metalView.bounds.size.height * 32767.0);
    if (x > 32767) x = 32767;
    if (y > 32767) y = 32767;
    [[KernEngine shared] sendTouchSlot:slot x:x y:y pressed:pressed];
    if (!pressed) {
        [_touchSlots removeObjectForKey:[NSValue valueWithNonretainedObject:touch]];
    }
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) [self forwardTouch:t pressed:YES];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) [self forwardTouch:t pressed:YES];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) [self forwardTouch:t pressed:NO];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) {
        uint32_t slot = [self slotForTouch:t create:NO];
        if (slot != UINT32_MAX) {
            [[KernEngine shared] cancelTouchSlot:slot];
            [_touchSlots removeObjectForKey:[NSValue valueWithNonretainedObject:t]];
        }
    }
}

@end
