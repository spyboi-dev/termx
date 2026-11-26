// TXGhosttyView implementation. See the header.
//
// The one Ghostty app per view: ghostty_init runs once per process
// (dispatch_once), the config is a default one, and the runtime
// callbacks bounce to the main queue. The surface is created on the
// first layout with real bounds, so Ghostty sizes its grid from the
// view; guest output before then is buffered and flushed once the
// surface is sized.
#import "TXGhosttyView.h"

#import <QuartzCore/QuartzCore.h>
#import <string.h>

#import "TXLog.h"
#import "TXTheme.h"

@interface TXGhosttyView ()
- (void)tx_tick;
- (void)tx_requestFrame;
- (void)tx_updateSublayerFrames;
- (void)tx_setViewportColumns:(uint16_t)cols rows:(uint16_t)rows widthPx:(uint32_t)w heightPx:(uint32_t)h;
- (void)tx_completeClipboardRead:(void *)request;
- (void)tx_ringBell;
- (void)tx_handlePinch:(UIPinchGestureRecognizer *)gesture;
@end

// Weak proxy for the display link: a CADisplayLink retains its
// target, so targeting the view directly would be a retain cycle
// and dealloc (which frees the surface) would never run. The proxy
// holds the view weakly, so the link never keeps it alive.
@interface TXGhosttyTickProxy : NSObject
@property (nonatomic, weak) TXGhosttyView *view;
- (void)tick:(CADisplayLink *)link;
@end

@implementation TXGhosttyTickProxy
- (void)tick:(CADisplayLink *)link {
    (void)link;
    [self.view tx_tick];
}
@end

// --- Ghostty C callbacks (file-static). userdata is the view,
// unretained: the view outlives the surface, and every callback
// bounces to the main queue before touching it. ---

// Bytes the terminal wants to send to the guest (typed text, key
// sequences, paste). Ghostty calls this from its own threads.
static void TXGhosttyReceiveBuffer(void *userdata, const uint8_t *bytes, size_t len) {
    TXGhosttyView *view = (__bridge TXGhosttyView *)userdata;
    if (!view || !bytes || len == 0) return;
    NSData *data = [NSData dataWithBytes:bytes length:len];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.onOutput) view.onOutput(data);
    });
}

// The viewport Ghostty computed from the view size and font: the
// grid size the guest's programs lay out for.
static void TXGhosttyReceiveResize(void *userdata, uint16_t columns, uint16_t rows,
                                   uint32_t widthPx, uint32_t heightPx) {
    TXGhosttyView *view = (__bridge TXGhosttyView *)userdata;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view tx_setViewportColumns:columns rows:rows widthPx:widthPx heightPx:heightPx];
    });
}

// Ghostty has work (an event in its mailbox): tick the app on the
// main thread so it is drained. A wakeup can also mean a new frame
// is owed (output parsed, cursor blink), so the tick draws.
static void TXGhosttyWakeup(void *userdata) {
    TXGhosttyView *view = (__bridge TXGhosttyView *)userdata;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view tx_requestFrame];
        [view tx_tick];
    });
}

// Actions from the terminal (title, bell, ...). The callback gets
// no userdata, so the view is reached through the app's userdata,
// which is the runtime config's userdata (this view).
static bool TXGhosttyAction(ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
    (void)target;
    if (action.tag != GHOSTTY_ACTION_RING_BELL) return false;
    TXGhosttyView *view = (__bridge TXGhosttyView *)ghostty_app_userdata(app);
    if (!view) return true;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view tx_ringBell];
    });
    return true;
}

// Ghostty wants to read the clipboard (a paste keybinding, OSC 52
// read, ...). The read is async: return STARTED and complete it on
// the main thread from the pasteboard.
static ghostty_clipboard_read_result_e TXGhosttyReadClipboard(
    void *userdata, ghostty_clipboard_e clipboard, void *request,
    const char *const *mimeTypes, size_t mimeTypesLen, bool flag) {
    (void)clipboard; (void)mimeTypes; (void)mimeTypesLen; (void)flag;
    TXGhosttyView *view = (__bridge TXGhosttyView *)userdata;
    if (!view) return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view tx_completeClipboardRead:request];
    });
    return GHOSTTY_CLIPBOARD_READ_STARTED;
}

// Ghostty wants confirmation before reading the clipboard (a
// permission prompt for OSC 52 / Kitty reads). A personal terminal
// does not prompt: auto-allow with the pasteboard contents, the
// same completion as a plain read.
static void TXGhosttyConfirmReadClipboard(
    void *userdata, const ghostty_clipboard_confirm_s *confirm,
    void *request, ghostty_clipboard_request_e kind) {
    (void)confirm; (void)kind;
    TXGhosttyView *view = (__bridge TXGhosttyView *)userdata;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view tx_completeClipboardRead:request];
    });
}

