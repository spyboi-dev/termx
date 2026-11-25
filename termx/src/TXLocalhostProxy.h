// TXLocalhostProxy - the app half of TermX's localhost proxy.
//
// A service listening on 127.0.0.1:PORT inside the guest is not
// reachable from the iPhone: the guest sits behind slirp NAT,
// outbound only, and the runtime's public API has no port-forward
// call. The runtime does expose a vsock stream to the guest, so
// this proxy listens on the iPhone's 127.0.0.1:PORT for each
// configured port and forwards each connection over vsock to the
// guest bridge (tx-vsock-bridge, vsock 5999), which forwards it to
// guest 127.0.0.1:PORT. The result is that a guest localhost
// service answers at the iPhone's localhost, the way it would on a
// native OS — for any port, any tool, any agent.
//
// The proxy runs only while the guest is up: KernEngine starts it
// when the guest reaches Running and stops it when the guest stops.
// While it is stopped, nothing listens on the iPhone's localhost,
// so Safari gets a clean "connection refused", the way it would on
// a native OS with no service running.
//
// Protocol (proxy -> bridge, over one vsock stream per TCP connection):
//   2 bytes, big-endian uint16_t: the target TCP port.
// Then both sides shuttle bytes until either closes. If the guest
// has nothing on that port the bridge closes the vsock stream, and
// the proxy closes the iPhone side cleanly.
//
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import "KernariumRuntime.h"

NS_ASSUME_NONNULL_BEGIN

@interface TXLocalhostProxy : NSObject

// The ports forwarded while the guest is up, as the user configured
// them (NSUserDefaults "termx.localhostPorts"). When nothing is
// saved yet, the default set below. Ports are sorted, unique, and
// in 1...65535; anything else is dropped on read.
+ (NSArray<NSNumber *> *)configuredPorts;
+ (void)setConfiguredPorts:(NSArray<NSNumber *> *)ports;

// Start listening on 127.0.0.1 for each configured port. The api
// pointer must stay valid while the proxy runs (it is the engine's
// loaded runtime). Calling start while running restarts with the
// current configured ports. Safe to call from any thread.
- (void)startWithAPI:(const kernarium_runtime_api *)api;
// Stop all listeners. In-flight proxied connections are closed.
- (void)stop;

@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *ports;

@end

NS_ASSUME_NONNULL_END
