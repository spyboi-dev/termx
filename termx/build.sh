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
set -e
cd "$(dirname "$0")"
SDK="$HOME/workspace/spytube-ios/sdks/iPhoneOS26.5.sdk"
SRC=src
OUT=build
APP=$OUT/Payload/TermX.app
# 27.0: the embedded Kernarium frameworks declare MinimumOSVersion 27.0.
MIN=27.0

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
CFLAGS="-target arm64-apple-ios$MIN -isysroot $SDK -miphoneos-version-min=$MIN -fobjc-arc -O2 -Wno-deprecated-declarations -DTERMX_BUILD_COMMIT=\"$COMMIT\" -I$SRC -F$SDK/System/Library/SubFrameworks -F$SDK/System/Library/PrivateFrameworks"

echo "== compile"
for f in main AppDelegate TerminalViewController KernEngine GuestInstall TXCrashLog TXLog TXLogViewController TXStartupViewController; do
  echo "   $f.m"
  $CLANG $CFLAGS -c "$SRC/$f.m" -o "$OUT/$f.o"
done
for f in vt; do
  echo "   $f.c"
  $CLANG $CFLAGS -c "$SRC/$f.c" -o "$OUT/$f.o"
done

echo "== link"
ld64.lld-18 -arch arm64 -platform_version ios $MIN 26.5 \
  -syslibroot "$SDK" \
  -F"$SDK/System/Library/Frameworks" \
  -L"$SDK/usr/lib" \
  -adhoc_codesign -ObjC \
  -rpath @executable_path/Frameworks \
  "$OUT"/main.o "$OUT"/AppDelegate.o "$OUT"/TerminalViewController.o \
  "$OUT"/KernEngine.o "$OUT"/GuestInstall.o "$OUT"/TXCrashLog.o \
  "$OUT"/TXLog.o "$OUT"/TXLogViewController.o "$OUT"/TXStartupViewController.o \
  "$OUT"/vt.o \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework QuartzCore -framework Metal -framework MetalKit \
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

cd "$OUT"
rm -f TermX.ipa
zip -qry TermX.ipa Payload
ls -lh TermX.ipa