// Ghostty wants to write the clipboard (a copy). The contents
// buffer is only valid for this call, so the text is copied
// synchronously and the pasteboard is set on the main thread.
static void TXGhosttyWriteClipboard(
    void *userdata, ghostty_clipboard_e clipboard,
    const ghostty_clipboard_content_s *contents, size_t contentsLen, bool flag) {
    (void)userdata; (void)clipboard; (void)flag;
    if (!contents || contentsLen == 0) return;
    NSString *text = nil;
    for (size_t i = 0; i < contentsLen; i++) {
        const char *mime = contents[i].mime;
        if (mime && strcmp(mime, "text/plain") != 0) continue;
        if (!contents[i].data) continue;
        text = [[NSString alloc] initWithBytes:contents[i].data
                                         length:(NSUInteger)contents[i].len
                                       encoding:NSUTF8StringEncoding];
        if (text) break;
    }
    if (!text && contents[0].data) {
        text = [[NSString alloc] initWithBytes:contents[0].data
                                         length:(NSUInteger)contents[0].len
                                       encoding:NSUTF8StringEncoding];
    }
    if (!text) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = text;
    });
}

@implementation TXGhosttyView {
    ghostty_app_t _app;
    ghostty_config_t _config;
    ghostty_surface_t _surface;
    CADisplayLink *_tickLink;
    TXGhosttyTickProxy *_tickProxy;
    NSMutableData *_pendingOutput;
    BOOL _surfaceReady;
    BOOL _focused;
    BOOL _needsFrame; // a frame is owed (wakeup, output, resize, focus)
    CGSize _lastSizePx;
    CGFloat _pinchLastScale; // pinch-zoom: scale at the last step taken
    CGFloat _pinchFontSize;  // pinch-zoom: font size tracked on this side
}

@synthesize viewportColumns = _viewportColumns;
@synthesize viewportRows = _viewportRows;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor blackColor];
    self.opaque = YES;
    // Focused while on screen: the controller clears it when the
    // terminal screen goes away.
    _focused = YES;
    _pendingOutput = [NSMutableData data];
    _lastSizePx = CGSizeZero;
    _pinchLastScale = 1.0;
    _pinchFontSize = TXTermFontSize();
    [self tx_createApp];
    // Pinch to zoom the font, Termux's way: a plain two-finger
    // pinch, 2 pt per 0.9/1.1 threshold crossing. The exit pan is
    // one finger only, so it never sees the pinch.
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(tx_handlePinch:)];
    [self addGestureRecognizer:pinch];
    return self;
}

