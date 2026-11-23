// TerminalViewController: just the terminal, nothing else. No status
// bar, no Install/Boot/Stop/Log buttons: every control lives only on
// the startup screen, which is the app's root and the screen that
// presents this one. The terminal is a UITextView fed by vt.c from
// the guest's serial console (ttyS0); typing goes through a hidden
// UITextField so the software keyboard works, and the key row sends
// the keys a shell needs (Esc, Tab, Ctrl, arrows) — those are typing
// keys, not controls, and they stay.
//
// Way back: swipe down starting from the top edge of the screen (a
// downward drag that begins in the top strip) returns to the startup
// screen, where Stop, Logs, Install and Boot live. The guest's Metal
// view lives on the startup screen now, not here.
// Adapted from CrateTerm's TerminalViewController (same author, same VT
// parser); the engine here is KernEngine on the Kernarium Linux runtime.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@interface TerminalViewController : UIViewController
// When YES, the first time the terminal appears it clears the boot
// log from the display (grid and scrollback) and asks the guest for
// a fresh prompt, so the user opens on a clean prompt instead of the
// systemd boot log. The log itself is not lost: it stays in
// guest.log and engine.log. The startup screen sets this YES only
// for the first presentation after a boot, and NO when the user
// returns via the Terminal button, so returning never wipes
// scrollback.
@property (nonatomic, assign) BOOL clearScreenOnBoot;
@end
