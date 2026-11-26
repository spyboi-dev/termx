// TXLoopbackProbe - whether LocalDevVPN's loopback reaches this
// device's lockdownd at 10.7.0.1:62078 (the address StikJIT uses).
//
// Two steps, neither depending on what lockdownd says:
//   1. The route: the interface traffic to 10.7.0.1 would leave by,
//      asked of the kernel with an unsent UDP connect (no packets).
//      It must be a VPN interface (utun/ipsec/ppp) whose address is
//      in LocalDevVPN's 10.7.0.0/16 range: another VPN carrying all
//      traffic also routes 10.7.0.1, but the helper then reads an
//      early EOF.
//   2. Through the tunnel: a TCP connection, at most 0.4 s. Through
//      a working tunnel it opens in milliseconds; over cellular data,
//      where the tunnel does not work, it fails. Nothing is sent,
//      and it is closed at once.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TXLoopbackProbeResult : NSObject

@property (nonatomic, readonly) BOOL reachable;
@property (nonatomic, readonly) double milliseconds;
@property (nonatomic, readonly, copy) NSString *detail;
@property (nonatomic, readonly, copy, nullable) NSString *interfaceName;
@property (nonatomic, readonly, copy, nullable) NSString *localAddress;
// The route leaves by a VPN interface (utun/ipsec/ppp).
@property (nonatomic, readonly) BOOL routedViaVPN;
// The route leaves by LocalDevVPN's own tunnel (VPN interface with
// an address in 10.7.0.0/16).
@property (nonatomic, readonly) BOOL routedViaLocalDevVPN;

@end

@interface TXLoopbackProbe : NSObject

// Blocks for at most `timeout` (default 0.4 s); call off the main
// thread, or use the async variant.
+ (TXLoopbackProbeResult *)checkWithTimeout:(NSTimeInterval)timeout;
+ (void)checkWithTimeout:(NSTimeInterval)timeout
              completion:(void (^)(TXLoopbackProbeResult *result))completion;

// Checks again until the loopback answers or `within` seconds pass:
// a VPN that was just connected needs a moment before it routes.
+ (void)waitUntilReachableWithin:(NSTimeInterval)within
                      completion:(void (^)(TXLoopbackProbeResult *result))completion;

// LocalDevVPN is connected: traffic to 10.7.0.1 leaves by its
// tunnel. Instant: no network traffic.
+ (BOOL)vpnInterfaceUp;

@end

NS_ASSUME_NONNULL_END
