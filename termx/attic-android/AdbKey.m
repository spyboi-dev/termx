// SPDX-License-Identifier: GPL-2.0-or-later
#import "AdbKey.h"
#import <Security/Security.h>

static NSString* const kTag = @"app.kterm.ios.adbkey";

// --- tiny DER walker: pull the PKCS#1 RSAPublicKey out of an SPKI blob ---
// SPKI = SEQ { SEQ { OID, NULL }, BIT STRING { RSAPublicKey } }.
// Returns the inner RSAPublicKey DER, or nil.
static NSData* RSAPublicKeyFromSPKI(NSData* spki) {
    const uint8_t* p = spki.bytes;
    size_t len = spki.length, off = 0;
    // read one TLV; returns content offset/length, advances off past it
    // (long-form lengths handled)
    if (len < 2 || p[off++] != 0x30) return nil; // outer SEQ
    size_t outerLen = p[off++];
    if (outerLen & 0x80) {
        int n = (int)(outerLen & 0x7f);
        if (n < 1 || n > 2 || off + n > len) return nil;
        outerLen = 0;
        for (int i = 0; i < n; i++) outerLen = (outerLen << 8) | p[off++];
    }
    if (off + outerLen > len) return nil;
    // algorithm SEQ: skip it
    if (off >= len || p[off++] != 0x30) return nil;
    size_t algLen = p[off++];
    if (algLen & 0x80) {
        int n = (int)(algLen & 0x7f);
        if (n < 1 || n > 2 || off + n > len) return nil;
        algLen = 0;
        for (int i = 0; i < n; i++) algLen = (algLen << 8) | p[off++];
    }
    off += algLen;
    // BIT STRING
    if (off >= len || p[off++] != 0x03) return nil;
    size_t bitLen = p[off++];
    if (bitLen & 0x80) {
        int n = (int)(bitLen & 0x7f);
        if (n < 1 || n > 2 || off + n > len) return nil;
        bitLen = 0;
        for (int i = 0; i < n; i++) bitLen = (bitLen << 8) | p[off++];
    }
    if (off >= len || p[off++] != 0x00) return nil; // unused-bits byte
    bitLen -= 1;
    if (off + bitLen > len) return nil;
    return [NSData dataWithBytes:p + off length:bitLen];
}

static SecKeyRef GetOrCreatePrivateKey(void) {
    NSDictionary* query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassKey,
        (__bridge id)kSecAttrApplicationTag: [kTag dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecReturnRef: @YES,
    };
    CFTypeRef item = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &item) == errSecSuccess) {
        return (SecKeyRef)item;
    }
    NSDictionary* attrs = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeySizeInBits: @2048,
        (__bridge id)kSecAttrApplicationTag: [kTag dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };
    SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs, NULL);
    if (!key) return NULL;
    // Store it persistently under the tag.
    NSDictionary* add = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassKey,
        (__bridge id)kSecAttrApplicationTag: [kTag dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecValueRef: (__bridge id)key,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    return key;
}

@implementation AdbKey

+ (NSString*)publicKeyBase64 {
    SecKeyRef priv = GetOrCreatePrivateKey();
    if (!priv) return nil;
    SecKeyRef pub = SecKeyCopyPublicKey(priv);
    CFRelease(priv);
    if (!pub) return nil;
    CFErrorRef err = NULL;
    NSData* spki = (__bridge_transfer NSData*)SecKeyCopyExternalRepresentation(pub, &err);
    CFRelease(pub);
    if (!spki) return nil;
    NSData* pkcs1 = RSAPublicKeyFromSPKI(spki);
    if (!pkcs1) return nil;
    return [pkcs1 base64EncodedStringWithOptions:0];
}

+ (NSData*)signToken:(NSData*)token {
    SecKeyRef priv = GetOrCreatePrivateKey();
    if (!priv) return nil;
    CFErrorRef err = NULL;
    NSData* sig = (__bridge_transfer NSData*)SecKeyCreateSignature(
        priv, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1,
        (__bridge CFDataRef)token, &err);
    CFRelease(priv);
    return sig;
}

@end
