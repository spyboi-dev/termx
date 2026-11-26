// TXOnDevicePairing - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXOnDevicePairing.h"
#import "TXLog.h"
#import "TXPairingStore.h"
#import "TXRPPairing.h"
#import <BackgroundTasks/BackgroundTasks.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>
#import <dns_sd.h>
#import <string.h>

@interface TXOnDevicePairing ()
@property (nonatomic, readwrite) TXOnDevicePairingPhase phase;
@property (nonatomic, readwrite, copy, nullable) NSString *pin;
@property (nonatomic, readwrite, copy, nullable) NSString *pairedDeviceName;
@property (nonatomic, readwrite) BOOL backgroundLimited;
@property (nonatomic, assign) TXRPPairing *session;
@property (nonatomic, assign) DNSServiceRef registration;
@property (nonatomic, strong, nullable) id continuedTask;
@property (nonatomic, copy, nullable) NSString *registeredTaskIdentifier;
@property (nonatomic, assign) UIBackgroundTaskIdentifier graceTask;
@property (nonatomic, strong, nullable) NSTimer *deadlineTimer;

- (void)submitContinuedProcessingTask API_AVAILABLE(ios(26.0));
- (void)attachContinuedTask:(BGTask *)task API_AVAILABLE(ios(26.0));
- (void)showPIN:(NSString *)pin;
- (void)advertisingFailed:(DNSServiceErrorType)error;
@end

static void TXOnDevicePairingPinCallback(const char *pin, void *context) {
    if (!pin || !context) return;
    NSString *code = [NSString stringWithUTF8String:pin];
    if (!code) return;
    TXOnDevicePairing *pairing = (__bridge TXOnDevicePairing *)context;
    dispatch_async(dispatch_get_main_queue(), ^{ [pairing showPIN:code]; });
}

static void TXPairingRegisterReply(DNSServiceRef sdRef, DNSServiceFlags flags,
                                   DNSServiceErrorType errorCode, const char *name,
                                   const char *regtype, const char *domain, void *context) {
    (void)sdRef; (void)flags; (void)name; (void)regtype; (void)domain;
    if (errorCode == kDNSServiceErr_NoError || !context) return;
    TXOnDevicePairing *pairing = (__bridge TXOnDevicePairing *)context;
    dispatch_async(dispatch_get_main_queue(), ^{ [pairing advertisingFailed:errorCode]; });
}



// The pairing library is a static archive linked only when the Mac
// runner built it (termx/rppairing-artifact/): a host-only build
// has no such symbols, and a direct call would fail the link.
// Resolve them at runtime instead: dlsym finds them in the main
// executable when the library was linked, and NULL when it was not.
typedef TXRPPairing *(*TXRPPairingNewFn)(const char *, char **);
typedef uint16_t (*TXRPPairingPortFn)(const TXRPPairing *);
typedef const char *(*TXRPPairingServiceNameFn)(const TXRPPairing *);
typedef size_t (*TXRPPairingTxtCountFn)(const TXRPPairing *);
typedef const char *(*TXRPPairingTxtFn)(const TXRPPairing *, size_t);
typedef int32_t (*TXRPPairingAcceptFn)(const TXRPPairing *, TXRPPairingPinCallback, void *,
                                       uint8_t **, size_t *, char **, char **);
typedef void (*TXRPPairingCancelFn)(const TXRPPairing *);
typedef void (*TXRPPairingFreeFn)(TXRPPairing *);
typedef void (*TXRPPairingBytesFreeFn)(uint8_t *, size_t);
typedef void (*TXRPPairingStringFreeFn)(char *);