- (void)tx_createApp {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        static char *argv[] = { "TermX", NULL };
        ghostty_init(1, argv);
    });
    _config = ghostty_config_new();
    if (!_config) {
        TXLogEngine(@"Ghostty: config creation failed");
        return;
    }
    // Pure black background: Ghostty's default theme is One Dark
    // (#282C34), and the view's own black is hidden behind the
    // Metal layer Ghostty renders into, so the view colour alone
    // never shows. The C API has no config setter; the reference
    // wrapper writes a config file and loads it, so this does the
    // same: one line, loaded before finalize. The config lives in
    // Documents (not Caches) so it is visible in the Files app
    // alongside the guest data and logs; the stale Caches copy from
    // before is removed so there is one source of truth. One live
    // copy only: this file IS the config Ghostty reads, and the app
    // never keeps a second copy. If the user edits it in Files,
    // their other lines survive: only the background line is owned
    // here (forced to black, the required background), and every
    // other line is kept as-is.
    NSString *configDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *configPath = [configDir stringByAppendingPathComponent:@"ghostty-config.conf"];
    NSString *oldCachesPath = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject]
        stringByAppendingPathComponent:@"ghostty-config.conf"];
    [[NSFileManager defaultManager] removeItemAtPath:oldCachesPath error:nil];
    NSString *existing = [NSString stringWithContentsOfFile:configPath
                                                    encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray<NSString *> *keptLines = [NSMutableArray array];
    for (NSString *line in [existing componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        // Drop only an existing "background = ..." line (the app
        // owns the background); keep every other line the user may
        // have added in Files. "background-opacity" and friends are
        // not the background line: after "background" the next
        // non-space character must be "=".
        BOOL isBackgroundLine = NO;
        if ([trimmed hasPrefix:@"background"]) {
            NSString *rest = [[trimmed substringFromIndex:@"background".length]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            isBackgroundLine = [rest hasPrefix:@"="];
        }
        if (!isBackgroundLine && trimmed.length) [keptLines addObject:line];
    }
    [keptLines insertObject:@"background = #000000" atIndex:0];
    NSString *configContent = [[keptLines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    NSError *writeError = nil;
    if (![configContent writeToFile:configPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        TXLogEngine(@"Ghostty: background config write failed: %@", writeError);
    } else {
        ghostty_config_load_file(_config, [configPath UTF8String]);
    }
    ghostty_config_finalize(_config);
    ghostty_runtime_config_s rt;
    memset(&rt, 0, sizeof(rt));
    rt.userdata = (__bridge void *)self;
    rt.supports_selection_clipboard = true;
    rt.wakeup_cb = TXGhosttyWakeup;
    rt.action_cb = TXGhosttyAction;
    rt.read_clipboard_cb = TXGhosttyReadClipboard;
    rt.confirm_read_clipboard_cb = TXGhosttyConfirmReadClipboard;
    rt.write_clipboard_cb = TXGhosttyWriteClipboard;
    rt.close_surface_cb = NULL;
    _app = ghostty_app_new(&rt, _config);
    if (!_app) {
        TXLogEngine(@"Ghostty: app creation failed");
        return;
    }
    // Tick the app on the display link while this view is in a
    // window (paused in didMoveToWindow when it leaves, so a
    // backgrounded terminal does not tick at 60 Hz).
    _tickProxy = [[TXGhosttyTickProxy alloc] init];
    _tickProxy.view = self;
    _tickLink = [CADisplayLink displayLinkWithTarget:_tickProxy selector:@selector(tick:)];
    [_tickLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    _tickLink.paused = YES;
}

- (void)tx_createSurface {
    if (!_app || _surface) return;
    ghostty_surface_config_s cfg = ghostty_surface_config_new();
    cfg.platform_tag = GHOSTTY_PLATFORM_IOS;
    cfg.platform.ios.uiview = (__bridge void *)self;
    cfg.userdata = (__bridge void *)self;
    cfg.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED;
    cfg.receive_userdata = (__bridge void *)self;
    cfg.receive_buffer = TXGhosttyReceiveBuffer;
    cfg.receive_resize = TXGhosttyReceiveResize;
    cfg.scale_factor = (double)[UIScreen mainScreen].scale;
    cfg.font_size = (float)TXTermFontSize();
    cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW;
    _surface = ghostty_surface_new(_app, &cfg);
    if (_surface) {
        ghostty_surface_set_focus(_surface, _focused);
        // A surface is born occluded and skips every draw until it
        // hears otherwise: stamp visibility now, so the first frame
        // draws. (didMoveToWindow re-stamps it on window changes.)
        ghostty_surface_set_occlusion(_surface, self.window != nil);
        _needsFrame = YES;
    } else {
        TXLogEngine(@"Ghostty: surface creation failed");
    }
}

// Push the view size (in physical pixels) into the surface. The
// resize callback reports the grid Ghostty computed from it.
- (void)tx_updateSize {
    if (!_surface) return;
    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize size = self.bounds.size;
    uint32_t wPx = (uint32_t)lround(size.width * scale);
    uint32_t hPx = (uint32_t)lround(size.height * scale);
    if (wPx == 0 || hPx == 0) return;
    if (_surfaceReady && _lastSizePx.width == wPx && _lastSizePx.height == hPx) return;
    _lastSizePx = CGSizeMake(wPx, hPx);
    ghostty_surface_set_content_scale(_surface, (double)scale, (double)scale);
    ghostty_surface_set_size(_surface, wPx, hPx);
    _needsFrame = YES;
    if (!_surfaceReady) {
        _surfaceReady = YES;
        [self tx_flushPendingOutput];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    if (!_surface) [self tx_createSurface];
    [self tx_updateSize];
    [self tx_updateSublayerFrames];
}

// Ghostty renders into a Metal layer it adds as a sublayer of this
// view, but it never sizes that layer: it is born 0x0, so the render
// size (read from the layer's bounds) is 0x0 and every draw renders
// into nothing — the blank terminal, even with refresh/draw called.
// The host must size the engine layer to the view's bounds, like
// libghostty-spm's updateSublayerFrames does. Sublayers owned by
// UIKit (a subview's layer, whose delegate is the UIView) are left
// alone.
- (void)tx_updateSublayerFrames {
    CGFloat scale = [UIScreen mainScreen].scale;
    self.layer.contentsScale = scale;
    self.layer.masksToBounds = YES;
    CGRect frame = self.bounds;
    for (CALayer *sublayer in self.layer.sublayers) {
        if ([sublayer.delegate isKindOfClass:[UIView class]]) continue;
        sublayer.frame = frame;
        sublayer.contentsScale = scale;
    }
    // The layer was 0x0 until now, so the surface size Ghostty
    // derived from it was 0x0: a frame is owed.
    _needsFrame = YES;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    BOOL inWindow = (self.window != nil);
    _tickLink.paused = !inWindow;
    if (_surface) {
        ghostty_surface_set_focus(_surface, inWindow && _focused);
        ghostty_surface_set_occlusion(_surface, inWindow);
    }
    if (inWindow) {
        [self tx_updateSublayerFrames];
        _needsFrame = YES;
        [self tx_tick];
    }
}

- (void)tx_requestFrame {
    _needsFrame = YES;
}

- (void)tx_tick {
    if (!_app) return;
    ghostty_app_tick(_app);
    // The app tick only drains the mailbox: it never presents a
    // frame. The host must ask the surface to render, or the grid
    // updates in memory and the view stays black — the blank
    // terminal bug. Draw only when a frame is owed (wakeup, output,
    // resize, focus), so an idle terminal costs no draws.
    if (_surface && _needsFrame) {
        _needsFrame = NO;
        ghostty_surface_refresh(_surface);
        ghostty_surface_draw(_surface);
    }
}

- (void)tx_setViewportColumns:(uint16_t)cols rows:(uint16_t)rows
                       widthPx:(uint32_t)w heightPx:(uint32_t)h {
    if (cols == _viewportColumns && rows == _viewportRows) return;
    _viewportColumns = cols;
    _viewportRows = rows;
    TXLogEngine(@"Ghostty viewport: %u cols x %u rows (%u x %u px)",
                (unsigned)cols, (unsigned)rows, (unsigned)w, (unsigned)h);
}

- (void)tx_flushPendingOutput {
    if (!_surface || !_pendingOutput.length) return;
    NSData *data = [_pendingOutput copy];
    [_pendingOutput setLength:0];
    // Replay, not live: everything buffered here arrived before
    // the surface was sized, so it is history. Answering its
    // queries live would send a second set of CPR/DA replies to
    // a guest whose programs have moved on, and they land in the
    // shell as typed input.
    ghostty_surface_write_buffer_replay(_surface, (const uint8_t *)data.bytes, (uintptr_t)data.length);
    _needsFrame = YES;
}

- (void)tx_completeClipboardRead:(void *)request {
    if (!_surface) return;
    NSString *text = [UIPasteboard generalPasteboard].string ?: @"";
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    ghostty_clipboard_content_s content;
    memset(&content, 0, sizeof(content));
    content.mime = "text/plain";
    content.data = (const char *)data.bytes;
    content.len = (size_t)data.length;
    ghostty_clipboard_complete_s complete;
    memset(&complete, 0, sizeof(complete));
    complete.contents = &content;
    complete.contents_len = 1;
    complete.available = NULL;
    complete.available_len = 0;
    complete.confirmed = true;
    complete.remember = false;
    ghostty_surface_complete_clipboard_request(_surface, &complete, request);
}

- (void)tx_ringBell {
    if (self.onBell) self.onBell();
}

#pragma mark - Public API

- (void)feedGuestOutput:(NSData *)data {
    if (!data.length) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self feedGuestOutput:data]; });
        return;
    }
    if (!_surface || !_surfaceReady) {
        // Buffer until the surface is created and sized; cap it so
        // a long boot log fed before the first layout cannot grow
        // it without bound (keep the most recent 256 KiB).
        [_pendingOutput appendData:data];
        const NSUInteger cap = 256 * 1024;
        if (_pendingOutput.length > cap) {
            [_pendingOutput replaceBytesInRange:NSMakeRange(0, _pendingOutput.length - cap)
                                      withBytes:NULL length:0];
        }
        return;
    }
    ghostty_surface_write_buffer(_surface, (const uint8_t *)data.bytes, (uintptr_t)data.length);
    _needsFrame = YES;
}

// History into the terminal: same buffering as feedGuestOutput,
// but parsed with write_buffer_replay, so the replies the bytes
// would trigger (CPR/DA/OSC queries, title reports) are dropped
// instead of reaching the guest as a second answer.
- (void)feedGuestOutputReplay:(NSData *)data {
    if (!data.length) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self feedGuestOutputReplay:data]; });
        return;
    }
    if (!_surface || !_surfaceReady) {
        [_pendingOutput appendData:data];
        const NSUInteger cap = 256 * 1024;
        if (_pendingOutput.length > cap) {
            [_pendingOutput replaceBytesInRange:NSMakeRange(0, _pendingOutput.length - cap)
                                      withBytes:NULL length:0];
        }
        return;
    }
    ghostty_surface_write_buffer_replay(_surface, (const uint8_t *)data.bytes, (uintptr_t)data.length);
    _needsFrame = YES;
}

