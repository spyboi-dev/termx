// TXBootPathCheck — the runtime's exact path checks, repeated here.
//
// See the header for why this exists: the 14:02 run failed with the
// runtime's own "Kernarium: invalid rootfs or overlay path" while the
// app's stat()-based pre-flight passed on the same paths in the same
// process. Every check below is a line-for-line copy of the runtime's
// (KernariumRuntime.mm, usableFile / ext4Rootfs /
// immutableExt4Rootfs), using the same std::filesystem calls on the
// same C strings — the only difference is that each result is logged
// here instead of failing silently.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXBootPathCheck.h"
// TXLog.h's functions have C linkage; this TU is C++, so the
// declarations need extern "C" or the link fails on mangled names.
extern "C" {
#import "TXLog.h"
}
#include <filesystem>
#include <system_error>
#include <string>
#include <cstring>
#include <cctype>

namespace fs = std::filesystem;

// usableFile, exactly as the runtime has it: null/empty is false;
// otherwise std::filesystem::is_regular_file with an error_code,
// and the error must be clear.
static BOOL TXUsableFileExact(const char* path, const char* label) {
    if (path == nullptr || path[0] == '\0') {
        TXLogEngine(@"Exact-check: usableFile(%s) = NO (null or empty path)", label);
        return NO;
    }
    std::error_code ec;
    bool ok = fs::is_regular_file(path, ec) && !ec;
    TXLogEngine(@"Exact-check: usableFile(%s) = %@ (std::error_code: %s)",
                label, ok ? @"YES" : @"NO", ec ? ec.message().c_str() : "none");
    return ok ? YES : NO;
}

// ext4Rootfs, exactly as the runtime has it: the lowercased extension
// of the path is ".ext4".
static BOOL TXExt4RootfsExact(const char* path) {
    std::string extension = fs::path{path}.extension().string();
    for (auto& c : extension) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    BOOL ok = (extension == ".ext4");
    TXLogEngine(@"Exact-check: rootfs extension = \"%s\" (lowercased), ext4 = %@",
                extension.c_str(), ok ? @"YES" : @"NO");
    return ok;
}

// immutableExt4Rootfs, exactly as the runtime has it: a non-.ext4
// path passes outright; an .ext4 path passes only when
// std::filesystem::status reports no owner/group/other write bits,
// and a status error fails it.
static BOOL TXImmutableExt4RootfsExact(const char* path) {
    if (!TXExt4RootfsExact(path)) {
        TXLogEngine(@"Exact-check: immutableExt4Rootfs(rootfs) = YES (not an .ext4 path, check skipped)");
        return YES;
    }
    std::error_code ec;
    const auto permissions = fs::status(path, ec).permissions();
    if (ec) {
        TXLogEngine(@"Exact-check: immutableExt4Rootfs(rootfs) = NO (status error: %s)", ec.message().c_str());
        return NO;
    }
    constexpr auto writable = fs::perms::owner_write | fs::perms::group_write | fs::perms::others_write;
    BOOL ok = (permissions & writable) == fs::perms::none;
    TXLogEngine(@"Exact-check: immutableExt4Rootfs(rootfs) = %@ (perms %04o, write bits %@)",
                ok ? @"YES" : @"NO",
                static_cast<unsigned>(permissions) & 0777,
                ok ? @"clear" : @"SET");
    return ok;
}

BOOL TXCheckBootPathsExact(const char* rootfsPath, const char* overlayPath) {
    BOOL rootUsable = TXUsableFileExact(rootfsPath, "rootfs");
    // The ext4/permissions check needs a real string: std::filesystem::path
    // from a null pointer is undefined, so a null rootfs fails here outright.
    BOOL rootImmutable = NO;
    if (rootfsPath != nullptr && rootfsPath[0] != '\0') {
        rootImmutable = TXImmutableExt4RootfsExact(rootfsPath);
    } else {
        TXLogEngine(@"Exact-check: immutableExt4Rootfs(rootfs) = NO (null or empty path)");
    }
    BOOL overlayUsable = TXUsableFileExact(overlayPath, "overlay");
    BOOL ok = rootUsable && rootImmutable && overlayUsable;
    TXLogEngine(@"Exact-check: rootfs usable=%@ immutable=%@, overlay usable=%@ — the runtime's combined check would %@",
                rootUsable ? @"YES" : @"NO",
                rootImmutable ? @"YES" : @"NO",
                overlayUsable ? @"YES" : @"NO",
                ok ? @"PASS" : @"FAIL");
    return ok;
}

BOOL TXLogBootCString(const char* label, const char* s, NSUInteger expectedLength) {
    if (s == nullptr) {
        TXLogEngine(@"Boot C string %s: NULL (expected %lu bytes)", label, (unsigned long)expectedLength);
        return NO;
    }
    size_t len = std::strlen(s);
    // A hex dump of the first bytes, not just the %s text: a string
    // with an embedded NUL prints truncated, the dump does not.
    NSMutableString* hex = [NSMutableString string];
    size_t dump = len < 32 ? len : 32;
    for (size_t i = 0; i < dump; i++) [hex appendFormat:@"%02x ", (unsigned char)s[i]];
    TXLogEngine(@"Boot C string %s: ptr=%p strlen=%zu expected=%lu bytes=\"%s\" hex[0..%zu]=%@",
                label, (const void*)s, len, (unsigned long)expectedLength, s, dump, hex);
    if (len != expectedLength) {
        TXLogEngine(@"Boot C string %s: LENGTH MISMATCH — strlen %zu but the app's string is %lu bytes (embedded NUL or truncated buffer?)",
                    label, len, (unsigned long)expectedLength);
        return NO;
    }
    return YES;
}
