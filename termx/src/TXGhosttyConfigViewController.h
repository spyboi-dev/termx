// TXGhosttyConfigViewController - the Ghostty Configuration detail
// from Settings.
//
// Font size (the same size pinch zoom changes, settable here with
// a stepper) and the terminal colors: a list of preset color themes
// (Black is the default), shown with a checkmark on the selected
// one. Picking a theme writes its colors to the Ghostty config
// file and reloads the live surface at once, so the terminal
// behind reflects it. The stepper sets the live surface's size
// the same way.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@class TXGhosttyView;

@interface TXGhosttyConfigViewController : UITableViewController

// The terminal's Ghostty view, so the stepper can set the live
// font size. Weak; the terminal owns it.
@property (nonatomic, weak) TXGhosttyView *terminalOutput;

@end
