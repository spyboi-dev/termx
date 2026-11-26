#!/bin/bash
# Patch the live slim rootfs tree for fix9: install tmux (added to
# configure-rootfs-slim.sh in da51fab) so the multi-window feature
# works. Every step here mirrors configure-rootfs-slim.sh and
# build-rootfs-slim.sh exactly — those scripts are the source of
# truth, this patch is the iterative shortcut for the live tree
# (see rebuild-image.sh).
#
# Usage: ./patch-rootfs-fix9.sh   (run from rootfs-build/)
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
cd "$(dirname "$0")"
ROOTFS="$PWD/rootfs-slim"
LOG="$PWD/patch-fix9.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== TermX slim rootfs fix9 patch started $(date -u +%FT%TZ) ==="

[ -d "$ROOTFS" ] || { echo "FATAL: live tree $ROOTFS is missing" >&2; exit 1; }

cleanup_mounts() {
  umount "$ROOTFS/dev/pts" 2>/dev/null || true
  umount "$ROOTFS/dev" 2>/dev/null || true
  umount "$ROOTFS/sys" 2>/dev/null || true
  umount "$ROOTFS/proc" 2>/dev/null || true
}

# Restore the real chown/chgrp only if the diversion is active
# (the .real file exists); otherwise rm would delete the real binary.
restore_chown() {
  for tool in chown chgrp; do
    if [ -f "$ROOTFS/usr/bin/$tool.real" ]; then
      rm -f "$ROOTFS/usr/bin/$tool"
      chroot "$ROOTFS" /usr/bin/dpkg-divert --remove --rename "/usr/bin/$tool" >/dev/null 2>&1 || true
    fi
  done
}

full_cleanup() {
  restore_chown
  rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
  cleanup_mounts
}
trap full_cleanup EXIT

# 1. binfmt qemu-aarch64 (same as build-rootfs-slim.sh setup_binfmt).
mkdir -p /proc/sys/fs/binfmt_misc
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  cat /usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register
fi
cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
chroot "$ROOTFS" /bin/uname -m | grep -q aarch64 || { echo "FATAL: qemu-aarch64 binfmt is not working" >&2; exit 1; }
echo "   binfmt qemu-aarch64 OK (chroot uname -m = aarch64)"

# 2. chown/chgrp diversion (the VM sandbox denies chown; see build-rootfs-slim.sh).
for tool in chown chgrp; do
  chroot "$ROOTFS" /usr/bin/dpkg-divert --add --rename --divert "/usr/bin/$tool.real" "/usr/bin/$tool" >/dev/null 2>&1 || true
  printf '#!/bin/sh\n# No-op: the build sandbox denies chown/chgrp (see build-rootfs-slim.sh).\nexit 0\n' > "$ROOTFS/usr/bin/$tool"
  chmod +x "$ROOTFS/usr/bin/$tool"
done
echo "   chown/chgrp diverted to no-op shims"

# 3. mounts + resolv.conf (same as build-rootfs-slim.sh).
mount -t proc proc "$ROOTFS/proc" 2>/dev/null || true
mount -t sysfs sys "$ROOTFS/sys" 2>/dev/null || true
mount --bind /dev "$ROOTFS/dev" 2>/dev/null || true
mount -t devpts devpts "$ROOTFS/dev/pts" 2>/dev/null || true
rm -f "$ROOTFS/etc/resolv.conf"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# 4. Proxy: pin the chroot's apt to the IPv6 literal (same as build-rootfs-slim.sh).
PROXY6=$(getent ahosts hatch-egress-proxy 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}')
if [ -z "$PROXY6" ]; then
  PROXY6=$(awk '$1 == "nameserver" && $2 ~ /:/ {print $2; exit}' /etc/resolv.conf)
fi
if [ -n "$PROXY6" ] && [ -n "$http_proxy" ]; then
  PROXY6URL="${http_proxy/hatch-egress-proxy/[$PROXY6]}"
  export http_proxy="$PROXY6URL" https_proxy="$PROXY6URL" \
    HTTP_PROXY="$PROXY6URL" HTTPS_PROXY="$PROXY6URL" \
    ALL_PROXY="$PROXY6URL" all_proxy="$PROXY6URL"
  echo "   chroot proxy pinned to IPv6 literal [$PROXY6]"
fi

# 5. apt update + install tmux (same flags as configure-rootfs-slim.sh).
echo "== apt-get update (inside chroot)"
for i in 1 2 3 4 5; do
  if TMPDIR=/tmp chroot "$ROOTFS" /usr/bin/apt-get update -o Acquire::Languages=none; then
    echo "   apt-get update OK"
    break
  fi
  echo "   apt-get update failed (attempt $i/5), retrying in 15s..."
  [ "$i" = 5 ] && { echo "FATAL: apt-get update still failing after 5 attempts" >&2; exit 1; }
  sleep 15
done

echo "== apt-get install tmux (inside chroot)"
for i in 1 2 3; do
  if TMPDIR=/tmp chroot "$ROOTFS" /usr/bin/apt-get install -o Acquire::Queue-Mode=access -y --no-install-recommends tmux; then
    echo "   apt-get install tmux OK"
    break
  fi
  echo "   apt-get install failed (attempt $i/3), retrying in 15s..."
  [ "$i" = 3 ] && { echo "FATAL: apt-get install tmux still failing after 3 attempts" >&2; exit 1; }
  sleep 15
done

# 6. Verify tmux is really in the tree.
echo "== verify tmux"
[ -x "$ROOTFS/usr/bin/tmux" ] || { echo "FATAL: /usr/bin/tmux missing from the tree" >&2; exit 1; }
grep -q "^Package: tmux$" "$ROOTFS/var/lib/dpkg/status" || { echo "FATAL: tmux not in dpkg status" >&2; exit 1; }
TMPDIR=/tmp chroot "$ROOTFS" /usr/bin/tmux -V || { echo "FATAL: tmux -V failed under qemu" >&2; exit 1; }
echo "   tmux installed and runs under qemu"

# 7. Restore real chown/chgrp, verify, remove qemu, unmount.
restore_chown
chroot "$ROOTFS" /usr/bin/chown --version | head -1 || { echo "FATAL: real chown was not restored" >&2; exit 1; }
echo "   real chown/chgrp restored"
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
cleanup_mounts
trap - EXIT

echo "=== TermX slim rootfs fix9 patch finished $(date -u +%FT%TZ) ==="
