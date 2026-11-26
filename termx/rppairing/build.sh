#!/bin/bash
# Build libtx_rppairing.a (on-device remote pairing for Built-in
# StikJIT, termx/src/TXOnDevicePairing.m) for iOS arm64 and copy it
# to termx/rppairing-artifact/, where termx/build.sh links it when
# present. The C interface is termx/src/TXRPPairing.h.
#
# Dependencies come from crates.io at the versions in Cargo.toml
# (idevice is MIT, jkcoxson/idevice). Needs rustup with the
# aarch64-apple-ios target (`rustup target add aarch64-apple-ios`).
# Runs on a Mac; the same steps run in CI in
# .github/workflows/build-rppairing.yml.
set -euo pipefail

RPPAIRING_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$RPPAIRING_DIR/../.." && pwd)"
TARGET=aarch64-apple-ios
export IPHONEOS_DEPLOYMENT_TARGET=17.0

cd "$RPPAIRING_DIR"
rustup target add "$TARGET"
cargo build --release --target "$TARGET"
mkdir -p "$REPO_ROOT/termx/rppairing-artifact"
cp "target/$TARGET/release/libtermx_rppairing.a" "$REPO_ROOT/termx/rppairing-artifact/libtx_rppairing.a"
echo "-> termx/rppairing-artifact/libtx_rppairing.a"
lipo -info "$REPO_ROOT/termx/rppairing-artifact/libtx_rppairing.a"
