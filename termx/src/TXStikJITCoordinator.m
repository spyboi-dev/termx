// TXStikJITCoordinator - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXStikJITCoordinator.h"
#import "TXLog.h"
#import "TXLoopbackProbe.h"
#import "TXPairingStore.h"
#import <stdlib.h>
#import <sys/proc.h>
#import <sys/sysctl.h>
#import <unistd.h>

// Security framework SPI (not in the public headers). Declared
// here exactly as in the StikJIT integration guide. Link
// Security.framework (see build.sh).
void *SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef entitlement, CFErrorRef *error);

NSString *const kTXStikJITMethodDefaultsKey = @"termx.jitMethod";
NSString *const kTXStikJITForceScriptDefaultsKey = @"termx.jitForceScript";

// The one developer-configured script, fixed in backend code.
// Never a user setting.
static NSString *const kTXStikJITScriptName = @"universal.js";

@interface TXStikJITCoordinator ()
@property (nonatomic, copy, nullable) NSString *lastPrepareStatusTextValue;
@property (nonatomic, copy, nullable) NSString *lastAutoEnableStatusTextValue;
@property (nonatomic, assign) BOOL jitEnabledThisLaunchValue;
@property (nonatomic, assign) BOOL autoEnableAttempted;
@property (nonatomic, assign) BOOL loopbackCheckedValue;
@property (nonatomic, assign) BOOL loopbackReachableValue;
@property (nonatomic, copy, nullable) NSString *lastLoopbackDetailValue;
@end

@implementation TXStikJITCoordinator

+ (instancetype)shared {
    static TXStikJITCoordinator *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[TXStikJITCoordinator alloc] init]; });
    return instance;
}

+ (BOOL)isRunningInLiveContainer {
    return getenv("LC_HOME_PATH") != NULL;
}

+ (BOOL)isDebuggerAttached {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return NO;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

#pragma mark - Method selection

- (TXStikJITMethod)selectedMethod {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger stored = [defaults objectForKey:kTXStikJITMethodDefaultsKey]
        ? [defaults integerForKey:kTXStikJITMethodDefaultsKey]
        : TXStikJITMethodBuiltInStikJIT;
    if (stored < TXStikJITMethodBuiltInStikJIT || stored > TXStikJITMethodStikDebug) {
        // A stale stored value (e.g. the removed Wait for Debugger
        // method) falls back to StikDebug, the method available
        // in every environment.
        stored = TXStikJITMethodStikDebug;
    }
    // In LiveContainer a stored Built-in selection is not usable:
    // read it as StikDebug rather than attempting the
    // helper. applyLiveContainerDefaultIfNeeded persists this.
    if (stored == TXStikJITMethodBuiltInStikJIT && [[self class] isRunningInLiveContainer]) {
        return TXStikJITMethodStikDebug;
    }
    return (TXStikJITMethod)stored;
}

- (void)setSelectedMethod:(TXStikJITMethod)method {
    // Refuse Built-in in LiveContainer at the setter too, so no
    // path can store an unusable method there.
    if (method == TXStikJITMethodBuiltInStikJIT && [[self class] isRunningInLiveContainer]) {
        method = TXStikJITMethodStikDebug;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:method forKey:kTXStikJITMethodDefaultsKey];
}

- (void)applyLiveContainerDefaultIfNeeded {
    if (![[self class] isRunningInLiveContainer]) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kTXStikJITMethodDefaultsKey]
        && [defaults integerForKey:kTXStikJITMethodDefaultsKey] == TXStikJITMethodBuiltInStikJIT) {
        [defaults setInteger:TXStikJITMethodStikDebug forKey:kTXStikJITMethodDefaultsKey];
    }
}

- (BOOL)forceScript {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kTXStikJITForceScriptDefaultsKey];
}

- (void)setForceScript:(BOOL)forceScript {
    [[NSUserDefaults standardUserDefaults] setBool:forceScript forKey:kTXStikJITForceScriptDefaultsKey];
}

#pragma mark - Preflight

- (BOOL)supportsOSVersionWithReason:(NSString * _Nullable * _Nullable)reason {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    BOOL supported = version.majorVersion > 17
        || (version.majorVersion == 17 && version.minorVersion >= 4);
    if (!supported && reason) *reason = @"Requires iOS 17.4 or later.";
    return supported;
}

- (BOOL)hasGetTaskAllowWithReason:(NSString * _Nullable * _Nullable)reason {
    void *task = SecTaskCreateFromSelf(NULL);
    if (task == NULL) {
        if (reason) *reason = @"Could not check get-task-allow.";
        return NO;
    }
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("get-task-allow"), NULL);
    BOOL allowed = (value == kCFBooleanTrue);
    if (value != NULL) CFRelease(value);
    CFRelease(task);
    if (!allowed && reason) {
        *reason = @"No get-task-allow. Reinstall with a signing method that preserves it.";
    }
    return allowed;
}

