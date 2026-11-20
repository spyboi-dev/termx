// TXStartupViewController - Andarium-style boot screen.
//
// Layout copies the Andarium boot screen the user sent: a top row
// with a status dot plus "Starting" on the left and a live elapsed
// timer on the right, a big bold "TermX" title, a thin progress bar,
// and one rounded card holding four checklist rows. Each row is a
// real boot stage, driven only by what the engine actually reports
// (KernEngine state, boot phase, download byte counts, overlay
// allocation): a row flips to a teal check only when that stage
// really completed, the current stage shows a spinner, later
// stages stay dim, and a failed stage shows the reason inline in
// red. Nothing is faked, no timers pretend to be progress.
//
// The Log button opens the live log view (TXLogViewController,
// with its Copy log button). A Continue button is always on
// screen. The screen dismisses itself into the terminal a short
// beat after the shell is really ready (login prompt on the
// console, engine state Running).
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@interface TXStartupViewController : UIViewController
@end
