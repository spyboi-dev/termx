# TermX guest boot base archive

`uml-boot-base-aarch64.cpio.gz` is the static BusyBox + e2fsprogs initramfs
base every Linux guest boots through. It is built on Linux with upstream
Kernarium's own producer (`../build-boot-base.sh`, which replicates
`upstream/tools/rootfs/starter/build-all.sh --product boot-base-aarch64` with
the same pinned Buildroot 2026.05.3 and BusyBox 1.38.0 inputs), because the
published starter release does not exist for the pinned Kernarium commit and
the archive cannot be built on macOS.

- Size: 1,398,102 bytes
- SHA-256: 9e3bfe90695b5112fcd94bdfa69d1217fa6370624bdc3b919d952a56e7cfe929
- Verified with upstream's `tools/rootfs/boot-ramdisk/verify_base.py`
  (41 entries, aarch64, static binaries, 16 KiB ELF segments).

The Mac workflow stages this archive and accepts it by rewriting the
boot-base descriptor from its size and SHA-256 (same pattern as the kernel
bundle accept step). License: GPL-2.0-or-later (BusyBox, e2fsprogs,
Buildroot); the corresponding sources are the pinned tarballs named in
`../build-boot-base.sh`.
