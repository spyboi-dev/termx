// TXGhosttyConfigViewController - the Ghostty Configuration detail
// from Settings.
//
// Font size (the same size pinch zoom changes, settable here with
// a stepper) and the terminal appearance (the background, which is
// pure black). The stepper sets the live surface's size at once
// through the Ghostty view, so the terminal behind reflects it.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@class TXGhosttyView;

@interface TXGhosttyConfigViewController : UITableViewController

// The terminal's Ghostty view, so the stepper can set the live
// font size. Weak; the terminal owns it.
@property (nonatomic, weak) TXGhosttyView *terminalOutput;

@end
