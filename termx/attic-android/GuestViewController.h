// GuestViewController: the whole app is one screen — a status bar with
// Install / Boot / Stop / Termux, and the guest's display (an MTKView the
// runtime draws into) filling the rest. Touch goes straight to the guest;
// the key row sends evdev keys, and the keyboard button brings up the
// software keyboard for typing into the guest.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@interface GuestViewController : UIViewController
@end
