#!/bin/bash
# TermX post-restart pipeline: wait for the apt lock (another agent is
# reinstalling after the same VM restart), reinstall the toolchain, then
# run the full rootfs build from scratch (the rootfs tree was wiped
# with /opt). Logs to pipeline.log next to build.log.
# SPDX-License-Identifier: GPL-2.0-or-later
LOG="/opt/termx-rootfs-build/pipeline.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== TermX pipeline started $(date -u +%FT%TZ) ==="
for i in $(seq 1 180); do
  if ! pgrep -x apt-get >/dev/null 2>&1 && ! pgrep -x dpkg >/dev/null 2>&1; then
    echo "apt lock free after $((i * 10))s"
    break
  fi
  sleep 10
done
if pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; then
  echo "apt lock still held after 30 min, giving up" >&2
  exit 2
fi
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y clang-18 lld-18 qemu-user-static
echo "TOOLCHAIN-EXIT=$?"
which clang-18 ld64.lld-18 qemu-aarch64-static
bash /opt/termx-rootfs-build/build-rootfs.sh
echo "PIPELINE-EXIT=$?"
