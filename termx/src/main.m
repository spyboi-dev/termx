// KTerm: our own iOS Termux app on the Kernarium runtime.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "TXCrashLog.h"
#import "TXLog.h"

int main(int argc, char* argv[]) {
    @autoreleasepool {
        // Crash recorder FIRST, before UIApplicationMain runs: a
        // launch crash must leave a trace in Documents/CRASH.txt
        // and Documents/Engine/engine.log, or there is nothing to
        // diagnose it with. InstallEarly also checks the previous
        // run for an unclean end (jetsam leaves no crash line).
        TXCrashLogInstallEarly();
        // Then the runtime's own stdout/stderr into engine.log:
        // the Kernarium runtime prints the exact reason a boot
        // fails there, and until now the app never saw it.
        TXLogCaptureRuntimeOutput();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
