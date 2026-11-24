#!/bin/bash
# rebuild-image.sh — the TermX guest-image iteration loop, in one command.
#
# The old loop was six manual steps that could drift: patch the live
# tree, rebuild with mke2fs, verify, hash, publish the release, and
# update the app constants — and nothing enforced that the live tree
# still matched configure-rootfs-slim.sh (the source of truth). This
# script runs the whole loop and refuses to proceed if the tree has
# drifted from the script.
#
# Usage: ./rebuild-image.sh fix7 [--dry-run] [--skip-patch]
#   fix7        the fix number for the new image (tag becomes
#               rootfs-<today>-slim-fix7)
#   --dry-run   run the checks and print what would happen, without
#               building, publishing, or touching GuestInstall.m
#   --skip-patch
#               do not run patch-rootfs-fixN.sh even if it exists
#               (use when the tree was already patched by hand)
#
# Flow:
#   1. Run rootfs-build/patch-rootfs-fixN.sh if it exists (the patch
#      mirrors configure-rootfs-slim.sh into the live tree; it is the
#      iterative shortcut, see patch-rootfs-fix6.sh).
#   2. Drift check: the tree's config.jsonc, motd, and bashrc files
#      must match configure-rootfs-slim.sh. Refuse on any drift.
#   3. mke2fs -d the tree into the 1 GiB ext4 image (same size formula
#      as build-rootfs-slim.sh: used + 40% headroom, at least 1024 MiB).
#   4. e2fsck + debugfs spot checks, chmod 444 (read-only, as the
#      runtime requires).
#   5. gzip -9 -k, SHA-256 both files, refresh SHA256SUMS-slim.
#   6. Publish the .gz as a GitHub release (tag rootfs-<date>-slim-fixN).
#   7. Update the app constants in termx/src/GuestInstall.m (URL,
#      both SHA-256s, extracted size) so the next app build installs
#      the new image. A phone holding the older image boots it as-is
#      and is offered the new one as an Update.
#
# Run from rootfs-build/ (the script cds to its own directory).
# Expects the same privileges as build-rootfs-slim.sh. /tmp is a
# 512M tmpfs, so TMPDIR is set to rootfs-build/tmp.
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")"

FIX="${1:-}"
DRY_RUN=0
SKIP_PATCH=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-patch) SKIP_PATCH=1 ;;
    fix*) FIX="$arg" ;;
    *) echo "Usage: $0 fixN [--dry-run] [--skip-patch]" >&2; exit 2 ;;
  esac
done
if [ -z "$FIX" ]; then
  echo "Usage: $0 fixN [--dry-run] [--skip-patch]" >&2
  exit 2
fi
case "$FIX" in
  fix[0-9]*) ;;
  *) echo "ERROR: fix number must look like fix7, got '$FIX'" >&2; exit 2 ;;
esac

ROOTFS="$PWD/rootfs-slim"
IMG="$PWD/termx-debian-trixie-arm64-slim.ext4"
SCRIPT="configure-rootfs-slim.sh"
DATE="$(date +%Y%m%d)"
TAG="rootfs-${DATE}-slim-${FIX}"
APP_CONSTANTS="../termx/src/GuestInstall.m"

export TMPDIR="$PWD/tmp"
mkdir -p "$TMPDIR"

for tool in mke2fs e2fsck debugfs gzip sha256sum python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is not installed" >&2; exit 1; }
done
[ -d "$ROOTFS" ] || { echo "ERROR: live tree $ROOTFS is missing" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "ERROR: $SCRIPT is missing" >&2; exit 1; }
[ -f "$APP_CONSTANTS" ] || { echo "ERROR: $APP_CONSTANTS is missing" >&2; exit 1; }

echo "=== TermX image rebuild $TAG $(date -u +%FT%TZ) ==="
[ "$DRY_RUN" = 1 ] && echo "(dry run: checks only, nothing is built or published)"

# 1. Patch the tree (the fix's own patch script, if it exists).
PATCH="patch-rootfs-${FIX}.sh"
if [ "$SKIP_PATCH" = 0 ] && [ -f "$PATCH" ]; then
  echo "== running $PATCH"
  if [ "$DRY_RUN" = 1 ]; then
    echo "   (dry run: would run ./$PATCH)"
  else
    bash "./$PATCH"
  fi
