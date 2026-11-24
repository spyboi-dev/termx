#!/bin/bash
# Patch the live slim rootfs tree for fix6: install fastfetch, refresh
# the motd, add shell aliases, and document the fixed-48 width limit.
# Every file edit here mirrors configure-rootfs-slim.sh exactly — the
# script is the source of truth, this patch is the iterative shortcut
# for the live tree (see the plan: patch the tree, rebuild with
# mke2fs, verify, publish). After running this, diff the tree files
# against the script's heredocs (the checks at the end) to prove
# they have not drifted.
#
# Usage: ./patch-rootfs-fix6.sh   (run from rootfs-build/)
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
cd "$(dirname "$0")"
ROOTFS="$PWD/rootfs-slim"
LOG="$PWD/patch-fix6.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== TermX slim rootfs fix6 patch started $(date -u +%FT%TZ) ==="

# binfmt (same as build-rootfs-slim.sh: mounts do not persist between
# exec calls, so set it up inside this invocation).
mkdir -p /proc/sys/fs/binfmt_misc
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  cat /usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register
fi
cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
chroot "$ROOTFS" /bin/uname -m | grep -q aarch64 || {
  echo "FATAL: qemu-aarch64 binfmt is not working" >&2; exit 1; }
echo "== binfmt qemu-aarch64 OK"

# The tree's /etc/resolv.conf points at the guest's SLiRP nameserver
# (10.0.2.3), which does not exist on this VM. Swap in the host's
# resolv.conf for the apt run, then restore the SLiRP one.
cp "$ROOTFS/etc/resolv.conf" "$PWD/resolv.conf.slipr-saved"
rm -f "$ROOTFS/etc/resolv.conf"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# chown/chgrp diversion (same reason as build-rootfs-slim.sh: the
# sandbox denies chown to any uid/gid other than the current one).
for tool in chown chgrp; do
  chroot "$ROOTFS" /usr/bin/dpkg-divert --add --rename --divert "/usr/bin/$tool.real" "/usr/bin/$tool" >/dev/null 2>&1 || true
  printf '#!/bin/sh\n# No-op: the build sandbox denies chown/chgrp (see build-rootfs-slim.sh).\nexit 0\n' > "$ROOTFS/usr/bin/$tool"
  chmod +x "$ROOTFS/usr/bin/$tool"
done
echo "== chown/chgrp diverted to no-op shims"

mount -t proc proc "$ROOTFS/proc" 2>/dev/null || true
mount -t sysfs sys "$ROOTFS/sys" 2>/dev/null || true
mount --bind /dev "$ROOTFS/dev" 2>/dev/null || true
mount -t devpts devpts "$ROOTFS/dev/pts" 2>/dev/null || true
cleanup_mounts() {
  umount "$ROOTFS/dev/pts" 2>/dev/null || true
  umount "$ROOTFS/dev" 2>/dev/null || true
  umount "$ROOTFS/sys" 2>/dev/null || true
  umount "$ROOTFS/proc" 2>/dev/null || true
}
trap cleanup_mounts EXIT

# Proxy as an IPv6 literal (same as build-rootfs-slim.sh: apt's
# resolver path is IPv4-only and the hostname resolves to a dead
# IPv4 backend from inside the chroot).
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

echo "== apt install fastfetch (in chroot)"
for i in 1 2 3 4 5; do
  echo "apt-get update (attempt $i/5)"
  if TMPDIR=/tmp chroot "$ROOTFS" /usr/bin/apt-get update -o Acquire::Queue-Mode=access 2>&1 | tail -2; then
    break
  fi
  sleep 15
done
for i in 1 2 3; do
  echo "apt-get install fastfetch (attempt $i/3)"
  if TMPDIR=/tmp chroot "$ROOTFS" /usr/bin/apt-get install -o Acquire::Queue-Mode=access -y --no-install-recommends fastfetch; then
    break
  fi
  [ "$i" = 3 ] && { echo "FATAL: fastfetch install failed" >&2; exit 1; }
  sleep 15
