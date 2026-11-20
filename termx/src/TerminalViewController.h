// TerminalViewController: the whole app is one screen — a status bar with
// Install-or-Boot / Stop, a terminal, and a key row. The terminal is a
// UITextView fed by vt.c from the guest's serial console (ttyS0); typing
// goes through a hidden UITextField so the software keyboard works, and
// the key row sends the keys a shell needs (Esc, Tab, Ctrl, arrows).
// The guest's Metal view is kept behind the terminal (the runtime refuses
// a null view) and never shown: the console is the whole interface.
// Adapted from CrateTerm's TerminalViewController (same author, same VT
// parser); the engine here is KernEngine on the Kernarium Linux runtime.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@interface TerminalViewController : UIViewController
@end
