# rootfs-build — the TermX guest image

The guest is a minimal Debian trixie arm64 rootfs. It boots to a shell
as user `termx`, with working apt and networking; users apt-install
what they need. The app downloads it from a GitHub release — it is
not in the IPA.

## The files

- `configure-rootfs-slim.sh` — **the source of truth.** Everything
  the image contains (packages, users, hostname, prompt, bashrc
  width, fastfetch config, motd, pip config, DNS) is defined here.
  A full build runs this inside the chroot.
- `rootfs-slim/` — the **live tree**: the unpacked rootfs the image
  is built from. Patch this for a fix, then rebuild with `mke2fs`.
- `build-rootfs-slim.sh` — full from-scratch build: debootstrap
  `--foreign` → second stage under qemu → `configure-rootfs-slim.sh`
  in chroot → `mke2fs` → `e2fsck` → `gzip` → SHA-256. Slow and
  fragile behind the VM egress proxy (retried in-script); use it
  only when the tree itself is lost or the base needs rebuilding.
- `patch-rootfs-fixN.sh` — a fix's patch: installs packages in the
  chroot and mirrors the `configure-rootfs-slim.sh` edits into the
  live tree, with drift checks at the end proving the tree matches
  the script. One per fix; `patch-rootfs-fix6.sh` is the example.
- `rebuild-image.sh` — **the iteration loop, use this.** One command
  runs patch → drift check → `mke2fs` → `e2fsck` → `gzip` → hashes
  → `SHA256SUMS-slim` → publish the release → update the app
  constants in `termx/src/GuestInstall.m`. Refuses to proceed on
  drift. See its header.
- `SHA256SUMS-slim` — the current image's hashes (gz + extracted).
- `termx-debian-trixie-arm64-slim.ext4[.gz]` — the current built
  image (fix6). The `.gz` is what the app downloads.

## The rule

**The tree and the script must never drift.** Every tree patch
mirrors `configure-rootfs-slim.sh` exactly, and the drift checks in
the patch scripts and in `rebuild-image.sh` prove it (config.jsonc
and motd by diff, bashrc by grep). A full rebuild from the script
alone must reproduce the tree. If a check fails, fix the tree or
the script — never ship a drifted image.

## Image layout

Exactly 1 GiB ext4 (`-L termx-root -m 0`), read-only (`chmod 444`)
once built — the runtime requires no write bits. The size formula
is the tree's used space + 40% headroom, at least 1024 MiB, rounded
up to 16 MiB (see `build-rootfs-slim.sh`); the app's
`kRootfsSize` constant must match the extracted size exactly.