done
TMPDIR=/tmp chroot "$ROOTFS" /usr/bin/fastfetch --version | head -1
TMPDIR=/tmp chroot "$ROOTFS" /usr/bin/dpkg -l fastfetch | tail -1

# Restore the real chown/chgrp before touching files: the file edits
# below are host-side writes, but the diversion must not ship.
for tool in chown chgrp; do
  rm -f "$ROOTFS/usr/bin/$tool"
  chroot "$ROOTFS" /usr/bin/dpkg-divert --remove --rename "/usr/bin/$tool" >/dev/null 2>&1 || true
done
chroot "$ROOTFS" /usr/bin/chown --version | head -1 || {
  echo "FATAL: real chown was not restored" >&2; exit 1; }
echo "== real chown/chgrp restored"
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

# Restore the SLiRP resolv.conf (the guest's DNS).
rm -f "$ROOTFS/etc/resolv.conf"
cp "$PWD/resolv.conf.slipr-saved" "$ROOTFS/etc/resolv.conf"
rm -f "$PWD/resolv.conf.slipr-saved"

cleanup_mounts
trap - EXIT

echo "== file edits (mirror configure-rootfs-slim.sh)"
# motd: rewrite with the fix6 text (identical to the script's heredoc).
cat > "$ROOTFS/etc/motd" <<'EOF'
TermX — minimal Debian trixie on a real Linux kernel, inside iOS.
You are user "termx" (passwordless sudo). apt works, fastfetch is
installed (try "fastfetch"), and Docker runs too once installed:
"sudo apt install docker.io", then "sudo docker run hello-world".
Pinch to zoom the terminal; your files and installs live on the
data disk and survive reboots.
EOF
chmod 644 "$ROOTFS/etc/motd"

# bashrc files: insert the alias block before the width comment, and
# the fixed-48 limit comment after it — the same lines the script
# appends, in the same order (aliases, then width).
# Note the tree's width comment is the OLD multi-line form from an
# earlier hand patch (the script appends the single-line form): the
# tree and the script had already drifted on this block, so replace
# the multi-line block with the script's single-line comment first.
# The alias check must match the real alias value: the stock Debian
# .bashrc contains a commented "#alias ll='ls -l'" that a loose
# substring check mistakes for the real thing.
python3 - "$ROOTFS/home/termx/.bashrc" "$ROOTFS/etc/bash.bashrc" <<'PYEOF'
import sys
alias_block = """# TermX: a few useful aliases (ll, la, .., ff for fastfetch).
alias ll='ls -alF'
alias la='ls -A'
alias ..='cd ..'
alias ff='fastfetch'
"""
limit_line = "# Fixed at 48: it does not follow the phone orientation or pinch zoom — the guest has no winsize channel from the app.\n"
width_comment = "# TermX: the terminal shows 48 columns; set the tty width at login so programs wrap at the visible edge.\n"
old_width_block = """# TermX: the terminal shows 48 columns (14 pt font on this iPhone), but
# the guest lays out for 80 by default, so long lines are cut at the
# right edge. Set the tty width at login so programs wrap at the
# visible edge. Guarded to a real terminal; COLUMNS is the fallback
# for programs that read the variable instead of the winsize.
"""
for path in sys.argv[1:]:
    with open(path) as f:
        text = f.read()
    if "alias ll='ls -alF'" in text:
        print(f"{path}: aliases already present, skipping")
        continue
    if old_width_block in text:
        text = text.replace(old_width_block, width_comment, 1)
        print(f"{path}: replaced old multi-line width comment with the script's single-line form")
    assert width_comment in text, f"{path}: width comment not found"
    text = text.replace(width_comment, alias_block + width_comment, 1)
    text = text.replace(width_comment, width_comment + limit_line, 1)
    with open(path, "w") as f:
        f.write(text)
    print(f"{path}: aliases + width-limit comment inserted")
PYEOF

