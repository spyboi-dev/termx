// TXGhosttyView implementation. See the header.
//
// The one Ghostty app per view: ghostty_init runs once per process
// (dispatch_once), the config is a default one, and the runtime
// callbacks bounce to the main queue. The surface is created on the
// first layout with real bounds, so Ghostty sizes its grid from the
// view; guest output before then is buffered and flushed once the
// surface is sized.
#import "TXGhosttyView.h"

#import <string.h>

#import "TXLog.h"
#import "TXTheme.h"

@interface TXGhosttyView ()
- (void)tx_tick;
- (void)tx_setViewportColumns:(uint16_t)cols rows:(uint16_t)rows widthPx:(uint32_t)w heightPx:(uint32_t)h;
- (void)tx_completeClipboardRead:(void *)request;
- (void)tx_ringBell;
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
// main thread so it is drained.
static void TXGhosttyWakeup(void *userdata) {
    TXGhosttyView *view = (__bridge TXGhosttyView *)userdata;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
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
    CGSize _lastSizePx;
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
    [self tx_createApp];
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
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    BOOL inWindow = (self.window != nil);
    _tickLink.paused = !inWindow;
    if (_surface) ghostty_surface_set_focus(_surface, inWindow && _focused);
}

- (void)tx_tick {
    if (_app) ghostty_app_tick(_app);
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
    ghostty_surface_write_buffer(_surface, (const uint8_t *)data.bytes, (uintptr_t)data.length);
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

- (void)sendKey:(ghostty_input_key_e)key mods:(ghostty_input_mods_e)mods {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self sendKey:key mods:mods]; });
        return;
    }
    if (!_surface) return;
    ghostty_input_key_s k;
    memset(&k, 0, sizeof(k));
    k.action = GHOSTTY_ACTION_PRESS;
    k.mods = mods;
    k.consumed_mods = 0;
    k.keycode = (uint32_t)key;
    k.text = NULL;
    k.unshifted_codepoint = 0;
    k.composing = false;
    ghostty_surface_key(_surface, k);
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
