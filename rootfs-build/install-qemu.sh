#!/bin/bash
# Wait for the apt lock (another agent is reinstalling after the VM restart),
# then install qemu-user-static for the slim rootfs build.
LOG="$HOME/workspace/kernarium-termux/rootfs-build/install-qemu.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== install-qemu started $(date -u +%FT%TZ) ==="
for i in $(seq 1 180); do
  if ! pgrep -x apt-get >/dev/null 2>&1 && ! pgrep -x dpkg >/dev/null 2>&1; then
    echo "apt lock free after $((i * 10))s"
    break
  fi
  sleep 10
done
if pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; then
  echo "apt lock still held after 30 min, giving up" >&2; exit 2
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y qemu-user-static
echo "INSTALL-EXIT=$?"
which qemu-aarch64-static
qemu-aarch64-static --version | head -1
ls /usr/lib/binfmt.d/ | grep -i qemu || echo "no qemu binfmt conf yet"
echo "=== install-qemu finished $(date -u +%FT%TZ) ==="
