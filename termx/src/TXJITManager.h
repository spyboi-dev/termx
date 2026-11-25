// TXJITManager - Swipt-style native JIT support (client only).
//
// TermX's guest runs natively on the Kernarium kernel, so the engine
// needs no JIT. But JIT *inside* the guest (Node.js V8, JVM, ...) can
// not run: the host process may not map PROT_EXEC memory without the
// JIT entitlement, and TermX is ad-hoc signed with none. Swipterm
// solves the same problem with Swipt: a separate helper app on the
// phone that attaches to the process like a debugger and flips JIT
// on. This manager is the client side of that protocol, ported from
// Swipterm's SwiptJIT / SwiptClient (Swift) to Objective-C:
//
//   - Bonjour discovery of the Swipt server (_swipt._tcp, local
//     only). The server advertises a TXT record; auth=1 means it
//     requires a Bearer token, and a udid key means it is for a
//     different device and is ignored.
//   - A gRPC-web POST to swipt.DeviceService/EnableJIT with this
//     app's bundle ID and pid, after a GetInfo probe that checks the
//     server is reachable and whether auth is needed.
//   - Nothing is bundled or built here: the user must have the
//     separate Swipt app installed and running on the phone for the
//     toggle to find a server.
//
// The enabled flag persists in NSUserDefaults ("termx.jitEnabled",
// default YES, matching Swipterm) and the token in
// "termx.swiptToken". All state changes post
// TXJITManagerStatusDidChangeNotification on the main thread.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

extern NSString *const TXJITManagerStatusDidChangeNotification;

@interface TXJITManager : NSObject

+ (instancetype)shared;

// The persisted toggle (NSUserDefaults "termx.jitEnabled", default
// YES). When on and a Swipt server is found, EnableJIT is called
// automatically.
@property (nonatomic, readonly) BOOL jitEnabled;

// YES once the Swipt server confirmed EnableJIT for this launch.
@property (nonatomic, readonly) BOOL jitActive;

// YES when the discovered server requires a Bearer token.
@property (nonatomic, readonly) BOOL requiresToken;

// The saved token (NSUserDefaults "termx.swiptToken"), empty if none.
@property (nonatomic, readonly, copy) NSString *swiptToken;

// Human-readable status for the About card.
@property (nonatomic, readonly, copy) NSString *statusText;

- (void)setJITEnabled:(BOOL)enabled;
- (void)setSwiptToken:(NSString *)token;
// (Re)start discovery and, if a server is known and the toggle is
// on, retry the connect/enable flow.
- (void)refresh;

@end
