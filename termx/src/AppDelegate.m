// SPDX-License-Identifier: GPL-2.0-or-later
#import "AppDelegate.h"
#import "TerminalViewController.h"
#import "TXCrashLog.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[TerminalViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
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
    TXCrashLogMarkCleanShutdown();
}

@end