elif [ "$SKIP_PATCH" = 0 ]; then
  echo "== no $PATCH — drift check only (tree must already match $SCRIPT)"
fi

# 2. Drift checks: the tree must match the configure script.
# config.jsonc: extract the script's heredoc body and diff it.
echo "== drift checks: tree must match $SCRIPT"
sed -n "/cat > \/home\/termx\/.config\/fastfetch\/config.jsonc <<'EOF'/,/^EOF$/p" \
  "$SCRIPT" | sed '1d;$d' > "$TMPDIR/drift-config.jsonc"
diff "$TMPDIR/drift-config.jsonc" "$ROOTFS/home/termx/.config/fastfetch/config.jsonc" \
  && echo "   config.jsonc: tree matches script" \
  || { echo "FATAL: config.jsonc drifted from script — patch the tree (or the script) first" >&2; exit 1; }
# motd: same extraction.
sed -n "/cat > \/etc\/motd <<'EOF'/,/^EOF$/p" \
  "$SCRIPT" | sed '1d;$d' > "$TMPDIR/drift-motd"
diff "$TMPDIR/drift-motd" "$ROOTFS/etc/motd" \
  && echo "   motd: tree matches script" \
  || { echo "FATAL: motd drifted from script — patch the tree (or the script) first" >&2; exit 1; }
# bashrc: the script's appended lines must appear in the tree files.
for f in "$ROOTFS/home/termx/.bashrc" "$ROOTFS/etc/bash.bashrc"; do
  grep -q "alias ff='fastfetch'" "$f" || { echo "FATAL: $f missing aliases" >&2; exit 1; }
  grep -q "Fixed at 48: it does not follow the phone orientation" "$f" || { echo "FATAL: $f missing width-limit comment" >&2; exit 1; }
  grep -q "stty cols 48" "$f" || { echo "FATAL: $f missing stty cols 48" >&2; exit 1; }
  echo "   bashrc: $f has the fix lines"
done

if [ "$DRY_RUN" = 1 ]; then
  echo "== dry run: would now mke2fs the tree, e2fsck it, gzip it,"
  echo "   publish release $TAG, and update $APP_CONSTANTS"
  echo "   (tag $TAG, image $IMG)"
  echo "OK: dry run passed — tree matches script, ready to build"
  exit 0
fi

# 3. Build the image (same size formula as build-rootfs-slim.sh).
USED_MB=$(du -sm "$ROOTFS" | cut -f1)
IMG_MB=$(( (USED_MB * 14 / 10 + 15) / 16 * 16 ))  # 40% headroom
[ "$IMG_MB" -lt 1024 ] && IMG_MB=1024
BLOCKS=$(( IMG_MB * 1024 ))
echo "== building ext4 image: ${IMG_MB} MiB ($BLOCKS 1K blocks), tree uses ${USED_MB} MiB"
rm -f "$IMG"
mke2fs -t ext4 -L termx-root -m 0 -d "$ROOTFS" "$IMG" "$BLOCKS"

# 4. Verify.
echo "== e2fsck"
e2fsck -fn "$IMG"
echo "== debugfs spot checks"
debugfs -R "stat /sbin/init" "$IMG" 2>/dev/null | head -3
debugfs -R "ls -l /home/termx/.config/fastfetch" "$IMG" 2>/dev/null | grep -q config.jsonc \
  || { echo "FATAL: fastfetch config missing from the image" >&2; exit 1; }
if debugfs -R "ls -l /usr/bin/fastfetch" "$IMG" 2>/dev/null | grep -q fastfetch; then
  echo "   fastfetch binary present"
else
  echo "   WARNING: fastfetch binary not in the image (config ships anyway)"
fi
chmod 444 "$IMG"

