// TXLogViewController - the live log view.
//
// Shows TXLogFullText() (engine.log, then the guest console) in a
// dark monospace card, refreshed every second while visible, with a
// Copy log button. The presenter adds the Done button, the same
// way OCStartupViewController presents the OpenCode engine log.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@interface TXLogViewController : UIViewController
@end
