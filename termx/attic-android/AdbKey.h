// AdbKey: the host ADB keypair.
// The Kernarium boot authorizes one adb host key (android_adb_public_key:
// base64 of the PKCS#1 RSAPublicKey DER). adbd then challenges us with a
// 20-byte token, which we answer with an RSA PKCS#1 v1.5 SHA-1 signature.
// The pair lives in the keychain so the guest sees the same host every boot.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

@interface AdbKey : NSObject
// Base64 of the PKCS#1 RSAPublicKey DER, as adb writes it (no comment).
+ (NSString*)publicKeyBase64;
// Sign the 20-byte ADB auth token. Returns the signature, or nil.
+ (NSData*)signToken:(NSData*)token;
@end
