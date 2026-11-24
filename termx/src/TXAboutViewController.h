// TXAboutViewController - the About / Version screen.
//
// Shows what this build is, in readable form first: the app version
// (Info.plist) and the build commit (the build.sh marker), the
// installed system-image release (and the release this build
// installs, when they differ), and the Kernarium runtime version
// (API version, upstream commit, framework hash). Hashes are a
// secondary detail — a truncated hash, never the primary display.
//
// It also says two honest things in plain words: fastfetch shows
// Host, CPU and GPU as Unknown on a fresh install (the app never
// types commands into the terminal at boot, and the runtime has no
// channel to pass the phone model to the guest), and the guest
// pauses when the app backgrounds instead of running there.
//
// Presented modally from the startup screen in a navigation
// controller with a Done button, like the Log screen.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@interface TXAboutViewController : UIViewController
@end
