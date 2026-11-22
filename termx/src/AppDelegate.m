// SPDX-License-Identifier: GPL-2.0-or-later
#import "AppDelegate.h"
#import "TXStartupViewController.h"
#import "TXCrashLog.h"
#import "TXLog.h"
#import "GuestInstall.h"
#import "KernEngine.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    // The startup screen IS the app: it is the root view controller.
    // The terminal is only ever presented from it, once the shell is
    // really ready. No control lives on the terminal window at all.
    self.window.rootViewController = [[TXStartupViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

// The background download finished while the app was suspended or
// killed: re-attach to the session so its delegate callbacks arrive,
// and hand the system completion handler over so it is called once
// the session has delivered all its events.
- (void)application:(UIApplication*)application
    handleEventsForBackgroundURLSession:(NSString*)identifier
                      completionHandler:(void (^)(void))completionHandler {
    (void)application;
    TXLogEngine(@"Background URL session event: %@", identifier);
    [GuestInstall reconnectBackgroundSessionWithCompletionHandler:completionHandler];
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
    // Clean-shutdown marker: on the next launch, a log that ends
    // without one means the previous run was killed (jetsam leaves
    // no crash line). See TXCrashLog.
    TXCrashLogMarkCleanShutdown();
    // Hold the guest GPU while backgrounded: iOS revokes the GPU within
    // seconds, and the runtime must not submit work while it is gone.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"TermXEnterBackground" object:nil];
}

- (void)applicationWillEnterForeground:(UIApplication*)application {
    // Foreground marker: a clean-shutdown marker from an earlier
    // backgrounding must not mask later foreground work.
    TXCrashLogMarkForeground();
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"TermXEnterForeground" object:nil];
}

- (void)applicationWillTerminate:(UIApplication*)application {
    // End the guest before the process dies (best effort, bounded
    // — see KernEngine stopGuestForTermination); the background
    // quiesce is the primary defence.
    [[KernEngine shared] stopGuestForTermination];
    TXCrashLogMarkCleanShutdown();
}

@end
