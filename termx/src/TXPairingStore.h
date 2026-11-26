// TXPairingStore - where Built-in StikJIT's pairing bytes live.
//
// The pairing file is a credential for the device itself, so it
// lives in the Keychain (generic password, this device only, while
// unlocked) and never in Documents, where the Files app could read
// it. Its bytes go only to the bundled helper, over the transport,
// for one request.
//
// A copy an earlier build left at Documents/StikJIT/pairingFile.plist
// moves into the Keychain on first read and is deleted; an installer
// that already holds this device's pairing file hands it over by
// writing it there. Importing a file stores it in the Keychain too.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Where the stored pairing came from.
typedef NS_ENUM(NSInteger, TXPairingSource) {
    TXPairingSourceNone = 0,
    // Paired on this iPhone (TXOnDevicePairing, iOS 27).
    TXPairingSourceOnDevice,
    // Imported from a file made on a computer.
    TXPairingSourceImported,
};

@interface TXPairingStore : NSObject

+ (instancetype)shared;

// YES when pairing bytes are stored (Keychain, or a legacy file
// waiting to be migrated in).
- (BOOL)pairingStored;
- (TXPairingSource)pairingSource;

// The stored pairing bytes, or nil. Migrates a legacy
// Documents/StikJIT/pairingFile.plist into the Keychain first and
// deletes the file once the Keychain holds it. Never logged.
- (nullable NSData *)pairingData;

// Validates an RPPairing plist (public_key/private_key, 32 bytes
// each, plus a non-empty identifier) and stores it in the Keychain,
// replacing any stored pairing. Returns NO with an error when the
// data is not a pairing file or the Keychain refuses it.
- (BOOL)storePairingData:(NSData *)data
                  source:(TXPairingSource)source
                   error:(NSError **)error;

// Deletes the stored pairing and its recorded source.
- (void)deletePairing;

// Documents/StikJIT/pairingFile.plist: the legacy location, kept
// only so the migration above can find it.
+ (NSURL *)legacyPairingFileURL;

@end

NS_ASSUME_NONNULL_END
