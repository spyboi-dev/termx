// GuestInstall: fetch the Debian rootfs image for KTerm's Linux guest and
// place it where the runtime boots it from.
//
// The image is a plain ext4 file, built from Debian trixie arm64
// (see ../rootfs-build/). The runtime requires the file to end in .ext4
// and to carry NO write permission bits, so the install chmods it 0444
// (upstream KernariumRuntime.mm: immutableExt4Rootfs). It is delivered
// gzipped; both the archive and the extracted image are checked against
// their SHA-256. If the image is already in place with the right hash —
// for example dropped into Documents/guest/ with the Files app — no
// download happens at all.
//
// The download URL is the release the image is published under. Publish
// rootfs-build/termx-debian-trixie-arm64.ext4.gz there before the first
// install from the app (see BUILD-NOTE.md).
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

extern NSString* const kRootfsURL;        // .ext4.gz download URL
extern NSString* const kRootfsName;       // termx-debian-trixie-arm64.ext4
extern NSString* const kRootfsGzSHA256;   // SHA-256 of the .ext4.gz
extern NSString* const kRootfsSHA256;     // SHA-256 of the extracted .ext4
extern const long long kRootfsSize;       // bytes of the extracted image

@interface GuestInstall : NSObject

// True when rootfsPath exists, has the expected size, and hashes to
// kRootfsSHA256.
+ (BOOL)guestInstalledAt:(NSString*)rootfsPath error:(NSString**)error;

// Download + verify + extract the image to rootfsPath.
// Calls progress(0..1, step) on the main queue.
+ (void)installGuestTo:(NSString*)rootfsPath
              progress:(void (^)(double fraction, NSString* step))progress
            completion:(void (^)(BOOL ok, NSString* error))completion;

@end
