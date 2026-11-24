#!/bin/bash
# Builds termx-debian-trixie-arm64-slim.ext4: the MINIMAL arm64 Debian trixie
# rootfs for TermX's Linux guest (boots to a shell with working apt and
# networking; users apt-install what they need). Same recipe as
# build-rootfs.sh, but configure-rootfs-slim.sh installs only the
# essentials: no Docker, no python3, no nodejs, no git, no build tools.
# The full image (termx-debian-trixie-arm64.ext4) is untouched.
#
# Steps: debootstrap --foreign (arm64, minbase) -> second stage under
# qemu-aarch64-static -> configure-rootfs-slim.sh in chroot -> mke2fs -d
# image -> e2fsck + debugfs checks -> gzip + SHA-256.
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
cd "$(dirname "$0")"
ROOTFS="$PWD/rootfs-slim"
IMG="$PWD/termx-debian-trixie-arm64-slim.ext4"
LOG="$PWD/build-slim.log"
# /tmp is a 512M tmpfs; keep all temp files on the workspace disk.
export TMPDIR="$PWD/tmp"
mkdir -p "$TMPDIR"
exec > >(tee -a "$LOG") 2>&1
echo "=== TermX slim rootfs build started $(date -u +%FT%TZ) ==="

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

if [ ! -d "$ROOTFS/debootstrap" ] && ! grep -q "^Architecture: arm64" "$ROOTFS/var/lib/dpkg/status" 2>/dev/null; then
  echo "== debootstrap --foreign (arm64 trixie minbase)"
  debootstrap --foreign --arch=arm64 --variant=minbase trixie "$ROOTFS" http://deb.debian.org/debian
else
  echo "== debootstrap already done, skipping"
fi

echo "== second stage under qemu"
# NOTE: the status-file dedupe lives inside the second-stage if below,
# not here. debootstrap's second_stage_install runs `x_feign_install
# dpkg`, which APPENDS a placeholder dpkg stanza (no Architecture) to
# /var/lib/dpkg/status every run. If a proper dpkg stanza (Architecture:
# arm64) already exists, dpkg then dies on the duplicate ("multiple
# non-coinstallable package instances") at the first install. The fix
# is to delete ALL dpkg stanzas just before the second stage runs:
# the feigned one becomes the only entry, and `x_core_install dpkg`
# replaces it in place with the full stanza (proven by run 4).
cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
# The VM's exec sandbox denies chown to any uid/gid other than the
# current one, even as root (user namespace: the overlay fs belongs to
# the init userns, so this namespace's CAP_CHOWN does not apply there).
# debootstrap's second stage dies on this: base-files' postinst chowns
# /var/mail to root:mail. Work around it with a dpkg diversion: the real
# coreutils binaries move to *.real, and a no-op script answers chown/
# chgrp calls from maintainer scripts. Files just keep root:root
# ownership (harmless for this terminal image: /var/mail, /etc/shadow's
# group and the like are never used by the guest's services). The
# diversion is removed after configure, restoring the real binaries.
for tool in chown chgrp; do
  chroot "$ROOTFS" /usr/bin/dpkg-divert --add --rename --divert "/usr/bin/$tool.real" "/usr/bin/$tool" >/dev/null 2>&1 || true
  printf '#!/bin/sh\n# No-op: the build sandbox denies chown/chgrp (see build-rootfs-slim.sh).\nexit 0\n' > "$ROOTFS/usr/bin/$tool"
  chmod +x "$ROOTFS/usr/bin/$tool"
done
echo "== chown/chgrp diverted to no-op shims for the build"
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
# TMPDIR is the host workspace tmp dir ($PWD/tmp) and does not exist
# inside the chroot: guest tools that honour it (ca-certificates'
# postinst runs mktemp under $TMPDIR) die with "No such file or
# directory". Override it to the chroot's own /tmp for every chroot
# call; that /tmp lives in the rootfs tree on the workspace disk.
# The second stage is resumable but slow (~15 min under qemu); skip it
# once it has completed (marker removed by configure's cleanup so the
# shipped image never contains it).
if [ ! -f "$ROOTFS/.termx-second-stage-done" ]; then
  # Delete ALL dpkg stanzas before the second stage (see note above):
  # x_feign_install appends a placeholder one, and x_core_install
  # dpkg replaces it in place with the full stanza. Also dedupe any
  # other package that somehow appears twice.
  python3 - "$ROOTFS/var/lib/dpkg/status" <<'PYEOF' || true
import re, sys
p = sys.argv[1]
with open(p) as f:
    text = f.read()
stanzas = [s for s in text.split('\n\n') if s.strip()]
seen, order, out = {}, [], []
for s in stanzas:
    m = re.search(r'^Package:\s*(\S+)', s, re.M)
    if not m:
        continue
    if m.group(1) == 'dpkg':
        print("status: dropping dpkg stanza before second stage")
        continue
    arch = re.search(r'^Architecture:\s*(\S+)', s, re.M)
    key = (m.group(1), arch.group(1) if arch else '')
    if key in seen:
        print(f"status: dropping duplicate stanza {key}")
    seen[key] = s
    order.append(key)
for k in dict.fromkeys(order):
    out.append(seen[k])
with open(p, 'w') as f:
    f.write('\n\n'.join(out) + '\n')
PYEOF
  TMPDIR=/tmp chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
  touch "$ROOTFS/.termx-second-stage-done"
else
  echo "== second stage already done, skipping"
fi
echo "== second stage done"

echo "== configure inside chroot"
cp configure-rootfs-slim.sh "$ROOTFS/root/configure-rootfs-slim.sh"
chmod +x "$ROOTFS/root/configure-rootfs-slim.sh"
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
TMPDIR=/tmp chroot "$ROOTFS" /bin/bash /root/configure-rootfs-slim.sh
rm -f "$ROOTFS/root/configure-rootfs-slim.sh"
# Restore the real chown/chgrp: remove the no-op shims, then remove the
# diversions (which renames *.real back into place). Verify the restore
# by asking the real binary for its version under qemu.
for tool in chown chgrp; do
  rm -f "$ROOTFS/usr/bin/$tool"
  chroot "$ROOTFS" /usr/bin/dpkg-divert --remove --rename "/usr/bin/$tool" >/dev/null 2>&1 || true
done
chroot "$ROOTFS" /usr/bin/chown --version | head -1 || {
  echo "FATAL: real chown was not restored" >&2; exit 1; }
echo "== real chown/chgrp restored"
cleanup_mounts
trap - EXIT

echo "== rootfs size"
du -sh "$ROOTFS"
USED_MB=$(du -sm "$ROOTFS" | cut -f1)
# image size = used + 30% headroom, at least 1024 MiB, rounded up to 16 MiB
IMG_MB=$(( (USED_MB * 14 / 10 + 15) / 16 * 16 ))  # 40% headroom
[ "$IMG_MB" -lt 1024 ] && IMG_MB=1024
# mke2fs takes the size in 1K units, not 4K blocks: the full build once
# passed 393216 and got a 384 MiB fs (98304 4K blocks), which ran out of
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
sha256sum "$IMG" "$IMG.gz" | tee "$PWD/SHA256SUMS-slim"

echo "=== TermX slim rootfs build finished $(date -u +%FT%TZ) ==="
