// AdbClient: a minimal ADB host over a connected socket (the runtime's
// vsock to the guest's adbd on port 5555). Implements only what installing
// Termux needs: CNXN + RSA auth, shell commands, and sync push.
// The socket is owned by the caller and is NOT closed here.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

@interface AdbClient : NSObject

- (instancetype)initWithFD:(int)fd;

// Full connect: CNXN, answer the AUTH token with our RSA signature,
// return YES once the device's CNXN arrives. Error string on failure.
- (BOOL)connectWithError:(NSString**)error;

// Run a shell command in the guest; returns its combined output, or nil.
- (NSString*)shell:(NSString*)command timeout:(NSTimeInterval)timeout error:(NSString**)error;

// Push a local file to the guest path (mode e.g. 0644). YES on OKAY.
- (BOOL)pushFile:(NSString*)localPath to:(NSString*)remotePath mode:(int)mode
        progress:(void (^)(double fraction))progress error:(NSString**)error;

- (void)close;

@end
