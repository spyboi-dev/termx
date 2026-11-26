// TXGhosttyView - the terminal surface, now Ghostty (libghostty) instead
// of the hand-rolled vt.c + UITextView.
//
// Ghostty owns the whole terminal: the VT parser, the grid, the
// colours, the cursor blink, the scrollback, and the Metal rendering.
// This view only provides the UIView Ghostty renders into, feeds it
// the guest's console bytes, and forwards input (typed text, key-row
// keys, paste) into it. The guest I/O stays host-managed: bytes the
// terminal wants to send to the guest arrive on onOutput, and the
// controller sends them with KernEngine sendConsoleInput:.
//
// All Ghostty calls run on the main thread. Ghostty invokes the
// receive_buffer / receive_resize / wakeup / clipboard callbacks from
// its own threads; those callbacks bounce to the main queue before
// touching this view or the output block.
//
// Lifecycle: the app is created in init (it needs no view). The
// surface is created lazily on the first layout with non-zero bounds
// (Ghostty sizes the grid from the view, so a zero-size surface
// would start 0x0). Guest output fed before the surface is sized is
// buffered and flushed once it is. The display link ticks the app
// while the view is in a window; the surface is freed in dealloc.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

// Static library: GHOSTTY_API must be a no-op (see ghostty.h).
#define GHOSTTY_STATIC
#import <libghostty/ghostty.h>

@interface TXGhosttyView : UIView

// Bytes the terminal wants to send to the guest (typed text, key
// sequences, paste). Called on the main thread. The controller sets
// this to forward to KernEngine sendConsoleInput:.
@property (nonatomic, copy) void (^onOutput)(NSData *data);

// Fired on the main thread when the terminal rings the bell (BEL).
// The controller sets this to the haptic.
@property (nonatomic, copy) void (^onBell)(void);

// The viewport Ghostty last reported via receive_resize: the grid
// size the guest's programs should lay out for. 0 until the first
// resize (the surface has not been sized yet).
@property (nonatomic, readonly) uint16_t viewportColumns;
@property (nonatomic, readonly) uint16_t viewportRows;

// Guest console bytes into the terminal. Safe before the surface
// exists: they are buffered and flushed once it is sized.
- (void)feedGuestOutput:(NSData *)data;

// Guest console bytes that are history, not live output (the boot
// log replayed when the terminal first appears). Parsed the same
// way, but the replies the bytes would trigger — device attributes,
// status and cursor reports, OSC colour queries, title reports —
// are dropped: those queries were answered when the bytes were
// live, and a second answer reaches the shell as typed input.
// Same buffering as feedGuestOutput before the surface is sized.
- (void)feedGuestOutputReplay:(NSData *)data;

// Typed text (from the hidden input field) into the terminal, on
// the key path like libghostty-spm's sendTypedText: a key event
// with keycode 0xFFFF (unidentified) and the text, so Ghostty
// encodes it as keystrokes. NOT the text path (sendText:), which
// Ghostty treats as a paste and wraps in bracketed paste.
- (void)sendTypedText:(NSString *)text mods:(ghostty_input_mods_e)mods;

// Raw text into the terminal on the text path: Ghostty treats it
// as a paste. Only for key-row byte sequences and control bytes,
// never for typed letters (see sendTypedText:).
- (void)sendText:(NSString *)text;

// A special key (arrows, Esc, Tab, Backspace, Enter) with the
// Ghostty modifier mask (GHOSTTY_MODS_CTRL / GHOSTTY_MODS_ALT for
// the latched key-row modifiers).
- (void)sendKey:(ghostty_input_key_e)key mods:(ghostty_input_mods_e)mods;

// A paste (clipboard text) into the terminal. Ghostty wraps it in
// bracketed paste when the terminal has that mode on.
- (void)pasteText:(NSString *)text;

// Set the font size absolutely (Settings stepper), via Ghostty's
// set_font_size binding action. Clamped to Termux's 4-256 pt and
// persisted, like the pinch zoom.
- (void)setFontSize:(CGFloat)size;

// Reload the Ghostty config on the live surface, so a color theme
// picked in Settings applies at once, without relaunching: a fresh
// config is built from the live config file and pushed with
// ghostty_app_update_config. If there is no surface yet, the config
// file is already rewritten and the next launch picks the theme up.
- (void)reloadConfig;

// Whether the surface is focused (cursor shown). Set NO when the
// terminal screen goes away; YES while it is on screen.
- (void)setFocused:(BOOL)focused;

// The visible screen's plain text (viewport only, not the
// scrollback), for the Copy button. Empty when the surface is not
// ready yet.
- (NSString *)visibleScreenText;

@end