- (void)sendText:(NSString *)text {
    if (!text.length) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self sendText:text]; });
        return;
    }
    if (!_surface) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    ghostty_surface_text(_surface, (const char *)data.bytes, (uintptr_t)data.length);
}

// Typed text on the key path, like libghostty-spm's sendTypedText:
// a key event with keycode 0xFFFF (outside the keycode table, so
// Ghostty resolves it to unidentified) and the text, so the
// encoder writes the characters as keystrokes. Text with newlines
// goes to the text path instead: a shell must not read those lines
// as Return presses.
- (void)sendTypedText:(NSString *)text mods:(ghostty_input_mods_e)mods {
    if (!text.length) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self sendTypedText:text mods:mods]; });
        return;
    }
    if (!_surface) return;
    if ([text rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound) {
        [self sendText:text];
        return;
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    // First Unicode scalar, for the kitty encoder (which keys its
    // event off unshifted_codepoint). Surrogate pairs combine.
    uint32_t codepoint = 0;
    unichar c0 = [text characterAtIndex:0];
    if (c0 >= 0xD800 && c0 <= 0xDBFF && text.length > 1) {
        unichar c1 = [text characterAtIndex:1];
        if (c1 >= 0xDC00 && c1 <= 0xDFFF) {
            codepoint = 0x10000 + ((uint32_t)(c0 - 0xD800) << 10) + (uint32_t)(c1 - 0xDC00);
        } else {
            codepoint = c0;
        }
    } else {
        codepoint = c0;
    }
    ghostty_input_key_s k;
    memset(&k, 0, sizeof(k));
    k.action = GHOSTTY_ACTION_PRESS;
    k.mods = mods;
    k.consumed_mods = 0;
    k.keycode = 0xFFFF;
    k.text = (const char *)data.bytes;
    k.unshifted_codepoint = codepoint;
    k.composing = false;
    ghostty_surface_key(_surface, k);
}

// Ghostty's key event takes the platform-native keycode, and
// libghostty's lookup uses macOS AppKit keycodes on iOS too, so a
// Ghostty key enum must be translated to the AppKit keycode for
// the same physical key — the way the reference wrapper does it
// (TerminalHardwareKeyRouter.appKitKeyCode). Sending the enum
// value itself as the keycode is wrong: BACKSPACE (53) lands on
// AppKit Escape (0x35), ENTER (58) on AppKit Alt, and both
// silently do nothing. This is the reference's appKitMap
// (the mac column of libghostty's src/input/keycodes.zig),
// inverted. Keys with no AppKit equivalent (Help, Fn,
// NumpadClear, IntlBackslash, IntlYen, IntlRo, media and
// clipboard keys) get the sentinel 0x10000 — outside the 8-bit
// AppKit range, where plain 0 would collide with AppKit A — and
// are not sent at all.
static uint32_t TXAppKitKeyCodeForGhosttyKey(ghostty_input_key_e key) {
    switch (key) {
        case GHOSTTY_KEY_A: return 0x00;
        case GHOSTTY_KEY_S: return 0x01;
        case GHOSTTY_KEY_D: return 0x02;
        case GHOSTTY_KEY_F: return 0x03;
        case GHOSTTY_KEY_H: return 0x04;
        case GHOSTTY_KEY_G: return 0x05;
        case GHOSTTY_KEY_Z: return 0x06;
        case GHOSTTY_KEY_X: return 0x07;
        case GHOSTTY_KEY_C: return 0x08;
        case GHOSTTY_KEY_V: return 0x09;
        case GHOSTTY_KEY_B: return 0x0B;
        case GHOSTTY_KEY_Q: return 0x0C;
        case GHOSTTY_KEY_W: return 0x0D;
        case GHOSTTY_KEY_E: return 0x0E;
        case GHOSTTY_KEY_R: return 0x0F;
        case GHOSTTY_KEY_Y: return 0x10;
        case GHOSTTY_KEY_T: return 0x11;
        case GHOSTTY_KEY_DIGIT_1: return 0x12;
        case GHOSTTY_KEY_DIGIT_2: return 0x13;
        case GHOSTTY_KEY_DIGIT_3: return 0x14;
        case GHOSTTY_KEY_DIGIT_4: return 0x15;
        case GHOSTTY_KEY_DIGIT_6: return 0x16;
        case GHOSTTY_KEY_DIGIT_5: return 0x17;
        case GHOSTTY_KEY_EQUAL: return 0x18;
        case GHOSTTY_KEY_DIGIT_9: return 0x19;
        case GHOSTTY_KEY_DIGIT_7: return 0x1A;
        case GHOSTTY_KEY_MINUS: return 0x1B;
        case GHOSTTY_KEY_DIGIT_8: return 0x1C;
        case GHOSTTY_KEY_DIGIT_0: return 0x1D;
        case GHOSTTY_KEY_BRACKET_RIGHT: return 0x1E;
        case GHOSTTY_KEY_O: return 0x1F;
        case GHOSTTY_KEY_U: return 0x20;
        case GHOSTTY_KEY_BRACKET_LEFT: return 0x21;
        case GHOSTTY_KEY_I: return 0x22;
        case GHOSTTY_KEY_P: return 0x23;
        case GHOSTTY_KEY_ENTER: return 0x24;
        case GHOSTTY_KEY_L: return 0x25;
        case GHOSTTY_KEY_J: return 0x26;
        case GHOSTTY_KEY_QUOTE: return 0x27;
        case GHOSTTY_KEY_K: return 0x28;
        case GHOSTTY_KEY_SEMICOLON: return 0x29;
        case GHOSTTY_KEY_BACKSLASH: return 0x2A;
        case GHOSTTY_KEY_COMMA: return 0x2B;
        case GHOSTTY_KEY_SLASH: return 0x2C;
        case GHOSTTY_KEY_N: return 0x2D;
        case GHOSTTY_KEY_M: return 0x2E;
        case GHOSTTY_KEY_PERIOD: return 0x2F;
        case GHOSTTY_KEY_TAB: return 0x30;
        case GHOSTTY_KEY_SPACE: return 0x31;
        case GHOSTTY_KEY_BACKQUOTE: return 0x32;
        case GHOSTTY_KEY_BACKSPACE: return 0x33;
        case GHOSTTY_KEY_ESCAPE: return 0x35;
        case GHOSTTY_KEY_META_RIGHT: return 0x36;
        case GHOSTTY_KEY_META_LEFT: return 0x37;
        case GHOSTTY_KEY_SHIFT_LEFT: return 0x38;
        case GHOSTTY_KEY_CAPS_LOCK: return 0x39;
        case GHOSTTY_KEY_ALT_LEFT: return 0x3A;
        case GHOSTTY_KEY_CONTROL_LEFT: return 0x3B;
        case GHOSTTY_KEY_SHIFT_RIGHT: return 0x3C;
        case GHOSTTY_KEY_ALT_RIGHT: return 0x3D;
        case GHOSTTY_KEY_CONTROL_RIGHT: return 0x3E;
        case GHOSTTY_KEY_F17: return 0x40;
        case GHOSTTY_KEY_NUMPAD_DECIMAL: return 0x41;
        case GHOSTTY_KEY_NUMPAD_MULTIPLY: return 0x43;
        case GHOSTTY_KEY_NUMPAD_ADD: return 0x45;
        case GHOSTTY_KEY_NUM_LOCK: return 0x47;
        case GHOSTTY_KEY_AUDIO_VOLUME_UP: return 0x48;
        case GHOSTTY_KEY_AUDIO_VOLUME_DOWN: return 0x49;
        case GHOSTTY_KEY_AUDIO_VOLUME_MUTE: return 0x4A;
        case GHOSTTY_KEY_NUMPAD_DIVIDE: return 0x4B;
        case GHOSTTY_KEY_NUMPAD_ENTER: return 0x4C;
        case GHOSTTY_KEY_NUMPAD_SUBTRACT: return 0x4E;
        case GHOSTTY_KEY_F18: return 0x4F;
        case GHOSTTY_KEY_F19: return 0x50;
        case GHOSTTY_KEY_NUMPAD_EQUAL: return 0x51;
        case GHOSTTY_KEY_NUMPAD_0: return 0x52;
        case GHOSTTY_KEY_NUMPAD_1: return 0x53;
        case GHOSTTY_KEY_NUMPAD_2: return 0x54;
        case GHOSTTY_KEY_NUMPAD_3: return 0x55;
        case GHOSTTY_KEY_NUMPAD_4: return 0x56;
        case GHOSTTY_KEY_NUMPAD_5: return 0x57;
        case GHOSTTY_KEY_NUMPAD_6: return 0x58;
        case GHOSTTY_KEY_NUMPAD_7: return 0x59;
        case GHOSTTY_KEY_F20: return 0x5A;
        case GHOSTTY_KEY_NUMPAD_8: return 0x5B;
        case GHOSTTY_KEY_NUMPAD_9: return 0x5C;
        case GHOSTTY_KEY_F5: return 0x60;
        case GHOSTTY_KEY_F6: return 0x61;
        case GHOSTTY_KEY_F7: return 0x62;
        case GHOSTTY_KEY_F3: return 0x63;
        case GHOSTTY_KEY_F8: return 0x64;
        case GHOSTTY_KEY_F9: return 0x65;
        case GHOSTTY_KEY_F11: return 0x67;
        case GHOSTTY_KEY_F13: return 0x69;
        case GHOSTTY_KEY_F16: return 0x6A;
        case GHOSTTY_KEY_F14: return 0x6B;
        case GHOSTTY_KEY_F10: return 0x6D;
        case GHOSTTY_KEY_CONTEXT_MENU: return 0x6E;
        case GHOSTTY_KEY_F12: return 0x6F;
        case GHOSTTY_KEY_F15: return 0x71;
        case GHOSTTY_KEY_INSERT: return 0x72;
        case GHOSTTY_KEY_HOME: return 0x73;
        case GHOSTTY_KEY_PAGE_UP: return 0x74;
        case GHOSTTY_KEY_DELETE: return 0x75;
        case GHOSTTY_KEY_F4: return 0x76;
        case GHOSTTY_KEY_END: return 0x77;
        case GHOSTTY_KEY_F2: return 0x78;
        case GHOSTTY_KEY_PAGE_DOWN: return 0x79;
        case GHOSTTY_KEY_F1: return 0x7A;
        case GHOSTTY_KEY_ARROW_LEFT: return 0x7B;
        case GHOSTTY_KEY_ARROW_RIGHT: return 0x7C;
        case GHOSTTY_KEY_ARROW_DOWN: return 0x7D;
        case GHOSTTY_KEY_ARROW_UP: return 0x7E;
        default: return 0x10000;
    }
}

// The codepoint the key types with no modifier at all, on a US
// layout — what the kitty encoder reports, and what the legacy
// encoder derives Ctrl bytes from (the reference's
// TerminalKeyPress.unshiftedCodepoint). Zero for a key that types
// nothing. A..Z and the digits are consecutive in the Ghostty
// enum, like the Ctrl+letter code in the controller already
// assumes; punctuation is by name.
static uint32_t TXUnshiftedCodepointForGhosttyKey(ghostty_input_key_e key) {
    if (key >= GHOSTTY_KEY_A && key <= GHOSTTY_KEY_Z)
        return (uint32_t)('a' + (key - GHOSTTY_KEY_A));
    if (key >= GHOSTTY_KEY_DIGIT_0 && key <= GHOSTTY_KEY_DIGIT_9)
        return (uint32_t)('0' + (key - GHOSTTY_KEY_DIGIT_0));
    switch (key) {
        case GHOSTTY_KEY_MINUS: return '-';
        case GHOSTTY_KEY_EQUAL: return '=';
        case GHOSTTY_KEY_BRACKET_LEFT: return '[';
        case GHOSTTY_KEY_BRACKET_RIGHT: return ']';
        case GHOSTTY_KEY_BACKSLASH: return '\\';
        case GHOSTTY_KEY_SEMICOLON: return ';';
        case GHOSTTY_KEY_QUOTE: return '\'';
        case GHOSTTY_KEY_COMMA: return ',';
        case GHOSTTY_KEY_PERIOD: return '.';
        case GHOSTTY_KEY_SLASH: return '/';
        case GHOSTTY_KEY_BACKQUOTE: return '`';
        case GHOSTTY_KEY_SPACE: return ' ';
        default: return 0;
    }
}

- (void)sendKey:(ghostty_input_key_e)key mods:(ghostty_input_mods_e)mods {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self sendKey:key mods:mods]; });
        return;
    }
    if (!_surface) return;
    // No AppKit keycode for this key: libghostty would resolve it
    // to unidentified, so do not send it at all (the reference's
    // hasPlatformKeycode guard).
    uint32_t keycode = TXAppKitKeyCodeForGhosttyKey(key);
    if (keycode == 0x10000) return;
    ghostty_input_key_s k;
    memset(&k, 0, sizeof(k));
    k.mods = mods;
    k.consumed_mods = 0;
    k.keycode = keycode;
    k.text = NULL;
    k.unshifted_codepoint = TXUnshiftedCodepointForGhosttyKey(key);
    k.composing = false;
    // Press then release, like the reference: the release follows
    // so a program on the kitty keyboard protocol never sees a key
    // held down; in the legacy encoding a release encodes nothing.
    k.action = GHOSTTY_ACTION_PRESS;
    ghostty_surface_key(_surface, k);
    k.action = GHOSTTY_ACTION_RELEASE;
    ghostty_surface_key(_surface, k);
}

