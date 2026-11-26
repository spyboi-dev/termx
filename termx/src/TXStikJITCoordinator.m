// TXStikJITCoordinator - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXStikJITCoordinator.h"
#import "TXLog.h"
#import <stdlib.h>
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

#pragma mark - Method selection

- (TXStikJITMethod)selectedMethod {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger stored = [defaults objectForKey:kTXStikJITMethodDefaultsKey]
        ? [defaults integerForKey:kTXStikJITMethodDefaultsKey]
        : TXStikJITMethodWaitForDebugger;
    if (stored < TXStikJITMethodBuiltInStikJIT || stored > TXStikJITMethodWaitForDebugger) {
        stored = TXStikJITMethodWaitForDebugger;
    }
    // In LiveContainer a stored Built-in selection is not usable:
    // read it as Wait for Debugger rather than attempting the
    // helper. applyLiveContainerDefaultIfNeeded persists this.
    if (stored == TXStikJITMethodBuiltInStikJIT && [[self class] isRunningInLiveContainer]) {
        return TXStikJITMethodWaitForDebugger;
    }
    return (TXStikJITMethod)stored;
}

- (void)setSelectedMethod:(TXStikJITMethod)method {
    // Refuse Built-in in LiveContainer at the setter too, so no
    // path can store an unusable method there.
    if (method == TXStikJITMethodBuiltInStikJIT && [[self class] isRunningInLiveContainer]) {
        method = TXStikJITMethodWaitForDebugger;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:method forKey:kTXStikJITMethodDefaultsKey];
}

- (void)applyLiveContainerDefaultIfNeeded {
    if (![[self class] isRunningInLiveContainer]) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kTXStikJITMethodDefaultsKey]
        && [defaults integerForKey:kTXStikJITMethodDefaultsKey] == TXStikJITMethodBuiltInStikJIT) {
        [defaults setInteger:TXStikJITMethodWaitForDebugger forKey:kTXStikJITMethodDefaultsKey];
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

#pragma mark - Pairing file

+ (NSURL *)pairingFileURL {
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    return [[documents URLByAppendingPathComponent:@"StikJIT"]
        URLByAppendingPathComponent:@"pairingFile.plist"];
}

- (BOOL)pairingFileExists {
    return [[NSFileManager defaultManager] fileExistsAtPath:[[[self class] pairingFileURL] path]];
}

- (NSString *)pairingFileName {
    if (![self pairingFileExists]) return nil;
    return [[[self class] pairingFileURL] lastPathComponent];
}

- (NSString *)pairingFileStatusText {
    NSString *name = [self pairingFileName];
    return name ?: @"Not imported";
}

- (NSData *)readPairingFileDataWithError:(NSError **)error {
    // The bytes cross to the helper over the transport; the
    // contents are never logged anywhere.
    return [NSData dataWithContentsOfURL:[[self class] pairingFileURL]
                                 options:0
                                   error:error];
}

- (void)importPairingFileFromURL:(NSURL *)sourceURL
                      completion:(void (^)(BOOL success, NSString *statusText))completion {
    NSURL *destination = [[self class] pairingFileURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    BOOL scoped = [sourceURL startAccessingSecurityScopedResource];
    BOOL ok = NO;
    NSString *status = nil;
    @try {
        NSURL *directory = [destination URLByDeletingLastPathComponent];
        if (![fm createDirectoryAtURL:directory
          withIntermediateDirectories:YES attributes:nil error:&error]) {
            status = @"Could not create StikJIT folder.";
        } else {
            // Copy to a temp file first, then atomically replace
            // the stored pairing file.
            NSURL *temp = [[directory URLByAppendingPathComponent:
                [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"plist"]]
                URLByAppendingPathExtension:@"tmp"];
            if (![fm copyItemAtURL:sourceURL toURL:temp error:&error]) {
                status = @"Could not copy pairing file.";
            } else if (![fm replaceItemAtURL:destination
                              withItemAtURL:temp
                             backupItemName:nil
                                    options:NSFileManagerItemReplacementUsingNewMetadataOnly
                           resultingItemURL:nil
                                      error:&error]) {
                [fm removeItemAtURL:temp error:nil];
                status = @"Could not replace pairing file.";
            } else {
                ok = YES;
                status = [self pairingFileStatusText];
            }
        }
    } @finally {
        if (scoped) [sourceURL stopAccessingSecurityScopedResource];
    }
    if (ok) {
        // A new pairing file invalidates any shown readiness.
        self.lastPrepareStatusTextValue = nil;
        TXLogEngine(@"StikJIT pairing file imported");
    } else {
        TXLogEngine(@"StikJIT pairing file import failed: %@", error.localizedDescription ?: @"unknown");
    }
    NSString *finalStatus = status ?: @"Import failed.";
    dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, finalStatus); });
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
    if (![self pairingFileExists]) return @"Import a pairing file first.";
    return nil;
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
    NSError *readError = nil;
    NSData *pairingData = [self readPairingFileDataWithError:&readError];
    if (!pairingData) {
        NSString *reason = @"Could not read pairing file.";
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
    NSError *readError = nil;
    NSData *pairingData = [self readPairingFileDataWithError:&readError];
    if (!pairingData) {
        NSString *reason = @"Could not read pairing file.";
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
        if (strongSelf) strongSelf.lastPrepareStatusTextValue = result.statusText;
        completion(result.success, result.statusText);
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