# 5. Compress + hash.
echo "== gzip + hashes"
rm -f "$IMG.gz"
gzip -9 -k "$IMG"
ls -lh "$IMG" "$IMG.gz"
sha256sum "$IMG" "$IMG.gz" | tee "$PWD/SHA256SUMS-slim"
GZ_SHA=$(sha256sum "$IMG.gz" | cut -d' ' -f1)
IMG_SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
IMG_SIZE=$(stat -c%s "$IMG")
echo "   gz   SHA-256 $GZ_SHA"
echo "   img  SHA-256 $IMG_SHA"
echo "   img  size $IMG_SIZE bytes"

# 6. Publish the release.
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated — the image is built and hashed, but not published." >&2
  echo "Run 'gh auth login', then publish the already-built image by hand:" >&2
  echo "  gh release create $TAG \"$IMG.gz\" --repo spyboi-dev/termx --title \"TermX slim image $TAG\" --notes \"Debian trixie arm64 slim guest image.\"" >&2
  echo "Then re-run this script with --skip-patch to update the app constants (it rebuilds the image, which is fast — mke2fs, not debootstrap)." >&2
  exit 1
fi
if gh release view "$TAG" --repo spyboi-dev/termx >/dev/null 2>&1; then
  echo "ERROR: release $TAG already exists — pick a new fix number, do not overwrite." >&2
  exit 1
fi
echo "== publishing release $TAG"
gh release create "$TAG" "$IMG.gz" --repo spyboi-dev/termx \
  --title "TermX slim image $TAG" \
  --notes "Debian trixie arm64 slim guest image ($FIX). Extracts to $IMG_SIZE bytes. SHA-256 (gz) $GZ_SHA, (img) $IMG_SHA."

# 7. Update the app constants so the next app build installs it.
echo "== updating $APP_CONSTANTS"
URL="https://github.com/spyboi-dev/termx/releases/download/${TAG}/termx-debian-trixie-arm64-slim.ext4.gz"
python3 - "$APP_CONSTANTS" "$TAG" "$URL" "$GZ_SHA" "$IMG_SHA" "$IMG_SIZE" <<'PYEOF'
import re, sys
path, tag, url, gz_sha, img_sha, img_size = sys.argv[1:7]
with open(path) as f:
    text = f.read()
# Release tag in the header comment and in the URL.
text, n1 = re.subn(r"rootfs-\d{8}-slim-fix\d+", tag, text)
assert n1 >= 1, "release tag not found in GuestInstall.m"
text, n2 = re.subn(r'@"https://github\.com/spyboi-dev/termx/releases/download/[^"]+\.gz"',
                   '@"%s"' % url, text)
assert n2 == 1, "kRootfsURL not found"
text, n3 = re.subn(r'(kRootfsGzSHA256 = @")[0-9a-f]{64}(")',
                   r'\g<1>%s\g<2>' % gz_sha, text)
assert n3 == 1, "kRootfsGzSHA256 not found"
text, n4 = re.subn(r'(kRootfsSHA256 = @")[0-9a-f]{64}(")',
                   r'\g<1>%s\g<2>' % img_sha, text)
assert n4 == 1, "kRootfsSHA256 not found"
text, n5 = re.subn(r'(const long long kRootfsSize = )\d+',
                   r'\g<1>%s' % img_size, text)
assert n5 == 1, "kRootfsSize not found"
# The trailing comment says "exactly 1 GiB": keep it honest if a
# future image is bigger than 1 GiB.
size_mib = int(img_size) // (1024 * 1024)
if size_mib == 1024:
    text = re.sub(r'\(exactly 1 GiB\)', '(exactly 1 GiB)', text)
else:
    text = re.sub(r'\(exactly 1 GiB\)', '(%d MiB)' % size_mib, text)
with open(path, "w") as f:
    f.write(text)
print("   tag %s, gz %s…, img %s…, size %s" % (tag, gz_sha[:12], img_sha[:12], img_size))
PYEOF

echo "=== TermX image rebuild finished: $TAG ==="
echo "Next steps:"
echo "  1. git add $SCRIPT $PATCH SHA256SUMS-slim (if new) and commit the image change."
echo "  2. Rebuild the app (termx/build.sh) — it now points at $TAG."
echo "  3. Ship the app build; phones on the older image are offered $TAG as an Update."
