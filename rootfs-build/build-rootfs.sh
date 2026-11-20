#!/bin/bash
# Builds termx-debian-trixie-arm64.ext4: a minimal arm64 Debian trixie rootfs
# for KTerm's Linux guest, as an ext4 image the Kernarium Linux runtime mounts
# read-only on ubd0 (root type ext4, overlay ext4 on ubd1, entry /sbin/init).
# The runtime requires the image file to end in .ext4 and to carry NO write
# permission bits (upstream KernariumRuntime.mm: immutableExt4Rootfs).
#
# Steps: debootstrap --foreign (arm64, minbase) -> second stage under
# qemu-aarch64-static -> configure-rootfs.sh in chroot -> mke2fs -d image ->
# e2fsck + debugfs checks -> gzip + SHA-256.
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
cd "$(dirname "$0")"
ROOTFS="$PWD/rootfs"
IMG="$PWD/termx-debian-trixie-arm64.ext4"
LOG="$PWD/build.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== TermX rootfs build started $(date -u +%FT%TZ) ==="

# Mounts do not persist between exec calls in this environment, so the
# binfmt_misc mount and the qemu-aarch64 handler must be set up inside
# this same invocation, before any chroot runs. Write the packaged
# registration VERBATIM: the register file parses \x.. escapes itself,
# so expanding them first (printf %b) writes a malformed handler that
# matches every ELF and breaks host binaries.
setup_binfmt() {
  mkdir -p /proc/sys/fs/binfmt_misc
  mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
  if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    cat /usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register
  fi
  if [ -x "$ROOTFS/bin/uname" ]; then
    chroot "$ROOTFS" /bin/uname -m | grep -q aarch64 || {
      echo "FATAL: qemu-aarch64 binfmt is not working" >&2; exit 1; }
    echo "== binfmt qemu-aarch64 OK (chroot uname -m = aarch64)"
  else
    echo "== binfmt handler registered (no rootfs yet to test it against)"
  fi
}
setup_binfmt

if [ ! -d "$ROOTFS/debootstrap" ]; then
  echo "== debootstrap --foreign (arm64 trixie minbase)"
  debootstrap --foreign --arch=arm64 --variant=minbase trixie "$ROOTFS" http://deb.debian.org/debian
else
  echo "== debootstrap already done, skipping"
fi

echo "== second stage under qemu"
cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
mount -t proc proc "$ROOTFS/proc" 2>/dev/null || true
mount -t sysfs sys "$ROOTFS/sys" 2>/dev/null || true
mount --bind /dev "$ROOTFS/dev" 2>/dev/null || true
mount -t devpts devpts "$ROOTFS/dev/pts" 2>/dev/null || true
# /etc/resolv.conf in the rootfs is a symlink to systemd-resolved's
# stub (dangling while resolved is not running); cp refuses to
# write through a dangling symlink, so remove it first.
rm -f "$ROOTFS/etc/resolv.conf"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
cleanup_mounts() {
  umount "$ROOTFS/dev/pts" 2>/dev/null || true
  umount "$ROOTFS/dev" 2>/dev/null || true
  umount "$ROOTFS/sys" 2>/dev/null || true
  umount "$ROOTFS/proc" 2>/dev/null || true
}
trap cleanup_mounts EXIT
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
echo "== second stage done"

echo "== configure inside chroot"
cp configure-rootfs.sh "$ROOTFS/root/configure-rootfs.sh"
chmod +x "$ROOTFS/root/configure-rootfs.sh"
# The chroot's apt resolves the egress proxy hostname to a dead IPv4
# backend (apt ignores the IPv6-only /etc/hosts pin: its resolver path is
# IPv4-only). Give the chroot the proxy as an IPv6 literal, which needs no
# resolution at all. Credentials stay in the environment only; nothing
# proxy-related is written into the image. The IPv6 address is the cell
# gateway address, resolved live here, stable across boots.
PROXY6=$(getent ahosts hatch-egress-proxy 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}')
if [ -z "$PROXY6" ]; then
  PROXY6=$(awk '$1 == "nameserver" && $2 ~ /:/ {print $2; exit}' /etc/resolv.conf)
fi
if [ -n "$PROXY6" ] && [ -n "$http_proxy" ]; then
  PROXY6URL="${http_proxy/hatch-egress-proxy/[$PROXY6]}"
  export http_proxy="$PROXY6URL" https_proxy="$PROXY6URL" \
    HTTP_PROXY="$PROXY6URL" HTTPS_PROXY="$PROXY6URL" \
    ALL_PROXY="$PROXY6URL" all_proxy="$PROXY6URL"
  echo "chroot proxy pinned to IPv6 literal [$PROXY6]"
fi
chroot "$ROOTFS" /bin/bash /root/configure-rootfs.sh
rm -f "$ROOTFS/root/configure-rootfs.sh"
cleanup_mounts
trap - EXIT

echo "== rootfs size"
du -sh "$ROOTFS"
USED_MB=$(du -sm "$ROOTFS" | cut -f1)
# image size = used + 30% headroom, at least 1024 MiB, rounded up to 16 MiB
IMG_MB=$(( (USED_MB * 14 / 10 + 15) / 16 * 16 ))  # 40% headroom
[ "$IMG_MB" -lt 1024 ] && IMG_MB=1024
# mke2fs takes the size in 1K units, not 4K blocks: resume 8 passed
# 393216 and got a 384 MiB fs (98304 4K blocks), which ran out of
# blocks mid-copy. 1 MiB = 1024 1K units.
BLOCKS=$(( IMG_MB * 1024 ))
echo "== building ext4 image: ${IMG_MB} MiB ($BLOCKS 1K blocks)"
rm -f "$IMG"
mke2fs -t ext4 -L termx-root -m 0 -d "$ROOTFS" "$IMG" "$BLOCKS"

echo "== e2fsck"
e2fsck -fn "$IMG"

echo "== debugfs spot checks"
debugfs -R "ls -l /" "$IMG" 2>/dev/null | head -30
debugfs -R "stat /sbin/init" "$IMG" 2>/dev/null | head -5
debugfs -R "ls -l /etc/systemd/system" "$IMG" 2>/dev/null | grep -i "getty\|default" | head

echo "== permissions: image must be read-only (no write bits) for the runtime"
chmod 444 "$IMG"

echo "== gzip + hashes"
rm -f "$IMG.gz"
gzip -9 -k "$IMG"
ls -lh "$IMG" "$IMG.gz"
sha256sum "$IMG" "$IMG.gz" | tee "$PWD/SHA256SUMS"

echo "=== TermX rootfs build finished $(date -u +%FT%TZ) ==="
