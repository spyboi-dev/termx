// TXStikJITTransport - see the header.
//
// REAL IMPLEMENTATION: launches TermX's own JIT helper extension
// (PlugIns/TermXJITHelper.appex) with NSExtension's private calls,
// the ones LiveContainer and other built-in JIT enablers use, and
// carries PID + pairing-file data to it and progress + results back.
// There is no public API to start an app's own classic extension,
// so the extension is looked up by bundle ID (which survives a
// sideloader renaming the app), a request is begun with input items,
// and the reply arrives in the completion block. The helper is a
// second process because a process that attaches a debugger to
// itself deadlocks.
//
// Request/reply contract (see TermXJITHelper.swift): request is the
// input item's userInfo, {"op": enable|prepare|reset, "pid": Int,
// "pairing": Data, "forceScript": Bool}; reply is one item whose
// userInfo is {"ok": Bool, "summary": String, "log": [String]}.
// Pairing bytes are never logged. The helper returns its log lines
// only with the reply (no streaming channel), so progress is
// forwarded when the reply arrives, before completion.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXStikJITTransport.h"

#include <dlfcn.h>

NSString *const TXStikJITTransportErrorDomain = @"TXStikJITTransportErrorDomain";

@implementation TXStikJITTransportResult

+ (instancetype)successWithStatusText:(NSString *)statusText {
    TXStikJITTransportResult *result = [[TXStikJITTransportResult alloc] init];
    result->_success = YES;
    result->_statusText = [statusText copy];
    return result;
}

+ (instancetype)failureWithError:(NSError *)error statusText:(NSString *)statusText {
    TXStikJITTransportResult *result = [[TXStikJITTransportResult alloc] init];
    result->_success = NO;
    result->_statusText = [statusText copy];
    result->_error = error;
    return result;
}

@end

NSString *TXStikJITTXMStatusText(TXStikJITTXMStatus status) {
    switch (status) {
        case TXStikJITTXMStatusPresent: return @"Present";
        case TXStikJITTXMStatusNotPresent: return @"Not Present";
        case TXStikJITTXMStatusUnknown: return @"Unknown";
    }
}

/* Private NSExtension calls. There is no public API to start an
   app's own classic extension; this is the same mechanism
   LiveContainer and other built-in JIT enablers use. */
@interface NSObject (TXStikJITNSExtension)
+ (nullable id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *_Nullable))completion;
- (void)setRequestCompletionBlock:(void (^)(NSUUID *, NSArray *))block;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *, NSError *_Nullable))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *))block;
@end

static NSString *const kTXJITHelperAppexName = @"TermXJITHelper.appex";

/* Each NSExtension is kept until its request ends: released
   mid-request, it drops it. */
static NSMutableArray *TXLiveExtensions;

@implementation TXStikJITTransport {
    TXStikJITTXMStatus _lastTXMStatus;
}

+ (instancetype)shared {
    static TXStikJITTransport *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[TXStikJITTransport alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) _lastTXMStatus = TXStikJITTXMStatusUnknown;
    return self;
}

- (nullable NSString *)helperBundleIdentifier {
    NSURL *url = [[NSBundle.mainBundle.builtInPlugInsURL
        URLByAppendingPathComponent:kTXJITHelperAppexName] standardizedURL];
    return [NSBundle bundleWithURL:url].bundleIdentifier;
}

- (BOOL)helperAvailable {
    // YES only when the helper extension is embedded in this app.
    // It does not prove iOS will launch it (in LiveContainer the
    // coordinator never asks); a launch failure still reports why.
    return [self helperBundleIdentifier] != nil;
}

- (TXStikJITTXMStatus)txmSPTMStatus {
    @synchronized (self) { return _lastTXMStatus; }
}

- (void)noteTXMStatusFromSummary:(NSString *)summary {
    // The helper reports TXM presence inside the prepare summary
    // ("ready, TXM present" / "ready, no TXM" / "ready, TXM
    // unknown"); there is no separate machine-readable key.
    TXStikJITTXMStatus status = TXStikJITTXMStatusUnknown;
    if ([summary rangeOfString:@"TXM present"].location != NSNotFound) {
        status = TXStikJITTXMStatusPresent;
    } else if ([summary rangeOfString:@"no TXM"].location != NSNotFound) {
        status = TXStikJITTXMStatusNotPresent;
    }
    @synchronized (self) { _lastTXMStatus = status; }
}

