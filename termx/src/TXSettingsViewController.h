// TXSettingsViewController - Settings, Swipterm's layout.
//
// The top level matches the Swipterm Settings screenshot exactly:
// a "Container" section (JIT, Data Size, Reset) and a "Terminal"
// section (Ghostty Configuration), as grouped rounded cards on a
// black background. TermX's real features that Swipterm's shot
// does not show stay reachable without breaking that layout: the
// Background keep-alive toggle and the Localhost row sit in the
// Container card, and the existing About page is an "About" section
// at the bottom. No row here is fake: every row opens a working
// detail or toggles a real setting.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@class TXGhosttyView;

@interface TXSettingsViewController : UITableViewController

// The terminal's Ghostty view, so the Ghostty Configuration detail
// can set the live font size. Weak; the terminal owns it.
@property (nonatomic, weak) TXGhosttyView *terminalOutput;

@end
