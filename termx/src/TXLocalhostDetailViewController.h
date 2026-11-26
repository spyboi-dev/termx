// TXLocalhostDetailViewController - the Localhost detail from
// Settings.
//
// The guest's 127.0.0.1 services, reachable from the iPhone at the
// same address while the guest is running. The configured ports are
// the manual override (always forwarded, swipe to remove); the
// auto-detected ports are what the guest is listening on right now
// (read-only, they appear and leave as services start and stop).
// Changes take effect at once when the guest is up (the engine
// restarts the proxy); when it is not up, they apply on the next
// boot. Same source as the About Localhost card, in table form.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@interface TXLocalhostDetailViewController : UITableViewController

@end
