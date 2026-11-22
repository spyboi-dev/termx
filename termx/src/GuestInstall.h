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
// rootfs-build/termx-debian-trixie-arm64-slim.ext4.gz there before the first
// install from the app (see BUILD-NOTE.md).
//
// Download survival: the download runs on a background NSURLSession, so
// it keeps going when the phone locks or the app is suspended, and the
// system wakes the app when it finishes. If the app is killed mid
// download, the next Install resumes from the saved resume data instead
// of restarting from zero. An already-downloaded archive whose hash
// checks out is reused instead of downloaded again. Every milestone —
// each 10% of the download, each 256 MiB of extract/verify, every
// memory warning — is written to engine.log with the byte count, so a
// crash during the install leaves the exact phase and position behind.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

extern NSString* const kRootfsURL;        // .ext4.gz download URL
extern NSString* const kRootfsName;       // termx-debian-trixie-arm64.ext4
extern NSString* const kRootfsGzSHA256;   // SHA-256 of the .ext4.gz
extern NSString* const kRootfsSHA256;     // SHA-256 of the extracted .ext4
extern const long long kRootfsSize;       // bytes of the extracted image

@interface GuestInstall : NSObject

// Cheap: true when rootfsPath exists, has the expected size, and
// either matches the fingerprint recorded when the pipeline last
// hash-verified it, or hashes to kRootfsSHA256 on a one-time check.
// Never re-hashes on every call — the startup screen polls this
// twice a second.
+ (BOOL)guestInstalledAt:(NSString*)rootfsPath error:(NSString**)error;

// Full SHA-256 of the extracted image against kRootfsSHA256, and
// record the verified fingerprint on success. Expensive (reads
// 1 GiB) — never on the poll timer or the main thread. The install
// pipeline's one-time verify, and the launch re-verify in the
// timing diagnostic (KernEngine reverifyImageForLaunch).
+ (BOOL)guestImageHashValidAt:(NSString*)rootfsPath error:(NSString**)error;

// Download + verify + extract the image to rootfsPath.
// Calls progress(0..1, step, receivedBytes, expectedBytes) on the
// main queue. received/expected are the download byte counts while
// the archive is downloading, 0 for the verify/extract steps.
// If the user cancels, completion is called with ok=NO and
// error=@"cancelled" (the exact string; the engine turns that into
// the Idle state, not a failure).
+ (void)installGuestTo:(NSString*)rootfsPath
              progress:(void (^)(double fraction, NSString* step, int64_t received, int64_t expected))progress
            completion:(void (^)(BOOL ok, NSString* error))completion;

// Cancel the in-flight download, if any, saving resume data so the
// next Install continues where this one stopped.
+ (void)cancelDownload;

// Re-attach to the background session after the system wakes the app
// for a finished background download (AppDelegate's
// handleEventsForBackgroundURLSession). The stored completion
// handler is called once the session has delivered all its events.
+ (void)reconnectBackgroundSessionWithCompletionHandler:(void (^)(void))handler;

@end