#pragma mark - Pairing

+ (NSURL *)pairingFileURL {
    return [TXPairingStore legacyPairingFileURL];
}

- (BOOL)pairingStored {
    return [[TXPairingStore shared] pairingStored];
}

- (TXPairingSource)pairingSource {
    return [[TXPairingStore shared] pairingSource];
}

- (NSString *)pairingStatusText {
    switch ([self pairingSource]) {
        case TXPairingSourceOnDevice: return @"Paired on this iPhone";
        case TXPairingSourceImported: return @"Imported";
        case TXPairingSourceNone: return @"Not paired";
    }
}

- (NSData *)readPairingDataWithError:(NSError **)error {
    // The bytes cross to the helper over the transport; the
    // contents are never logged anywhere.
    NSData *data = [[TXPairingStore shared] pairingData];
    if (!data && error) {
        *error = [NSError errorWithDomain:@"TXStikJITCoordinatorErrorDomain"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"No pairing stored."}];
    }
    return data;
}

- (BOOL)pairingFileExists {
    return [self pairingStored];
}

- (NSString *)pairingFileName {
    return [self pairingStored] ? @"pairingFile.plist" : nil;
}

- (NSString *)pairingFileStatusText {
    return [self pairingStatusText];
}

- (NSData *)readPairingFileDataWithError:(NSError **)error {
    return [self readPairingDataWithError:error];
}

- (void)importPairingFileFromURL:(NSURL *)sourceURL
                      completion:(void (^)(BOOL success, NSString *statusText))completion {
    BOOL scoped = [sourceURL startAccessingSecurityScopedResource];
    NSData *data = nil;
    NSError *readError = nil;
    @try {
        data = [NSData dataWithContentsOfURL:sourceURL options:0 error:&readError];
    } @finally {
        if (scoped) [sourceURL stopAccessingSecurityScopedResource];
    }
    BOOL ok = NO;
    NSString *status = nil;
    if (!data) {
        status = @"Could not read pairing file.";
        TXLogEngine(@"StikJIT pairing file import failed: %@", readError.localizedDescription ?: @"unknown");
    } else {
        NSError *storeError = nil;
        ok = [[TXPairingStore shared] storePairingData:data
                                                source:TXPairingSourceImported
                                                 error:&storeError];
        if (ok) {
            // A legacy file is superseded by the Keychain copy.
            [[NSFileManager defaultManager] removeItemAtURL:[[self class] pairingFileURL] error:nil];
            status = [self pairingStatusText];
            TXLogEngine(@"StikJIT pairing file imported");
        } else {
            status = storeError.localizedDescription ?: @"Import failed.";
            TXLogEngine(@"StikJIT pairing file import failed: %@", status);
        }
    }
    if (ok) {
        // A new pairing invalidates any shown readiness.
        self.lastPrepareStatusTextValue = nil;
    }
    NSString *finalStatus = status ?: @"Import failed.";
    dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, finalStatus); });
}

#pragma mark - Loopback (LocalDevVPN)

- (BOOL)loopbackChecked {
    return self.loopbackCheckedValue;
}

- (BOOL)loopbackReachable {
    return self.loopbackReachableValue;
}

- (NSString *)lastLoopbackDetail {
    return self.lastLoopbackDetailValue;
}

- (void)checkLoopbackWithCompletion:(void (^)(BOOL reachable, NSString *detail))completion {
    __weak TXStikJITCoordinator *weakSelf = self;
    [TXLoopbackProbe checkWithTimeout:0.4 completion:^(TXLoopbackProbeResult *result) {
        TXStikJITCoordinator *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.loopbackCheckedValue = YES;
            strongSelf.loopbackReachableValue = result.reachable;
            strongSelf.lastLoopbackDetailValue = result.detail;
            TXLogEngine(@"[jit-loopback] %@ in %.0f ms (%@)",
                        result.reachable ? @"reachable" : @"unreachable",
                        result.milliseconds, result.detail);
        }
        completion(result.reachable, result.detail);
    }];
}

+ (BOOL)localDevVPNInstalled {
    return [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"localdevvpn://"]];
}

+ (NSURL *)localDevVPNConnectURL {
    return [NSURL URLWithString:@"localdevvpn://enable"];
}

+ (NSURL *)localDevVPNAppStoreURL {
    return [NSURL URLWithString:@"https://apps.apple.com/us/app/localdevvpn/id6755608044"];
}