static TXRPPairingNewFn txRPPairingNewFn = NULL;
static TXRPPairingPortFn txRPPairingPortFn = NULL;
static TXRPPairingServiceNameFn txRPPairingServiceNameFn = NULL;
static TXRPPairingTxtCountFn txRPPairingTxtCountFn = NULL;
static TXRPPairingTxtFn txRPPairingTxtKeyFn = NULL;
static TXRPPairingTxtFn txRPPairingTxtValueFn = NULL;
static TXRPPairingAcceptFn txRPPairingAcceptFn = NULL;
static TXRPPairingCancelFn txRPPairingCancelFn = NULL;
static TXRPPairingFreeFn txRPPairingFreeFn = NULL;
static TXRPPairingBytesFreeFn txRPPairingBytesFreeFn = NULL;
static TXRPPairingStringFreeFn txRPPairingStringFreeFn = NULL;

static BOOL TXRPPairingResolve(void) {
    static dispatch_once_t once;
    static BOOL available = NO;
    dispatch_once(&once, ^{
        txRPPairingNewFn = (TXRPPairingNewFn)dlsym(RTLD_DEFAULT, "tx_rppairing_new");
        txRPPairingPortFn = (TXRPPairingPortFn)dlsym(RTLD_DEFAULT, "tx_rppairing_port");
        txRPPairingServiceNameFn = (TXRPPairingServiceNameFn)dlsym(RTLD_DEFAULT, "tx_rppairing_service_name");
        txRPPairingTxtCountFn = (TXRPPairingTxtCountFn)dlsym(RTLD_DEFAULT, "tx_rppairing_txt_count");
        txRPPairingTxtKeyFn = (TXRPPairingTxtFn)dlsym(RTLD_DEFAULT, "tx_rppairing_txt_key");
        txRPPairingTxtValueFn = (TXRPPairingTxtFn)dlsym(RTLD_DEFAULT, "tx_rppairing_txt_value");
        txRPPairingAcceptFn = (TXRPPairingAcceptFn)dlsym(RTLD_DEFAULT, "tx_rppairing_accept");
        txRPPairingCancelFn = (TXRPPairingCancelFn)dlsym(RTLD_DEFAULT, "tx_rppairing_cancel");
        txRPPairingFreeFn = (TXRPPairingFreeFn)dlsym(RTLD_DEFAULT, "tx_rppairing_free");
        txRPPairingBytesFreeFn = (TXRPPairingBytesFreeFn)dlsym(RTLD_DEFAULT, "tx_rppairing_bytes_free");
        txRPPairingStringFreeFn = (TXRPPairingStringFreeFn)dlsym(RTLD_DEFAULT, "tx_rppairing_string_free");
        available = txRPPairingNewFn && txRPPairingPortFn && txRPPairingServiceNameFn
            && txRPPairingTxtCountFn && txRPPairingTxtKeyFn && txRPPairingTxtValueFn
            && txRPPairingAcceptFn && txRPPairingCancelFn && txRPPairingFreeFn
            && txRPPairingBytesFreeFn && txRPPairingStringFreeFn;
    });
    return available;
}

@implementation TXOnDevicePairing

+ (instancetype)shared {
    static TXOnDevicePairing *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[TXOnDevicePairing alloc] init]; });
    return instance;
}

+ (BOOL)isSupported {
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:
        (NSOperatingSystemVersion){ .majorVersion = 27, .minorVersion = 0, .patchVersion = 0 }];
}

+ (NSString *)hostName {
    return @"TermX";
}

+ (NSTimeInterval)timeout {
    return 300;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _phase = TXOnDevicePairingPhaseIdle;
        _graceTask = UIBackgroundTaskInvalid;
    }
    return self;
}

- (BOOL)active {
    return self.phase == TXOnDevicePairingPhaseWaiting
        || self.phase == TXOnDevicePairingPhasePIN;
}

- (void)log:(NSString *)line {
    TXLogEngine(@"[jit-pairing] %@", line);
}