// Pinch to zoom the font size, Termux's way (TerminalView.onScale):
// the recognizer's scale is accumulated, and past a 0.9/1.1
// threshold the font steps 2 pt, so a slow pinch still moves and a
// fast one steps more than once. Each step goes through Ghostty's
// increase/decrease_font_size binding action; Ghostty re-lays out
// the grid and reflows the displayed content to the new width, so
// it stays inside the edges instead of running past them. The size
// is tracked on this side (the C API cannot report it) and
// persisted, so a new surface starts at the zoomed size. Clamped
// to Termux's range.
- (void)tx_handlePinch:(UIPinchGestureRecognizer *)gesture {
    if (!_surface) return;
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            _pinchLastScale = gesture.scale;
            _pinchFontSize = TXTermFontSize();
            break;
        case UIGestureRecognizerStateChanged: {
            // One threshold crossing per step; a fast pinch can
            // cross several in one move, so loop until the ratio
            // is back inside the band.
            while (YES) {
                CGFloat ratio = gesture.scale / _pinchLastScale;
                BOOL growing = ratio >= TXConfigPinchZoomInThreshold;
                BOOL shrinking = ratio <= TXConfigPinchZoomOutThreshold;
                if (!growing && !shrinking) break;
                CGFloat next = _pinchFontSize + (growing ? TXConfigPinchZoomStepPt : -TXConfigPinchZoomStepPt);
                if (next < TXConfigTermFontSizeMin || next > TXConfigTermFontSizeMax) break;
                const char *action = growing ? "increase_font_size:2" : "decrease_font_size:2";
                if (!ghostty_surface_binding_action(_surface, action, strlen(action))) break;
                _pinchFontSize = next;
                TXSetTermFontSize(_pinchFontSize);
                _pinchLastScale *= growing ? TXConfigPinchZoomInThreshold : TXConfigPinchZoomOutThreshold;
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            _pinchLastScale = 1.0;
            break;
        default:
            break;
    }
}

// Set the font size absolutely (Settings stepper): one
// set_font_size binding action with the target size, clamped to
// Termux's range and persisted, like the pinch zoom. Ghostty
// re-lays out the grid and reflows the content to the new width.
- (void)setFontSize:(CGFloat)size {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setFontSize:size]; });
        return;
    }
    if (!_surface) return;
    if (size < TXConfigTermFontSizeMin) size = TXConfigTermFontSizeMin;
    if (size > TXConfigTermFontSizeMax) size = TXConfigTermFontSizeMax;
    char action[64];
    snprintf(action, sizeof(action), "set_font_size:%.0f", (double)size);
    if (ghostty_surface_binding_action(_surface, action, strlen(action))) {
        TXSetTermFontSize(size);
    }
}

