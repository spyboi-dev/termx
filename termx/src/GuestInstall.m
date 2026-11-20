// SPDX-License-Identifier: GPL-2.0-or-later
#import "GuestInstall.h"
#import <CommonCrypto/CommonDigest.h>
#import <zlib.h>

// Guest image: Debian trixie arm64, built 2026-11-20 (see rootfs-build/).
// The .gz must be published at kRootfsURL before first use from the app;
// the app refuses an image whose hash does not match.
NSString* const kRootfsURL =
    @"https://github.com/spyboi-dev/termx/releases/download/rootfs-20261120/termx-debian-trixie-arm64.ext4.gz";
NSString* const kRootfsName = @"termx-debian-trixie-arm64.ext4";
NSString* const kRootfsGzSHA256 = @"7bc05dcf82a48d7b1f04413c2d3a8c3cafa5ea4450cc2284b82725e7aba79676";
NSString* const kRootfsSHA256 = @"a11e2dd31cce3ab20630b48ff288586b9cc6691a7cf1992ff7d0193b00ba2f14";
const long long kRootfsSize = 1728053248; // extracted image size in bytes (1,648 MiB)

static NSString* SHA256OfFile(NSString* path, NSError** outError) {
    NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        if (outError) *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        return nil;
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (YES) {
        NSData* chunk = [handle readDataOfLength:1 << 20];
        if (chunk.length == 0) break;
        CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
    }
    [handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static BOOL FileHasHash(NSString* path, NSString* expected) {
    NSError* error = nil;
    NSString* hash = SHA256OfFile(path, &error);
    return hash && [hash isEqualToString:expected];
}

@implementation GuestInstall

+ (BOOL)guestInstalledAt:(NSString*)rootfsPath error:(NSString**)error {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSDictionary* attrs = [fm attributesOfItemAtPath:rootfsPath error:nil];
    if (!attrs) {
        if (error) *error = @"guest image is not installed";
        return NO;
    }
    if (kRootfsSize > 0 && [attrs fileSize] != kRootfsSize) {
        if (error) *error = @"guest image has the wrong size — reinstall";
        return NO;
    }
    if (!FileHasHash(rootfsPath, kRootfsSHA256)) {
        if (error) *error = @"guest image hash mismatch — reinstall";
        return NO;
    }
    return YES;
}

// Streaming gunzip of src (.gz) to dst. Returns NO with *error set on
// failure; the caller checks the hashes.
+ (BOOL)gunzipFile:(NSString*)src to:(NSString*)dst error:(NSString**)error {
    gzFile gz = gzopen(src.UTF8String, "rb");
    if (!gz) {
        if (error) *error = @"could not open the downloaded archive";
        return NO;
    }
    FILE* out = fopen(dst.UTF8String, "wb");
    if (!out) {
        gzclose(gz);
        if (error) *error = @"could not write the guest image";
        return NO;
    }
    uint8_t buffer[1 << 20];
    int n;
    BOOL ok = YES;
    while ((n = gzread(gz, buffer, (unsigned)sizeof(buffer))) > 0) {
        if (fwrite(buffer, 1, (size_t)n, out) != (size_t)n) { ok = NO; break; }
    }
    if (n < 0) ok = NO;
    fclose(out);
    gzclose(gz);
    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        if (error) *error = @"the downloaded archive is corrupt";
    }
    return ok;
}

+ (void)installGuestTo:(NSString*)rootfsPath
              progress:(void (^)(double, NSString*))progress
            completion:(void (^)(BOOL, NSString*))completion {
    NSString* error = nil;
    if ([self guestInstalledAt:rootfsPath error:&error]) {
        if (completion) completion(YES, nil);
        return;
    }
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* guestDir = [rootfsPath stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:guestDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* tmpDir = NSTemporaryDirectory();
    NSString* gzPath = [tmpDir stringByAppendingPathComponent:@"kterm-rootfs.ext4.gz"];
    [fm removeItemAtPath:gzPath error:nil];
    [fm removeItemAtPath:rootfsPath error:nil];

    NSURL* url = [NSURL URLWithString:kRootfsURL];
    NSURLSession* session = [NSURLSession sharedSession];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (progress) progress(0.0, @"Downloading Debian image…");
    });
    NSURLSessionDownloadTask* task =
        [session downloadTaskWithURL:url completionHandler:^(NSURL* location, NSURLResponse* response, NSError* taskError) {
            if (taskError || !location) {
                if (completion) completion(NO, @"download failed — check Wi-Fi and try again");
                return;
            }
            NSError* moveError = nil;
            [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:gzPath] error:&moveError];
            if (moveError) {
                if (completion) completion(NO, @"could not save the download");
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress) progress(0.6, @"Verifying the download…");
            });
            if (!FileHasHash(gzPath, kRootfsGzSHA256)) {
                [fm removeItemAtPath:gzPath error:nil];
                if (completion) completion(NO, @"download hash mismatch — the file may be corrupt, try again");
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress) progress(0.7, @"Extracting the image…");
            });
            NSString* extractError = nil;
            if (![self gunzipFile:gzPath to:rootfsPath error:&extractError]) {
                if (completion) completion(NO, extractError);
                return;
            }
            [fm removeItemAtPath:gzPath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress) progress(0.95, @"Verifying the image…");
            });
            NSString* verifyError = nil;
            if (![self guestInstalledAt:rootfsPath error:&verifyError]) {
                [fm removeItemAtPath:rootfsPath error:nil];
                if (completion) completion(NO, verifyError ?: @"image verification failed");
                return;
            }
            // The runtime requires a read-only image: no write bits at all.
            NSDictionary* attrs = @{NSFilePosixPermissions : @(0444)};
            [fm setAttributes:attrs ofItemAtPath:rootfsPath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress) progress(1.0, @"Guest ready");
            });
            if (completion) completion(YES, nil);
        }];
    // NSURLSessionDownloadTask does not report progress to the completion
    // handler, so a watcher thread polls the task's byte counts instead.
    [task resume];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (task.state == NSURLSessionTaskStateRunning) {
            int64_t received = task.countOfBytesReceived;
            int64_t expected = task.countOfBytesExpectedToReceive;
            if (expected > 0) {
                double f = (double)received / (double)expected * 0.6;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (progress) progress(f, @"Downloading Debian image…");
                });
            }
            [NSThread sleepForTimeInterval:0.25];
        }
    });
}

@end
