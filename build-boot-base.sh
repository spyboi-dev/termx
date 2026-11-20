#!/bin/sh
# Build the Kernarium guest boot base archive (uml-boot-base-aarch64.cpio.gz)
# on this x86_64 Linux VM, replicating upstream's producer for the boot-base
# product only: tools/rootfs/starter/build-all.sh --product boot-base-aarch64
# plus its prepare_busybox_config step. build-all.sh itself refuses to run
# here (it requires a native aarch64 host and passwordless sudo, for the disk
# products), but the boot-base product is pure Buildroot: Buildroot builds its
# own aarch64 musl cross toolchain, so the host architecture does not matter.
# No upstream file is modified; the pinned Buildroot/BusyBox versions and
# SHA-256s below are copied verbatim from build-all.sh.
#
# Output: bootbase-out/uml-boot-base-aarch64.cpio.gz (plus its size/SHA-256
# printed at the end, for the workflow's boot-base accept step).
set -eu

REPO="$HOME/workspace/kernarium-termux"
UPSTREAM="$REPO/upstream"
WORK="$REPO/bootbase-work"
OUT="$REPO/bootbase-out"
SOURCES="$WORK/sources"
BUILDS="$WORK/builds"

BUILDROOT_VERSION=2026.05.3
BUILDROOT_SHA256=f43f1627082a45848f73083b3b8d59f32bb4c77a449a8ead8a2a1f91849dea00
BUSYBOX_VERSION=1.38.0
BUSYBOX_SHA256=34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2

fail() { printf '%s\n' "build-boot-base.sh: $*" >&2; exit 1; }

# This VM's filesystem denies chown even as root, and GNU tar run as root
# tries to restore the recorded owner of every extracted file (host-libtool's
# tarball records uid 501/gid 50). TAR_OPTIONS is read by GNU tar itself, so
# every extraction in this script and in the Buildroot build skips ownership.
export TAR_OPTIONS="--no-same-owner"

# Compiler temp files default to /tmp, a 512M tmpfs that fills up and then
# fails compiles silently; point them at the workspace disk instead.
export TMPDIR="$WORK/tmp"
mkdir -p -- "$TMPDIR"

mkdir -p -- "$SOURCES" "$BUILDS" "$OUT"

download_checked() {
	url=$1; expected=$2; destination=$3
	if [ ! -f "$destination" ]; then
		partial=$destination.partial
		rm -f -- "$partial"
		curl -fL --retry 3 --output "$partial" "$url"
		mv -- "$partial" "$destination"
	fi
	actual=$(sha256sum "$destination" | awk '{print $1}')
	[ "$actual" = "$expected" ] || fail "checksum mismatch for $destination"
}

# --- prepare_busybox_config (verbatim from build-all.sh) ---
buildroot_archive=$SOURCES/buildroot-$BUILDROOT_VERSION.tar.xz
busybox_archive=$SOURCES/busybox-$BUSYBOX_VERSION.tar.bz2
download_checked \
	"https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.xz" \
	"$BUILDROOT_SHA256" "$buildroot_archive"
download_checked \
	"https://www.busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2" \
	"$BUSYBOX_SHA256" "$busybox_archive"
buildroot_source=$SOURCES/buildroot-$BUILDROOT_VERSION
busybox_source=$SOURCES/busybox-$BUSYBOX_VERSION
[ -d "$buildroot_source" ] || tar -C "$SOURCES" -xf "$buildroot_archive"
[ -d "$busybox_source" ] || tar -C "$SOURCES" -xf "$busybox_archive"

busybox_config=$BUILDS/busybox-minimal.config
busybox_log=$BUILDS/busybox-allnoconfig.log
make -s -C "$busybox_source" allnoconfig > "$busybox_log"
while IFS= read -r symbol; do
	case "$symbol" in \#*|'') continue ;; esac
	if grep -qx "CONFIG_$symbol=y" "$busybox_source/.config"; then
		continue
	fi
	grep -qx "# CONFIG_$symbol is not set" "$busybox_source/.config" || \
		fail "BusyBox does not define required option CONFIG_$symbol"
	sed -i "s/^# CONFIG_$symbol is not set\$/CONFIG_$symbol=y/" \
		"$busybox_source/.config"