- (void)start {
    if (![[self class] isSupported] || self.active || self.session != NULL) return;
    // The pairing library is resolved at runtime (see
    // TXRPPairingResolve): a host-only build made without
    // termx/rppairing-artifact/ has no symbols to call.
    if (!TXRPPairingResolve()) {
        [self fail:@"On-device pairing is not in this build. Import a pairing file instead."];
        return;
    }
    char *error = NULL;
    TXRPPairing *session = txRPPairingNewFn([[[self class] hostName] UTF8String], &error);
    if (!session) {
        NSString *message = nil;
        if (error) {
            message = [NSString stringWithUTF8String:error];
            txRPPairingStringFreeFn(error);
        }
        [self fail:message ?: @"TermX could not open its pairing port."];
        return;
    }
    self.session = session;
    self.phase = TXOnDevicePairingPhaseWaiting;
    self.backgroundLimited = NO;
    self.pairedDeviceName = nil;
    self.pin = nil;
    [self log:@"started"];
    [self requestNotificationAuthorization];
    if (![self publishSession:session]) {
        txRPPairingFreeFn(session);
        self.session = NULL;
        return;
    }
    [self beginBackground];
    __weak TXOnDevicePairing *weakSelf = self;
    self.deadlineTimer = [NSTimer scheduledTimerWithTimeInterval:[[self class] timeout]
                                                          repeats:NO
                                                            block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf cancelWithReason:@"Pairing timed out. Try again when you are ready to pair from Settings."];
    }];
    TXOnDevicePairing *strongSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint8_t *bytes = NULL;
        size_t length = 0;
        char *device = NULL;
        char *failure = NULL;
        int32_t status = txRPPairingAcceptFn(session, TXOnDevicePairingPinCallback,
                                             (__bridge void *)strongSelf,
                                             &bytes, &length, &device, &failure);
        NSData *data = bytes ? [NSData dataWithBytes:bytes length:length] : nil;
        if (bytes) txRPPairingBytesFreeFn(bytes, length);
        NSString *deviceName = nil;
        if (device) {
            deviceName = [NSString stringWithUTF8String:device];
            txRPPairingStringFreeFn(device);
        }
        NSString *message = nil;
        if (failure) {
            message = [NSString stringWithUTF8String:failure];
            txRPPairingStringFreeFn(failure);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf finishedWithStatus:status data:data deviceName:deviceName message:message];
        });
    });
}

- (void)cancelWithReason:(NSString *)reason {
    if (!self.session) return;
    txRPPairingCancelFn(self.session);
    [self stopAdvertising];
    self.phase = reason ? TXOnDevicePairingPhaseFailed : TXOnDevicePairingPhaseIdle;
    if (reason) {
        [self log:@"stopped"];
        if (self.completion) self.completion(NO, nil, reason);
    } else {
        [self log:@"cancelled"];
    }
    [self endBackgroundWithSuccess:NO];
}

- (void)showPIN:(NSString *)pin {
    if (!self.active) return;
    self.pin = pin;
    self.phase = TXOnDevicePairingPhasePIN;
    [self log:@"code shown"];
    if (@available(iOS 26.0, *)) {
        BGContinuedProcessingTask *task = (BGContinuedProcessingTask *)self.continuedTask;
        if ([task isKindOfClass:[BGContinuedProcessingTask class]]) {
            NSString *deviceKind = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad
                ? @"iPad" : @"iPhone";
            [task updateTitle:[NSString stringWithFormat:@"Pairing code %@", pin]
                     subtitle:[NSString stringWithFormat:@"Enter it on this %@ to pair with TermX", deviceKind]];
            task.progress.completedUnitCount = 1;
        }
    }
    if (self.onPIN) self.onPIN(pin);
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        [self notifyWithTitle:[NSString stringWithFormat:@"TermX pairing code: %@", pin]
                         body:@"Enter this code on your iPhone to finish pairing."];
    }
}

