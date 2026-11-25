#!/bin/bash
# Patch the live slim rootfs tree for fix7: install the localhost
# bridge (tx-vsock-bridge) and its systemd service, and refresh the
# motd. Every file edit here mirrors configure-rootfs-slim.sh
# exactly — the script is the source of truth, this patch is the
# iterative shortcut for the live tree (see rebuild-image.sh).
#
# The bridge is what makes guest localhost reachable from the iPhone:
# it listens on vsock 5999, and the TermX app listens on the iPhone's
# 127.0.0.1:PORT and proxies each connection here; the bridge forwards
# it to guest 127.0.0.1:PORT. A guest localhost service then answers
# at the iPhone's localhost, the way it would on a native OS.
#
# Usage: ./patch-rootfs-fix7.sh   (run from rootfs-build/)
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
cd "$(dirname "$0")"
ROOTFS="$PWD/rootfs-slim"
LOG="$PWD/patch-fix7.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== TermX slim rootfs fix7 patch started $(date -u +%FT%TZ) ==="

[ -d "$ROOTFS" ] || { echo "FATAL: live tree $ROOTFS is missing" >&2; exit 1; }
[ -f tx-vsock-bridge ] || { echo "FATAL: tx-vsock-bridge binary is missing — build it first (aarch64-linux-gnu-gcc -static -O2 -o tx-vsock-bridge tx-vsock-bridge.c)" >&2; exit 1; }

echo "== localhost bridge binary"
cp tx-vsock-bridge "$ROOTFS/usr/local/bin/tx-vsock-bridge"
chmod 755 "$ROOTFS/usr/local/bin/tx-vsock-bridge"
file "$ROOTFS/usr/local/bin/tx-vsock-bridge" | grep -q "ARM aarch64" || { echo "FATAL: bridge is not an aarch64 binary" >&2; exit 1; }
echo "   /usr/local/bin/tx-vsock-bridge installed ($(stat -c%s "$ROOTFS/usr/local/bin/tx-vsock-bridge") bytes, aarch64, static)"

echo "== localhost bridge systemd unit"
cat > "$ROOTFS/etc/systemd/system/tx-vsock-bridge.service" <<'EOF'
[Unit]
Description=TermX localhost bridge (vsock to guest loopback)
Documentation=https://github.com/spyboi-dev/termx

[Service]
Type=simple
ExecStart=/usr/local/bin/tx-vsock-bridge
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$ROOTFS/etc/systemd/system/tx-vsock-bridge.service"
# Enable it: the symlink systemd enable creates.
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/tx-vsock-bridge.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/tx-vsock-bridge.service"
echo "   unit installed and enabled (multi-user.target.wants)"

echo "== motd: refresh with the fix7 text (identical to configure-rootfs-slim.sh)"
cat > "$ROOTFS/etc/motd" <<'EOF'
TermX — minimal Debian trixie on a real Linux kernel, inside iOS.
You are user "termx" (passwordless sudo). apt works, fastfetch is
installed (try "fastfetch"), and Docker runs too once installed:
"sudo apt install docker.io", then "sudo docker run hello-world".
Pinch to zoom the terminal; your files and installs live on the
data disk and survive reboots. A service on guest localhost
(127.0.0.1) is reachable from the iPhone at the same address.
EOF
chmod 644 "$ROOTFS/etc/motd"

echo "== drift checks: tree files must match configure-rootfs-slim.sh"
# motd: extract the script's heredoc body and diff it.
sed -n "/cat > \/etc\/motd <<'EOF'/,/^EOF$/p" \
  configure-rootfs-slim.sh | sed '1d;$d' > "$PWD/tmp-motd-check"
diff "$PWD/tmp-motd-check" "$ROOTFS/etc/motd" \
  && echo "motd: tree matches script" || { echo "FATAL: motd drifted from script" >&2; exit 1; }
rm -f "$PWD/tmp-motd-check"
# Unit: extract the script's heredoc body and diff it.
sed -n "/cat > \/etc\/systemd\/system\/tx-vsock-bridge.service <<'EOF'/,/^EOF$/p" \
  configure-rootfs-slim.sh | sed '1d;$d' > "$PWD/tmp-unit-check"
diff "$PWD/tmp-unit-check" "$ROOTFS/etc/systemd/system/tx-vsock-bridge.service" \
  && echo "tx-vsock-bridge.service: tree matches script" || { echo "FATAL: unit drifted from script" >&2; exit 1; }
rm -f "$PWD/tmp-unit-check"
# Enable symlink present.
[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/tx-vsock-bridge.service" ] \
  && echo "unit: enabled (symlink present)" || { echo "FATAL: enable symlink missing" >&2; exit 1; }

# Verify the unit parses, inside the tree under qemu (best effort:
# if the binfmt setup is unavailable the file checks above are the
# hard requirement, and the configure script's own verify covers a
# from-scratch build).
mkdir -p /proc/sys/fs/binfmt_misc
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  cat /usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
fi
if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/" 2>/dev/null || true
  if chroot "$ROOTFS" /usr/bin/systemd-analyze verify tx-vsock-bridge.service 2>&1 | tee "$PWD/tmp-verify.log" | grep -qi "error\|failed"; then
    echo "WARNING: systemd-analyze verify reported issues (see $PWD/tmp-verify.log)" >&2
  else
    echo "unit: systemd-analyze verify clean"
  fi
  rm -f "$ROOTFS/usr/bin/qemu-aarch64-static" "$PWD/tmp-verify.log"
else
  echo "unit: binfmt unavailable, skipping systemd-analyze verify (file checks passed)"
fi

echo "=== TermX slim rootfs fix7 patch finished $(date -u +%FT%TZ) ==="
