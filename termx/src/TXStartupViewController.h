// TXStartupViewController - Andarium-style boot screen, and the app's
// root view controller.
//
// Layout copies the Andarium boot screen the user sent: a top row
// with a status dot plus "Starting" on the left and a live elapsed
// timer on the right, a big bold "TermX" title, a thin progress bar,
// and one rounded card holding four checklist rows. Each row is a
// real boot stage, driven only by what the engine actually reports
// (KernEngine state, boot phase, download byte counts, data disk
// allocation): a row flips to a teal check only when that stage
// really completed, the current stage shows a spinner, later
// stages stay dim, and a failed stage shows the reason inline in
// red. Nothing is faked, no timers pretend to be progress.
//
// This screen is the app's control centre, and the ONLY place with
// controls: Install-or-Boot, Stop, Log, Continue, and Erase data
// disk. The terminal window has no buttons at all; it is presented
// from here once the shell is really ready (login prompt on the
// console, engine state Running), or when Continue is tapped, and
// a swipe down from the top edge of the terminal returns here.
//
// The guest's Metal view lives on this screen (behind the opaque
// scroll view) because the guest boots from here, before any
// terminal exists.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@interface TXStartupViewController : UIViewController
@end