- (void)finishedWithStatus:(int32_t)status
                      data:(NSData *)data
                deviceName:(NSString *)deviceName
                   message:(NSString *)message {
    if (self.session) txRPPairingFreeFn(self.session);
    self.session = NULL;
    [self stopAdvertising];
    [self.deadlineTimer invalidate];
    self.deadlineTimer = nil;
    switch (status) {
        case 0: {
            if (!data) {
                [self fail:@"Pairing finished, but TermX could not save the pairing."];
                return;
            }
            NSError *storeError = nil;
            if (![[TXPairingStore shared] storePairingData:data
                                                     source:TXPairingSourceOnDevice
                                                      error:&storeError]) {
                [self log:@"save failed"];
                [self fail:@"Pairing finished, but TermX could not save the pairing."];
                return;
            }
            self.phase = TXOnDevicePairingPhasePaired;
            self.pairedDeviceName = deviceName ?: @"this iPhone";
            [self log:@"paired"];
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
                [self notifyWithTitle:@"Paired with TermX"
                                 body:@"Return to TermX to finish setting up JIT."];
            }
            [self endBackgroundWithSuccess:YES];
            if (self.completion) self.completion(YES, self.pairedDeviceName, nil);
            break;
        }
        case 2:
            // Cancelled: cancelWithReason already reported it and
            // set the phase; nothing more to do.
            [self endBackgroundWithSuccess:NO];
            break;
        default:
            [self fail:message ? [NSString stringWithFormat:@"Pairing failed: %@", message]
                              : @"Pairing failed. Try again."];
            break;
    }
}

- (void)fail:(NSString *)message {
    if (self.session) txRPPairingCancelFn(self.session);
    [self stopAdvertising];
    self.phase = TXOnDevicePairingPhaseFailed;
    [self log:@"failed"];
    [self endBackgroundWithSuccess:NO];
    if (self.completion) self.completion(NO, nil, message);
}

#pragma mark - Advertising

- (BOOL)publishSession:(TXRPPairing *)session {
    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    size_t count = txRPPairingTxtCountFn(session);
    for (size_t index = 0; index < count; index++) {
        const char *key = txRPPairingTxtKeyFn(session, index);
        const char *value = txRPPairingTxtValueFn(session, index);
        if (!key || !value) continue;
        TXTRecordSetValue(&txt, key, (uint8_t)strlen(value), value);
    }
    DNSServiceRef ref = NULL;
    DNSServiceErrorType error = DNSServiceRegister(
        &ref, 0, 0, txRPPairingServiceNameFn(session),
        "_remotepairing-pairable-host._tcp", NULL, NULL,
        htons(txRPPairingPortFn(session)),
        TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
        TXPairingRegisterReply, (__bridge void *)self);
    TXTRecordDeallocate(&txt);
    if (error != kDNSServiceErr_NoError || !ref) {
        [self advertisingFailed:error];
        return NO;
    }
    DNSServiceSetDispatchQueue(ref, dispatch_get_main_queue());
    self.registration = ref;
    return YES;
}

- (void)advertisingFailed:(DNSServiceErrorType)error {
    if (!self.active) return;
    [self log:[NSString stringWithFormat:@"advertising failed error=%d", (int)error]];
    [self fail:error == kDNSServiceErr_PolicyDenied
        ? @"TermX needs Local Network access to pair. Allow it in Settings > Apps > TermX, then try again."
        : @"TermX could not announce itself on the local network. Check that Wi-Fi is on, then try again."];
}

- (void)stopAdvertising {
    if (self.registration) DNSServiceRefDeallocate(self.registration);
    self.registration = NULL;
}

#pragma mark - Background

// The permitted "app.termx.ios.pairing.*" identifier from
// Info.plist, made concrete.
- (NSString *)taskIdentifier {
    NSArray *permitted = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"BGTaskSchedulerPermittedIdentifiers"];
    for (NSString *entry in permitted) {
        if ([entry hasSuffix:@".pairing.*"]) {
            return [[entry substringToIndex:entry.length - 1] stringByAppendingString:@"session"];
        }
    }
    return nil;
}

- (void)beginBackground {
    __weak TXOnDevicePairing *weakSelf = self;
    self.graceTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"TermX pairing"
                                                                  expirationHandler:^{
        TXOnDevicePairing *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!strongSelf.continuedTask && strongSelf.active) {
            [strongSelf cancelWithReason:@"iOS stopped TermX in the background before pairing finished. Try again, and pair from Settings straight away."];
        }
        [strongSelf endGrace];
    }];
    if (@available(iOS 26.0, *)) {
        [self submitContinuedProcessingTask];
    } else {
        self.backgroundLimited = YES;
    }
}