done < "$UPSTREAM/tools/rootfs/starter/buildroot/busybox.fragment"
make -s -C "$busybox_source" silentoldconfig
while IFS= read -r symbol; do
	case "$symbol" in \#*|'') continue ;; esac
	grep -qx "CONFIG_$symbol=y" "$busybox_source/.config" || \
		fail "BusyBox rejected required option CONFIG_$symbol"
done < "$UPSTREAM/tools/rootfs/starter/buildroot/busybox.fragment"
cp -- "$busybox_source/.config" "$busybox_config"
echo "BusyBox config ready: $busybox_config"

# --- build_boot_base aarch64 (verbatim from build-all.sh) ---
buildroot_output=$BUILDS/buildroot-aarch64
mkdir -p -- "$buildroot_output"
if [ -d "$buildroot_output/build" ]; then
	rm -rf -- \
		"$buildroot_output/images" \
		"$buildroot_output/staging" \
		"$buildroot_output/target"
	find "$buildroot_output/build" -name .stamp_target_installed \
		-delete
fi
generated_defconfig=$buildroot_output/uml-boot-base-defconfig
{
	printf '%s\n' 'BR2_aarch64=y
BR2_ARM64_PAGE_SIZE_16K=y'
	# This VM's filesystem denies chown even as root, so tar must not
	# restore recorded owners when Buildroot extracts package sources.
	# (Buildroot's own TAR_OPTIONS make variable overrides the
	# environment variable of the same name, so this Kconfig string
	# is the way to pass it.)
	printf '%s\n' 'BR2_TAR_OPTIONS="--no-same-owner"'
	sed \
		-e "s|@BUSYBOX_CONFIG@|$busybox_config|g" \
		-e "s|@OVERLAY@|$UPSTREAM/tools/rootfs/starter/buildroot/overlay|g" \
		-e "s|@POST_BUILD@|$UPSTREAM/tools/rootfs/starter/buildroot/post-build.sh|g" \
		-e "s|@ARCHITECTURE@|aarch64|g" \
		"$UPSTREAM/tools/rootfs/starter/buildroot/defconfig.in"
} > "$generated_defconfig"
make -C "$buildroot_source" O="$buildroot_output" \
	BR2_DL_DIR="$SOURCES/downloads" \
	BR2_DEFCONFIG="$generated_defconfig" defconfig
# -j1: this VM has ~8 GB RAM shared with other work and a parallel GCC
# build gets its compiler killed silently (missing .TPo, no error) when
# memory runs out; a serial build is slower but survives.
make -C "$buildroot_source" O="$buildroot_output" \
	BR2_DL_DIR="$SOURCES/downloads" -j1

image=$buildroot_output/images/rootfs.cpio.gz
[ -f "$image" ] || fail "Buildroot did not produce $image"
gzip -t "$image"
listing=$buildroot_output/boot-base.list
gzip -dc "$image" | cpio -it > "$listing" 2>/dev/null
for required in init bin/busybox bin/cp bin/printf bin/umount sbin/blkid \
	sbin/dumpe2fs sbin/e2fsck sbin/mke2fs sbin/mkfs.ext4 \
	sbin/resize2fs sbin/switch_root; do
	grep -qx "\./$required\|$required" "$listing" || \
		fail "boot base is missing $required"
done
cp -- "$image" "$OUT/uml-boot-base-aarch64.cpio.gz"
echo "boot base built: $OUT/uml-boot-base-aarch64.cpio.gz"
ls -l "$OUT/uml-boot-base-aarch64.cpio.gz"
sha256sum "$OUT/uml-boot-base-aarch64.cpio.gz"
