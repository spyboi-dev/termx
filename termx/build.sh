#!/bin/bash
# TermX build: Objective-C UIKit app on the Kernarium Linux runtime, built
# on Linux with clang-18 + ld64.lld-18 against the iOS 26.5 SDK.
#
# The runtime is NOT compiled here: upstream's CMake refuses non-Apple
# hosts and the whole chain needs Xcode. The app dlopen()s the Linux
# flavour runtime framework KRuntime_6_18_4K on Start (see KernEngine
# loadRuntimeWithError:), so the app binary carries NO framework load
# commands: linking it mapped its 53 MB (36 MB kernel inside) at launch
# before anything ran. The framework's own load commands pull in the
# three GPU frameworks it loads (KosmicKrisp, MesaEGL, MesaGallium).
# The Linux framework is NOT in any Kernarium release and NOT in the
# Andarium IPA (that one carries the Android flavour only): it must be
# built on a Mac first, with
#   Kernarium/scripts/package-ios-frameworks.sh --sdk device
# (default --runtimes all), which writes it to
#   .build/kernarium-xcframeworks/
# Copy the device slice KRuntime_6_18_4K.framework into Frameworks/ here
# and re-run this script. The GPU frameworks are already in Frameworks/
# (extracted from Andarium's release IPA; the Linux runtime loads the
# same three). See BUILD-NOTE.md.
#
# Produces build/TermX.ipa: an adhoc-signed IPA. The installer
# (SideStore, or sign-ipa.sh on a Mac) signs the whole bundle at
# install time.
set -euo pipefail
cd "$(dirname "$0")"
SDK="$HOME/workspace/spytube-ios/sdks/iPhoneOS26.5.sdk"
SRC=src
OUT=build
# Absolute: the script cds into $OUT to zip, and the post-build
# verification below still needs this path after the cd.
APP="$(pwd)/$OUT/Payload/TermX.app"
# 27.0: the embedded Kernarium frameworks declare MinimumOSVersion 27.0.
MIN=27.0

# Toolchain preflight: a VM restart wipes the apt tools (clang-18,
# ld64.lld-18 live in /usr/bin, not the workspace), and without this
# the build dies mid-way with a bare "command not found". Fail here,
# with the restore command, instead.
for tool in clang-18 ld64.lld-18 zip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is not installed." >&2
    echo "VM restarts wipe the apt tools. Restore with:" >&2
    echo "  sudo apt-get update -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20" >&2
    echo "  sudo apt-get install -y clang-18 lld-18" >&2
    exit 1
  fi
done
if [ ! -d "$SDK" ]; then
  echo "ERROR: iOS SDK not found at $SDK" >&2
  echo "The SDKs live in the sibling spytube-ios checkout, not this repo." >&2
  exit 1
fi

if [ ! -d "Frameworks/KRuntime_6_18_4K.framework" ]; then
  echo "ERROR: Frameworks/KRuntime_6_18_4K.framework is missing." >&2
  echo "The Linux runtime framework is not in any Kernarium release and" >&2
  echo "cannot be built on this Linux VM (upstream CMake refuses" >&2
  echo "non-Apple hosts). Build it on a Mac:" >&2
  echo "  git clone https://github.com/imxieyi/Kernarium" >&2
  echo "  cd Kernarium" >&2
  echo "  Kernarium/scripts/package-ios-frameworks.sh --sdk device" >&2
  echo "then copy .build/kernarium-xcframeworks/.../KRuntime_6_18_4K.framework" >&2
  echo "into Frameworks/ here and re-run this script. See BUILD-NOTE.md." >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$APP/Frameworks"

CLANG=clang-18
# The build marker in engine.log: the short commit of the source this
# IPA was built from, so a device log always identifies its build.
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
# The runtime framework's SHA-256, baked in the same way, so the
# About screen can show it without hashing a 53 MB file at runtime.
FWSHA=$(sha256sum Frameworks/KRuntime_6_18_4K.framework/KRuntime_6_18_4K | cut -d' ' -f1)
CFLAGS="-target arm64-apple-ios$MIN -isysroot $SDK -miphoneos-version-min=$MIN -fobjc-arc -O2 -Wno-deprecated-declarations -DTERMX_BUILD_COMMIT=\"$COMMIT\" -DTERMX_FRAMEWORK_SHA256=\"$FWSHA\" -I$SRC -IFrameworks/Ghostty/include -F$SDK/System/Library/SubFrameworks -F$SDK/System/Library/PrivateFrameworks"