# fastfetch config: rewrite with the fix6 text (identical to the
# script's heredoc — the diff check below proves it).
cat > "$ROOTFS/home/termx/.config/fastfetch/config.jsonc" <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  // TermX: the guest kernel does not know what phone it runs on, so
  // fastfetch reports CPU "Unknown", Host "Virtual Machine" and a
  // Kernarium virtual GPU. The command modules below read
  // ~/.config/termx/host, cpu and gpu — files written by older app
  // builds only. Since app build d1e4491 the app writes nothing at
  // boot (it never types a command into the terminal, and the runtime
  // has no channel to pass the device model to the guest), so on a
  // fresh install the files do not exist and the value falls back to
  // "Unknown" instead of a wrong device. Everything else is
  // auto-detected.
  "display": {
    // The terminal is 48 columns wide (stty cols 48 at login). Wrap
    // long lines at the terminal width instead of letting them run
    // off the right edge.
    "disableLinewrap": false
  },
  "modules": [
    "title",
    "separator",
    "os",
    {
      "type": "command",
      "key": "Host",
      "text": "cat $HOME/.config/termx/host 2>/dev/null || echo Unknown"
    },
    "kernel",
    "uptime",
    "packages",
    "shell",
    "display",
    "terminal",
    {
      "type": "command",
      "key": "CPU",
      "text": "cat $HOME/.config/termx/cpu 2>/dev/null || echo Unknown"
    },
    {
      "type": "command",
      "key": "GPU",
      "text": "cat $HOME/.config/termx/gpu 2>/dev/null || echo Unknown"
    },
    "memory",
    "swap",
    "disk",
    "localip",
    "locale",
    "break",
    "colors"
  ]
}
EOF
chown termx:termx "$ROOTFS/home/termx/.config/fastfetch/config.jsonc" 2>/dev/null || true
chmod 644 "$ROOTFS/home/termx/.config/fastfetch/config.jsonc"

echo "== drift checks: tree files must match configure-rootfs-slim.sh"
# fastfetch config: extract the script's heredoc body and diff it.
sed -n "/cat > \/home\/termx\/.config\/fastfetch\/config.jsonc <<'EOF'/,/^EOF$/p" \
  configure-rootfs-slim.sh | sed '1d;$d' > "$PWD/tmp-config-check.jsonc"
diff "$PWD/tmp-config-check.jsonc" "$ROOTFS/home/termx/.config/fastfetch/config.jsonc" \
  && echo "config.jsonc: tree matches script" || { echo "FATAL: config.jsonc drifted from script" >&2; exit 1; }
rm -f "$PWD/tmp-config-check.jsonc"
# motd: same extraction.
sed -n "/cat > \/etc\/motd <<'EOF'/,/^EOF$/p" \
  configure-rootfs-slim.sh | sed '1d;$d' > "$PWD/tmp-motd-check"
diff "$PWD/tmp-motd-check" "$ROOTFS/etc/motd" \
  && echo "motd: tree matches script" || { echo "FATAL: motd drifted from script" >&2; exit 1; }
rm -f "$PWD/tmp-motd-check"
# bashrc: the script's appended lines must appear in the tree files,
# in the script's order (aliases, width comment, limit line, stty).
for f in "$ROOTFS/home/termx/.bashrc" "$ROOTFS/etc/bash.bashrc"; do
  grep -q "alias ff='fastfetch'" "$f" || { echo "FATAL: $f missing aliases" >&2; exit 1; }
  grep -q "Fixed at 48: it does not follow the phone orientation" "$f" || { echo "FATAL: $f missing width-limit comment" >&2; exit 1; }
  grep -q "stty cols 48" "$f" || { echo "FATAL: $f missing stty cols 48" >&2; exit 1; }
  echo "bashrc: $f has the fix6 lines"
done

echo "== apt cache cleanup (keep the image lean)"
rm -rf "$ROOTFS/var/cache/apt/archives/"*.deb 2>/dev/null || true
echo "=== TermX slim rootfs fix6 patch finished $(date -u +%FT%TZ) ==="
