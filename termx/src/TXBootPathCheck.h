// TXBootPathCheck — replicate the Kernarium runtime's exact Linux path
// checks, on the exact C strings handed to run().
//
// The 14:02 run failed with the runtime's own line "Kernarium: invalid
// rootfs or overlay path" while the app's stat()-based pre-flight passed
// on the same paths in the same process. The runtime's checks
// (KernariumRuntime.mm, usableFile / immutableExt4Rootfs) are
// std::filesystem calls, not stat(), so this file repeats them with
// std::filesystem, on the boot struct's own C strings, immediately
// before run() — each check logged separately with its result and the
// std::error_code message, so the next device log names which check
// the runtime would fail, or proves the runtime sees different bytes
// than the app does.
//
// The C++ standard library headers of the iOS 26.5 SDK need builtins
// (__builtin_ctzg / __builtin_clzg) that clang-18 does not provide,
// so this one file is compiled with the 16.5 SDK's C++ headers (see
// build.sh); the std::filesystem ABI in libc++.dylib is stable across
// these SDKs.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// C linkage: KernEngine.m (Objective-C) calls these, and this file's
// implementation TU is C++ — without this the names mangle and the
// link fails.
#ifdef __cplusplus
extern "C" {
#endif

// Replicates, in the runtime's order, usableFile(rootfs),
// immutableExt4Rootfs(rootfs), usableFile(overlay), using
// std::filesystem exactly as the runtime does. Logs every check with
// its result and the error_code message. Returns YES only if the
// runtime's combined check would pass.
BOOL TXCheckBootPathsExact(const char *rootfsPath, const char *overlayPath);

// Logs one boot-struct C string at run() time: pointer address,
// strlen, the full bytes, and a hex dump of the first 32 bytes, so a
// dangling or garbage pointer — or an embedded NUL — is visible.
// expectedLength is the UTF-8 byte length the app's NSString says
// the string has; a strlen mismatch is logged and returns NO.
BOOL TXLogBootCString(const char *label, const char * _Nullable s, NSUInteger expectedLength);

#ifdef __cplusplus
} // extern "C"
#endif

NS_ASSUME_NONNULL_END