echo "== compile"
for f in main AppDelegate TerminalViewController KernEngine GuestInstall TXCrashLog TXLog TXLogViewController TXStartupViewController TXAboutViewController TXGuestFlow TXLocalhostProxy TXGhosttyView TXBackgroundKeepAlive TXStikJITCoordinator TXStikJITTransport TXPairingStore TXLoopbackProbe TXOnDevicePairing; do
  echo "   $f.m"
  $CLANG $CFLAGS -c "$SRC/$f.m" -o "$OUT/$f.o"
done
for f in vt; do
  echo "   $f.c"
  $CLANG $CFLAGS -c "$SRC/$f.c" -o "$OUT/$f.o"
done

echo "== link"
# On-device pairing library: the Rust static library built on the
# Mac runner (.github/workflows/build-rppairing.yml, or
# termx/rppairing/build.sh) and dropped here as
# rppairing-artifact/libtx_rppairing.a. When it is absent the build
# still links: the C functions in TXRPPairing.h are weak imports and
# TXOnDevicePairing reports the library missing, so only the file
# import path works. When it is present, on-device pairing works.
RPPAIRING_LIB=""
if [ -f "rppairing-artifact/libtx_rppairing.a" ]; then
  RPPAIRING_LIB="rppairing-artifact/libtx_rppairing.a"
  echo "   linking rppairing-artifact/libtx_rppairing.a"
else
  echo "   no rppairing-artifact/libtx_rppairing.a; host-only pairing (file import only)"
fi
ld64.lld-18 -arch arm64 -platform_version ios $MIN 26.5 \
  -syslibroot "$SDK" \
  -F"$SDK/System/Library/Frameworks" \
  -L"$SDK/usr/lib" \
  -adhoc_codesign -ObjC \
  -rpath @executable_path/Frameworks \
  "$OUT"/main.o "$OUT"/AppDelegate.o "$OUT"/TerminalViewController.o \
  "$OUT"/KernEngine.o "$OUT"/GuestInstall.o "$OUT"/TXCrashLog.o \
  "$OUT"/TXLog.o "$OUT"/TXLogViewController.o "$OUT"/TXStartupViewController.o \
  "$OUT"/TXAboutViewController.o "$OUT"/TXGuestFlow.o "$OUT"/TXLocalhostProxy.o \
  "$OUT"/TXGhosttyView.o "$OUT"/TXBackgroundKeepAlive.o \
  "$OUT"/TXStikJITCoordinator.o "$OUT"/TXStikJITTransport.o \
  "$OUT"/TXPairingStore.o "$OUT"/TXLoopbackProbe.o "$OUT"/TXOnDevicePairing.o \
  "$OUT"/vt.o \
  Frameworks/Ghostty/libghostty.a \
  $RPPAIRING_LIB \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework QuartzCore -framework Metal -framework MetalKit \
  -framework CoreText -framework CoreLocation -framework IOSurface \
  -framework Security -framework BackgroundTasks -framework UserNotifications \
  -lz -lobjc -lSystem -lc++ \
  -o "$APP/TermX"

