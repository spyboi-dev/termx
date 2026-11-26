// TXPairingStore - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXPairingStore.h"
#import "TXLog.h"
#import <Security/Security.h>

NSString *const kTXPairingStoreService = @"TermXJITPairing";
NSString *const kTXPairingStoreAccount = @"rppairing";
static NSString *const kTXPairingSourceDefaultsKey = @"termx.jitPairingSource";
static NSString *const kTXPairingSourceOnDeviceValue = @"onDevice";
static NSString *const kTXPairingSourceImportedValue = @"imported";

static NSString *const kTXPairingStoreErrorDomain = @"TXPairingStoreErrorDomain";

@implementation TXPairingStore

+ (instancetype)shared {
    static TXPairingStore *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[TXPairingStore alloc] init]; });
    return instance;
}

+ (NSURL *)legacyPairingFileURL {
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    return [[documents URLByAppendingPathComponent:@"StikJIT"]
        URLByAppendingPathComponent:@"pairingFile.plist"];
}

- (NSDictionary *)keychainQuery {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kTXPairingStoreService,
        (__bridge id)kSecAttrAccount: kTXPairingStoreAccount,
    };
}

- (BOOL)pairingStored {
    return [self pairingData] != nil;
}

- (TXPairingSource)pairingSource {
    if (![self pairingStored]) return TXPairingSourceNone;
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:kTXPairingSourceDefaultsKey];
    if ([stored isEqualToString:kTXPairingSourceOnDeviceValue]) return TXPairingSourceOnDevice;
    // Pairings stored before the source was recorded were all imported.
    return TXPairingSourceImported;
}

- (NSData *)pairingData {
    [self moveLegacyFileIntoKeychain];
    NSMutableDictionary *query = [[self keychainQuery] mutableCopy];
    query[(__bridge id)kSecReturnData] = (__bridge id)kCFBooleanTrue;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == NULL) return nil;
    NSData *data = [(__bridge NSData *)result length] > 0 ? (__bridge NSData *)result : nil;
    if (result != NULL) CFRelease(result);
    return data;
}

- (BOOL)storePairingData:(NSData *)data
                  source:(TXPairingSource)source
                   error:(NSError **)error {
    if (![self isValidPairingData:data]) {
        if (error) {
            *error = [NSError errorWithDomain:kTXPairingStoreErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"That is not a remote pairing file."}];
        }
        return NO;
    }
    // Delete first, then add: SecItemAdd fails on a duplicate item.
    SecItemDelete((__bridge CFDictionaryRef)[self keychainQuery]);
    NSMutableDictionary *item = [[self keychainQuery] mutableCopy];
    item[(__bridge id)kSecValueData] = data;
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:kTXPairingStoreErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:
                                             @"The pairing could not be saved in the Keychain (%d). Unlock this device and try again.",
                                             (int)status]}];
        }
        return NO;
    }
    NSString *value = (source == TXPairingSourceOnDevice)
        ? kTXPairingSourceOnDeviceValue : kTXPairingSourceImportedValue;
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kTXPairingSourceDefaultsKey];
    return YES;
}

- (void)deletePairing {
    SecItemDelete((__bridge CFDictionaryRef)[self keychainQuery]);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kTXPairingSourceDefaultsKey];
}

// An RPPairing plist: a dictionary with 32-byte public_key and
// private_key and a non-empty identifier.
- (BOOL)isValidPairingData:(NSData *)data {
    if (!data || data.length == 0) return NO;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:0
                                                          format:NULL
                                                           error:nil];
    if (![plist isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *dict = (NSDictionary *)plist;
    NSData *publicKey = dict[@"public_key"];
    NSData *privateKey = dict[@"private_key"];
    NSString *identifier = dict[@"identifier"];
    return [publicKey isKindOfClass:[NSData class]] && publicKey.length == 32
        && [privateKey isKindOfClass:[NSData class]] && privateKey.length == 32
        && [identifier isKindOfClass:[NSString class]] && identifier.length > 0;
}

- (void)moveLegacyFileIntoKeychain {
    NSURL *file = [[self class] legacyPairingFileURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:file.path]) return;
    NSData *data = [NSData dataWithContentsOfURL:file options:0 error:nil];
    if (!data) return;
    // The legacy file predates source tracking; it was imported.
    TXPairingSource source = TXPairingSourceImported;
    NSString *recorded = [[NSUserDefaults standardUserDefaults] stringForKey:kTXPairingSourceDefaultsKey];
    if ([recorded isEqualToString:kTXPairingSourceOnDeviceValue]) source = TXPairingSourceOnDevice;
    // Deleted only once the Keychain holds it (a locked device
    // keeps it for later).
    NSError *storeError = nil;
    if ([self storePairingData:data source:source error:&storeError]) {
        [fm removeItemAtURL:file error:nil];
        NSURL *folder = [file URLByDeletingLastPathComponent];
        if ([[fm contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil] count] == 0) {
            [fm removeItemAtURL:folder error:nil];
        }
        TXLogEngine(@"StikJIT pairing moved from Documents into the Keychain");
    } else {
        TXLogEngine(@"StikJIT pairing migration failed: %@", storeError.localizedDescription ?: @"unknown");
    }
}

@end