+ (NSString *)localDevVPNActionTitle {
    return [self localDevVPNInstalled] ? @"Connect LocalDevVPN" : @"Get LocalDevVPN";
}

+ (void)openLocalDevVPN {
    NSURL *url = [self localDevVPNInstalled] ? [self localDevVPNConnectURL] : [self localDevVPNAppStoreURL];
    TXLogEngine(@"[jit] LocalDevVPN %@", [self localDevVPNInstalled] ? @"connect" : @"app-store");
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

#pragma mark - TXM/SPTM status

- (TXStikJITTXMStatus)txmSPTMStatus {
    return [[TXStikJITTransport shared] txmSPTMStatus];
}

- (NSString *)txmSPTMStatusText {
    return TXStikJITTXMStatusText([self txmSPTMStatus]);
}

- (NSString *)lastPrepareStatusText {
    return self.lastPrepareStatusTextValue;
}

- (NSString *)lastAutoEnableStatusText {
    return self.lastAutoEnableStatusTextValue;
}

- (BOOL)jitEnabledThisLaunch {
    return self.jitEnabledThisLaunchValue || [[self class] isDebuggerAttached];
}

#pragma mark - Helper operations

// Shared preflight for prepare/enable. Returns nil when all three
// checks pass; otherwise the short reason for the first failure.
// In LiveContainer the helper is never launched: the reason says
// so directly.
- (nullable NSString *)preflightFailureReason {
    if ([[self class] isRunningInLiveContainer]) {
        return @"Built-in StikJIT unavailable in LiveContainer.";
    }
    NSString *reason = nil;
    if (![self supportsOSVersionWithReason:&reason]) return reason;
    if (![self hasGetTaskAllowWithReason:&reason]) return reason;
    if (![self pairingStored]) return @"Pair on this iPhone or import a pairing file.";
    return nil;
}

// The loopback gate shared by prepare/enable: when LocalDevVPN
// does not reach the device, the helper cannot either, so fail
// here with the fix instead of a helper error. `proceed` runs on
// the main queue when the loopback answers.
- (void)withLoopbackThen:(void (^)(void))proceed
               otherwise:(void (^)(NSString *reason))otherwise {
    __weak TXStikJITCoordinator *weakSelf = self;
    [self checkLoopbackWithCompletion:^(BOOL reachable, NSString *detail) {
        (void)detail;
        TXStikJITCoordinator *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (reachable) {
            proceed();
        } else {
            NSString *reason = @"LocalDevVPN is not reaching this iPhone. Connect LocalDevVPN and try again.";
            strongSelf.lastPrepareStatusTextValue = reason;
            otherwise(reason);
        }
    }];
}

- (void)prepareJITWithCompletion:(TXStikJITReadinessHandler)completion {
    NSString *failure = [self preflightFailureReason];
    if (failure) {
        self.lastPrepareStatusTextValue = failure;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(TXStikJITReadinessNotReady, failure);
        });
        return;
    }
    __weak TXStikJITCoordinator *weakSelf = self;
    [self withLoopbackThen:^{
        TXStikJITCoordinator *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf prepareJITAfterLoopbackWithCompletion:completion];
    } otherwise:^(NSString *reason) {
        completion(TXStikJITReadinessNotReady, reason);
    }];
}

- (void)prepareJITAfterLoopbackWithCompletion:(TXStikJITReadinessHandler)completion {
    NSError *readError = nil;
    NSData *pairingData = [self readPairingDataWithError:&readError];
    if (!pairingData) {
        NSString *reason = @"Could not read pairing.";
        self.lastPrepareStatusTextValue = reason;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(TXStikJITReadinessNotReady, reason);
        });
        return;
    }
    BOOL force = [self forceScript];
    __weak TXStikJITCoordinator *weakSelf = self;
    [[TXStikJITTransport shared] prepareJITWithPID:getpid()
                                       pairingData:pairingData
                                       forceScript:force
                                          progress:^(NSString *stage) {
        (void)stage;
    } completion:^(TXStikJITTransportResult *result) {
        TXStikJITCoordinator *strongSelf = weakSelf;
        NSString *status = result.statusText;
        if (strongSelf) strongSelf.lastPrepareStatusTextValue = status;
        TXStikJITReadiness readiness = result.success
            ? TXStikJITReadinessReady
            : TXStikJITReadinessHelperUnavailable;
        completion(readiness, status);
    }];
}