cp "$SRC/Info.plist" "$APP/Info.plist"
cp "$SRC"/icons/*.png "$APP/"
printf 'APPL????' > "$APP/PkgInfo"
# Embed the runtime framework and the GPU frameworks it loads.
cp -r Frameworks/KRuntime_6_18_4K.framework "$APP/Frameworks/"
cp -r Frameworks/KosmicKrisp.framework "$APP/Frameworks/"
cp -r Frameworks/MesaEGL.framework "$APP/Frameworks/"
cp -r Frameworks/MesaGallium.framework "$APP/Frameworks/"
# Drop any prebuilt code signature: the installer re-signs everything anyway.
find "$APP/Frameworks" -name _CodeSignature -type d -exec rm -rf {} + 2>/dev/null || true
# Built-in StikJIT helper: the .appex is built unsigned on the Mac
# runner (.github/workflows/build-jithelper.yml) and dropped here as
# helper-artifact/TermXJITHelper.appex. If it is present, embed it
# under PlugIns/; the installer (SideStore) signs the whole bundle,
# including the helper and its nested StikJIT.framework, at install
# time. If it is absent, the build is host-only and the About JIT
# card reports the helper unavailable.
if [ -d "helper-artifact/TermXJITHelper.appex" ]; then
  mkdir -p "$APP/PlugIns"
  cp -r helper-artifact/TermXJITHelper.appex "$APP/PlugIns/"
  find "$APP/PlugIns/TermXJITHelper.appex" -name _CodeSignature -type d -exec rm -rf {} + 2>/dev/null || true
  echo "   embedded PlugIns/TermXJITHelper.appex"
else
  echo "   no helper-artifact/TermXJITHelper.appex; host-only build (no Built-in StikJIT)"
fi

cd "$OUT"
rm -f TermX.ipa
zip -qry TermX.ipa Payload
ls -lh TermX.ipa

# Post-build verification: the build must prove what it made, not
# just zip it. An arm64 binary for the right bundle, with the
# version from Info.plist and the build marker baked in, and the
# runtime framework embedded. Any failure here exits non-zero with
# a named cause, instead of shipping an IPA that looks fine.
echo "== verify"
BIN="$APP/TermX"
ARCH=$(file -b "$BIN")
case "$ARCH" in
  *arm64*) ;;
  *) echo "ERROR: binary is not arm64: $ARCH" >&2; exit 1 ;;
esac
if [ ! -d "$APP/Frameworks/KRuntime_6_18_4K.framework" ]; then
  echo "ERROR: KRuntime_6_18_4K.framework was not embedded in the app." >&2
  exit 1
fi
if [ -d "$APP/PlugIns/TermXJITHelper.appex" ]; then
  HELPER_BIN="$APP/PlugIns/TermXJITHelper.appex/TermXJITHelper"
  HELPER_ARCH=$(file -b "$HELPER_BIN" 2>/dev/null || echo missing)
  case "$HELPER_ARCH" in
    *arm64*) ;;
    *) echo "ERROR: helper binary is not arm64: $HELPER_ARCH" >&2; exit 1 ;;
  esac
  if [ ! -d "$APP/PlugIns/TermXJITHelper.appex/Frameworks/StikJIT.framework" ]; then
    echo "ERROR: StikJIT.framework was not embedded in the helper." >&2
    exit 1
  fi
  echo "   helper PlugIns/TermXJITHelper.appex ($HELPER_ARCH)"
else
  echo "   no helper embedded (host-only build)"
fi
if [ -n "$RPPAIRING_LIB" ]; then
  if ! grep -a -q "tx_rppairing_new" "$BIN"; then
    echo "ERROR: pairing library linked but tx_rppairing_new not in the binary." >&2
    exit 1
  fi
  echo "   on-device pairing library linked"
else
  echo "   on-device pairing library absent (file import only)"
fi
if [ "$COMMIT" = "nogit" ]; then
  echo "ERROR: no git commit — the build marker would be 'nogit' and the IPA unidentifiable." >&2
  echo "Run the build from a git checkout." >&2
  exit 1
fi
if ! grep -a -q "$COMMIT" "$BIN"; then
  echo "ERROR: build marker '$COMMIT' not found in the binary." >&2
  exit 1
fi
python3 - "$APP/Info.plist" <<'EOF'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
bid = info.get('CFBundleIdentifier')
ver = info.get('CFBundleShortVersionString')
build = info.get('CFBundleVersion')
if bid != 'app.termx.ios':
    sys.exit('ERROR: bundle id is %r, expected app.termx.ios' % bid)
if not ver or not build:
    sys.exit('ERROR: Info.plist has no version/build')
print('   bundle %s version %s (%s)' % (bid, ver, build))
EOF
echo "   binary $ARCH"
echo "   marker $COMMIT"
echo "OK: TermX.ipa verified"