- (NSError *)errorWithCode:(TXStikJITTransportError)code description:(NSString *)description {
    return [NSError errorWithDomain:TXStikJITTransportErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

/* Starts the helper extension with `request` as its input item's
   userInfo, and calls `done` once: with the reply item's userInfo,
   or with nil and why there wasn't one. `done` may run on any
   thread; callers dispatch to main. Exactly one of the blocks
   below answers, whichever comes first. */
- (void)helperRequest:(NSDictionary *)request
                 done:(void (^)(NSDictionary *_Nullable reply, NSString *_Nullable failure))done {
    NSString *identifier = [self helperBundleIdentifier];
    if (!identifier) {
        done(nil, @"TermX's JIT helper is missing from the app.");
        return;
    }
    Class extensionClass = NSClassFromString(@"NSExtension");
    if (!extensionClass) {
        dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
        extensionClass = NSClassFromString(@"NSExtension");
    }
    if (!extensionClass) {
        done(nil, @"iOS has no way to start TermX's JIT helper.");
        return;
    }
    NSError *error = nil;
    id extension = [extensionClass extensionWithIdentifier:identifier error:&error];
    if (!extension) {
        done(nil, [NSString stringWithFormat:@"iOS wouldn't find TermX's JIT helper (%@).",
                   error.localizedDescription ?: @"no reason given"]);
        return;
    }
    @synchronized (NSMutableArray.class) {
        if (!TXLiveExtensions) TXLiveExtensions = [NSMutableArray array];
        [TXLiveExtensions addObject:extension];
    }

    NSObject *lock = [NSObject new];
    __block BOOL answered = NO;
    void (^finish)(NSDictionary *, NSString *) = ^(NSDictionary *reply, NSString *failure) {
        @synchronized (lock) {
            if (answered) return;
            answered = YES;
        }
        @synchronized (NSMutableArray.class) {
            [TXLiveExtensions removeObject:extension];
        }
        done(reply, failure);
    };
    [extension setRequestCompletionBlock:^(NSUUID *requestID, NSArray *items) {
        NSExtensionItem *item = items.firstObject;
        NSDictionary *reply = [item isKindOfClass:NSExtensionItem.class] ? (NSDictionary *)item.userInfo : nil;
        finish(reply ?: @{}, nil);
    }];
    [extension setRequestCancellationBlock:^(NSUUID *requestID, NSError *cancelError) {
        finish(nil, [NSString stringWithFormat:@"The JIT helper was cancelled (%@).",
                     cancelError.localizedDescription ?: @"no reason given"]);
    }];
    [extension setRequestInterruptionBlock:^(NSUUID *requestID) {
        finish(nil, @"The JIT helper stopped before it answered.");
    }];

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = request;
    [extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *requestID) {
        if (!requestID) finish(nil, @"iOS wouldn't start TermX's JIT helper.");
    }];
}

/* Sends one op to the helper and completes with its result.
   `progress` gets the helper's log lines when the reply arrives
   (there is no streaming channel); `completion` always runs on
   the main queue. */
- (void)runOp:(NSString *)op
          pid:(pid_t)pid
  pairingData:(nullable NSData *)pairingData
  forceScript:(BOOL)forceScript
     progress:(nullable TXStikJITProgressHandler)progress
   completion:(TXStikJITCompletionHandler)completion {
    if (([op isEqualToString:@"enable"] || [op isEqualToString:@"prepare"]) &&
        (!pairingData || pairingData.length == 0)) {
        NSError *error = [self errorWithCode:TXStikJITTransportErrorInvalidRequest
                                 description:@"No pairing file"];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([TXStikJITTransportResult failureWithError:error statusText:@"No pairing file"]);
        });
        return;
    }
    NSMutableDictionary *request = [NSMutableDictionary dictionary];
    request[@"op"] = op;
    if ([op isEqualToString:@"enable"]) request[@"pid"] = @(pid);
    if (pairingData) request[@"pairing"] = pairingData;
    if ([op isEqualToString:@"enable"]) request[@"forceScript"] = @(forceScript);
    [self helperRequest:request done:^(NSDictionary *reply, NSString *failure) {
        // Forward the helper's log lines as progress, then complete.
        NSArray *log = reply[@"log"];
        if ([log isKindOfClass:NSArray.class]) {
            for (id line in log) {
                if (![line isKindOfClass:NSString.class]) continue;
                if (!progress) break;
                NSString *stage = (NSString *)line;
                dispatch_async(dispatch_get_main_queue(), ^{ progress(stage); });
            }
        }
        TXStikJITTransportResult *result;
        if (failure) {
            NSError *error = [self errorWithCode:TXStikJITTransportErrorHelperUnavailable
                                     description:failure];
            result = [TXStikJITTransportResult failureWithError:error statusText:failure];
        } else {
            BOOL ok = [reply[@"ok"] boolValue];
            NSString *summary = reply[@"summary"];
            if (![summary isKindOfClass:NSString.class] || summary.length == 0) {
                summary = ok ? @"Done" : @"The JIT helper gave no result.";
            }
            if ([op isEqualToString:@"prepare"]) [self noteTXMStatusFromSummary:summary];
            if (ok) {
                result = [TXStikJITTransportResult successWithStatusText:summary];
            } else {
                NSError *error = [self errorWithCode:TXStikJITTransportErrorHelperUnavailable
                                         description:summary];
                result = [TXStikJITTransportResult failureWithError:error statusText:summary];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    }];
}

- (void)prepareJITWithPID:(pid_t)pid
              pairingData:(NSData *)pairingData
              forceScript:(BOOL)forceScript
                 progress:(TXStikJITProgressHandler)progress
               completion:(TXStikJITCompletionHandler)completion {
    [self runOp:@"prepare" pid:pid pairingData:pairingData
         forceScript:forceScript progress:progress completion:completion];
}

- (void)enableJITWithPID:(pid_t)pid
             pairingData:(NSData *)pairingData
             forceScript:(BOOL)forceScript
                progress:(TXStikJITProgressHandler)progress
              completion:(TXStikJITCompletionHandler)completion {
    [self runOp:@"enable" pid:pid pairingData:pairingData
         forceScript:forceScript progress:progress completion:completion];
}

- (void)resetCachedDDIWithCompletion:(TXStikJITCompletionHandler)completion {
    [self runOp:@"reset" pid:0 pairingData:nil
         forceScript:NO progress:nil completion:completion];
}

@end
