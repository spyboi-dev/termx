// SPDX-License-Identifier: GPL-2.0-or-later
#import "AppDelegate.h"
#import "TerminalViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[TerminalViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
    // Hold the guest GPU while backgrounded: iOS revokes the GPU within
    // seconds, and the runtime must not submit work while it is gone.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"TermXEnterBackground" object:nil];
}

- (void)applicationWillEnterForeground:(UIApplication*)application {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"TermXEnterForeground" object:nil];
}

@end