- (void)pasteText:(NSString *)text {
    if (!text.length) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self pasteText:text]; });
        return;
    }
    if (!_surface) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    ghostty_surface_paste_text(_surface, (const char *)data.bytes, (uintptr_t)data.length);
}

- (void)setFocused:(BOOL)focused {
    _focused = focused;
    if (_surface) ghostty_surface_set_focus(_surface, focused);
    _needsFrame = YES;
}

- (NSString *)visibleScreenText {
    if (!_surface || _viewportColumns == 0 || _viewportRows == 0) return @"";
    ghostty_selection_s sel;
    memset(&sel, 0, sizeof(sel));
    sel.top_left.tag = GHOSTTY_POINT_VIEWPORT;
    sel.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT;
    sel.top_left.x = 0;
    sel.top_left.y = 0;
    sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT;
    sel.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT;
    sel.bottom_right.x = (uint32_t)(_viewportColumns - 1);
    sel.bottom_right.y = (uint32_t)(_viewportRows - 1);
    sel.rectangle = false;
    ghostty_text_s text;
    memset(&text, 0, sizeof(text));
    if (!ghostty_surface_read_text(_surface, sel, &text)) return @"";
    NSString *result = @"";
    if (text.text && text.text_len > 0) {
        result = [[NSString alloc] initWithBytes:text.text
                                          length:(NSUInteger)text.text_len
                                        encoding:NSUTF8StringEncoding] ?: @"";
    }
    ghostty_surface_free_text(_surface, &text);
    return result;
}

- (void)dealloc {
    TXLogEngine(@"TXGhosttyView dealloc");
    [_tickLink invalidate];
    _tickLink = nil;
    if (_surface) { ghostty_surface_free(_surface); _surface = NULL; }
    if (_app) { ghostty_app_free(_app); _app = NULL; }
    if (_config) { ghostty_config_free(_config); _config = NULL; }
}

@end