- (void)submitContinuedProcessingTask API_AVAILABLE(ios(26.0)) {
    NSString *identifier = [self taskIdentifier];
    if (!identifier) {
        self.backgroundLimited = YES;
        return;
    }
    if (![identifier isEqualToString:self.registeredTaskIdentifier]) {
        __weak TXOnDevicePairing *weakSelf = self;
        BOOL registered = [[BGTaskScheduler sharedScheduler]
            registerForTaskWithIdentifier:identifier
                               usingQueue:dispatch_get_main_queue()
                            launchHandler:^(BGTask *task) {
            TXOnDevicePairing *strongSelf = weakSelf;
            if (!strongSelf) {
                [task setTaskCompletedWithSuccess:NO];
                return;
            }
            [strongSelf attachContinuedTask:task];
        }];
        if (!registered) {
            [self log:@"continued-processing register refused"];
            self.backgroundLimited = YES;
            return;
        }
        self.registeredTaskIdentifier = identifier;
    }
    BGContinuedProcessingTaskRequest *request = [[BGContinuedProcessingTaskRequest alloc]
        initWithIdentifier:identifier
                     title:@"Pairing with TermX"
                  subtitle:@"Settings > Privacy & Security > Developer Mode"];
    request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;
    NSError *error = nil;
    if (![[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error]) {
        [self log:@"continued-processing refused"];
        self.backgroundLimited = YES;
    } else {
        [self log:@"continued-processing submitted"];
    }
}

- (void)attachContinuedTask:(BGTask *)task API_AVAILABLE(ios(26.0)) {
    if (!self.active) {
        [task setTaskCompletedWithSuccess:NO];
        return;
    }
    if (![task isKindOfClass:[BGContinuedProcessingTask class]]) {
        [task setTaskCompletedWithSuccess:NO];
        return;
    }
    BGContinuedProcessingTask *continued = (BGContinuedProcessingTask *)task;
    self.continuedTask = task;
    continued.progress.totalUnitCount = 2;
    if (self.pin) {
        NSString *deviceKind = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad
            ? @"iPad" : @"iPhone";
        [continued updateTitle:[NSString stringWithFormat:@"Pairing code %@", self.pin]
                       subtitle:[NSString stringWithFormat:@"Enter it on this %@ to pair with TermX", deviceKind]];
        continued.progress.completedUnitCount = 1;
    }
    __weak TXOnDevicePairing *weakSelf = self;
    task.expirationHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            TXOnDevicePairing *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.continuedTask = nil;
            [strongSelf cancelWithReason:@"iOS stopped the pairing in the background. Try again."];
        });
    };
    [self log:@"continued-processing running"];
}

- (void)endBackgroundWithSuccess:(BOOL)success {
    if (@available(iOS 26.0, *)) {
        BGContinuedProcessingTask *task = (BGContinuedProcessingTask *)self.continuedTask;
        if ([task isKindOfClass:[BGContinuedProcessingTask class]]) {
            task.progress.completedUnitCount = task.progress.totalUnitCount;
            [task setTaskCompletedWithSuccess:success];
        }
    }
    self.continuedTask = nil;
    [self endGrace];
}

- (void)endGrace {
    if (self.graceTask == UIBackgroundTaskInvalid) return;
    [[UIApplication sharedApplication] endBackgroundTask:self.graceTask];
    self.graceTask = UIBackgroundTaskInvalid;
}

#pragma mark - Notifications

- (void)requestNotificationAuthorization {
    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                      completionHandler:^(BOOL granted, NSError *error) { (void)granted; (void)error; }];
}

- (void)notifyWithTitle:(NSString *)title body:(NSString *)body {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    content.sound = [UNNotificationSound defaultSound];
    UNNotificationRequest *request = [UNNotificationRequest
        requestWithIdentifier:[@"termx.pairing." stringByAppendingString:[[NSUUID UUID] UUIDString]]
                      content:content
                      trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                           withCompletionHandler:nil];
}

@end
