// TXBackgroundKeepAlive - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXBackgroundKeepAlive.h"
#import "KernEngine.h"
#import "TXLog.h"
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

NSString * const kTXBackgroundKeepAliveDefaultsKey = @"termx.backgroundKeepAlive";

@interface TXBackgroundKeepAlive () <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager *manager;
// The manager is running. Main-thread only: every start, stop, and
// read happens on the main queue (reconcile re-dispatches there).
@property (nonatomic) BOOL updating;
// The Always upgrade was already asked for this enable, so the
// prompt is not re-shown on every reconcile. Reset on enable.
@property (nonatomic) BOOL requestedAlwaysUpgrade;
@end

@implementation TXBackgroundKeepAlive

+ (instancetype)shared {
    static TXBackgroundKeepAlive *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _manager = [[CLLocationManager alloc] init];
    // 3 km, significant changes only: no GPS fix is ever needed for
    // a keep-alive session.
    _manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
    _manager.distanceFilter = CLLocationDistanceMax;
    _manager.pausesLocationUpdatesAutomatically = NO;
    _manager.delegate = self;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(reconcile) name:kTermXStateChanged object:nil];
    [nc addObserver:self selector:@selector(reconcile) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(reconcile) name:UIApplicationWillEnterForegroundNotification object:nil];
    return self;
}

- (BOOL)isEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kTXBackgroundKeepAliveDefaultsKey];
}

- (void)setEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kTXBackgroundKeepAliveDefaultsKey];
    // A fresh enable asks for the Always upgrade again, in case the
    // user declined it last time.
    if (enabled) self.requestedAlwaysUpgrade = NO;
    TXLogEngine(@"Background keep-alive %@", enabled ? @"on" : @"off");
    [self reconcile];
}

- (BOOL)isKeepingAlive {
    // Only a running session with Always authorization keeps the
    // app alive in the background. WhenInUse stops delivering once
    // the app backgrounds, so the engine must still quiesce then.
    if (!self.updating) return NO;
    return [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedAlways;
}

- (void)reconcile {
    // The location manager is main-thread only.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self reconcile]; });
        return;
    }
    BOOL inBackground = [UIApplication sharedApplication].applicationState == UIApplicationStateBackground;

    // Off, or no guest to keep alive: stop. The guest counts as
    // active while it is booting or running, so a backgrounded boot
    // can finish instead of being failed by enterBackground.
    if (![self isEnabled] || ![self guestIsActive]) {
        [self stopUpdates];
        return;
    }

    CLAuthorizationStatus auth = [CLLocationManager authorizationStatus];
    if (auth == kCLAuthorizationStatusDenied || auth == kCLAuthorizationStatusRestricted) {
        // Cannot work, and iOS will not prompt again: turn the
        // switch off so the About screen stops showing it on. The
        // user re-enables it from Settings.
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kTXBackgroundKeepAliveDefaultsKey];
        TXLogEngine(@"Background keep-alive: location denied — turning off");
        [self stopUpdates];
        return;
    }
    if (auth == kCLAuthorizationStatusNotDetermined) {
        // No prompt is possible in the background.
        if (inBackground) return;
        [self.manager requestWhenInUseAuthorization];
        return; // the delegate re-reconciles on the answer.
    }
    if (auth == kCLAuthorizationStatusAuthorizedWhenInUse) {
        // WhenInUse cannot run in the background: stop, and ask for
        // the Always upgrade while the app is still in the
        // foreground. The delegate re-reconciles on the answer.
        [self stopUpdates];
        if (!inBackground && !self.requestedAlwaysUpgrade) {
            self.requestedAlwaysUpgrade = YES;
            [self.manager requestAlwaysAuthorization];
        }
        return;
    }
    // Authorized Always: run the session.
    [self startUpdates];
}

- (BOOL)guestIsActive {
    TermXState state = [KernEngine shared].state;
    return state == TermXStateBooting || state == TermXStateRunning;
}

- (void)startUpdates {
    if (self.manager.desiredAccuracy != kCLLocationAccuracyThreeKilometers) {
        self.manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
    }
    if (self.manager.distanceFilter != CLLocationDistanceMax) {
        self.manager.distanceFilter = CLLocationDistanceMax;
    }
    if (!self.manager.allowsBackgroundLocationUpdates) {
        self.manager.allowsBackgroundLocationUpdates = YES;
    }
    if (!self.updating) {
        [self.manager startUpdatingLocation];
        self.updating = YES;
        TXLogEngine(@"Background keep-alive: location session started (3 km, Always)");
    }
}

- (void)stopUpdates {
    if (self.updating) {
        [self.manager stopUpdatingLocation];
        self.updating = NO;
        TXLogEngine(@"Background keep-alive: location session stopped");
    }
    if (self.manager.allowsBackgroundLocationUpdates) {
        self.manager.allowsBackgroundLocationUpdates = NO;
    }
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    (void)manager;
    [self reconcile];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    (void)manager;
    (void)locations;
    // Deliberately ignored: the session exists only to keep the app
    // alive. No fix is read, stored, or sent anywhere.
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    (void)manager;
    if (error.code == kCLErrorDenied) [self stopUpdates];
    TXLogEngine(@"Background keep-alive: location error %@", error);
}

@end