- (void)enableJITWithCompletion:(TXStikJITResultHandler)completion {
    NSString *failure = [self preflightFailureReason];
    if (failure) {
        self.lastPrepareStatusTextValue = failure;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, failure); });
        return;
    }
    __weak TXStikJITCoordinator *weakSelf = self;
    [self withLoopbackThen:^{
        TXStikJITCoordinator *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf enableJITAfterLoopbackWithCompletion:completion];
    } otherwise:^(NSString *reason) {
        completion(NO, reason);
    }];
}

- (void)enableJITAfterLoopbackWithCompletion:(TXStikJITResultHandler)completion {
    NSError *readError = nil;
    NSData *pairingData = [self readPairingDataWithError:&readError];
    if (!pairingData) {
        NSString *reason = @"Could not read pairing.";
        self.lastPrepareStatusTextValue = reason;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, reason); });
        return;
    }
    BOOL force = [self forceScript];
    __weak TXStikJITCoordinator *weakSelf = self;
    [[TXStikJITTransport shared] enableJITWithPID:getpid()
                                      pairingData:pairingData
                                      forceScript:force
                                         progress:^(NSString *stage) {
        (void)stage;
    } completion:^(TXStikJITTransportResult *result) {
        TXStikJITCoordinator *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.lastPrepareStatusTextValue = result.statusText;
            if (result.success) strongSelf.jitEnabledThisLaunchValue = YES;
        }
        completion(result.success, result.statusText);
    }];
}

- (void)autoEnableJITBestEffort {
    if ([[self class] isRunningInLiveContainer]) return;
    if ([self selectedMethod] != TXStikJITMethodBuiltInStikJIT) return;
    if (self.autoEnableAttempted) return;
    self.autoEnableAttempted = YES;
    if ([[self class] isDebuggerAttached]) {
        self.jitEnabledThisLaunchValue = YES;
        TXLogEngine(@"[jit-auto] JIT already enabled, skipping");
        return;
    }
    if (![self pairingStored]) {
        self.lastAutoEnableStatusTextValue = @"JIT skipped: not paired.";
        TXLogEngine(@"[jit-auto] skipped: no pairing stored");
        return;
    }
    TXLogEngine(@"[jit-auto] enabling JIT for the guest start");
    __weak TXStikJITCoordinator *weakSelf = self;
    [self enableJITWithCompletion:^(BOOL success, NSString *statusText) {
        TXStikJITCoordinator *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            strongSelf.lastAutoEnableStatusTextValue = @"JIT enabled.";
            TXLogEngine(@"[jit-auto] enabled: %@", statusText);
        } else {
            // Best-effort: the guest boots without JIT. The reason
            // stays visible in About for diagnosis.
            strongSelf.lastAutoEnableStatusTextValue =
                [NSString stringWithFormat:@"JIT not enabled: %@", statusText];
            TXLogEngine(@"[jit-auto] failed: %@", statusText);
        }
    }];
}

- (void)resetCachedDDIWithCompletion:(TXStikJITResultHandler)completion {
    if ([[self class] isRunningInLiveContainer]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, @"Built-in StikJIT unavailable in LiveContainer.");
        });
        return;
    }
    [[TXStikJITTransport shared] resetCachedDDIWithCompletion:
        ^(TXStikJITTransportResult *result) {
        completion(result.success, result.statusText);
    }];
}

#pragma mark - StikDebug URL

- (NSURL *)stikDebugURL {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID) return nil;
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"stikdebug";
    components.host = @"enable-jit";
    NSMutableArray *items = [NSMutableArray arrayWithObjects:
        [NSURLQueryItem queryItemWithName:@"bundle-id" value:bundleID],
        [NSURLQueryItem queryItemWithName:@"pid" value:[NSString stringWithFormat:@"%d", getpid()]],
        nil];
    // The script parameter is only sent when TXM/SPTM is present
    // (or forced): with no TXM, debugger attachment alone enables
    // JIT and the script is omitted.
    if ([self txmSPTMStatus] == TXStikJITTXMStatusPresent || [self forceScript]) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"script-name" value:kTXStikJITScriptName]];
    }
    components.queryItems = items;
    return components.URL;
}

- (BOOL)canOpenStikDebug {
    NSURL *url = [self stikDebugURL];
    if (!url) return NO;
    return [[UIApplication sharedApplication] canOpenURL:url];
}

- (void)openStikDebugWithCompletion:(void (^)(BOOL accepted))completion {
    NSURL *url = [self stikDebugURL];
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }
    // Opening the URL only confirms iOS accepted the request; it
    // is not JIT success. Readiness is still confirmed through
    // the existing breakpoint protocol after the app resumes.
    [[UIApplication sharedApplication] openURL:url
                                       options:@{}
                             completionHandler:completion];
}

@end
