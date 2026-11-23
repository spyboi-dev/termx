# TermX

TermX is a Linux terminal for iPhone. It runs a Debian system on the phone, with a shell, `apt`, and a persistent disk.

## Guest

Debian trixie arm64, boots straight to a shell as user `termx` (passwordless sudo). Standard Debian repos are enabled, so `apt install` works. The image is slim (171 packages); Python, Node.js, and Docker are not baked in, install them with `apt` when you need them.

Guest image:
[termx-debian-trixie-arm64-slim.ext4.gz](https://github.com/spyboi-dev/termx/releases/download/rootfs-20261123-slim-fix2/termx-debian-trixie-arm64-slim.ext4.gz)
(116 MB, SHA-256 `c59a7943aee33562a401dbe480e603ae22c0a1cbe5d392ca50e6b5345a56ce62`, extracts to 1 GiB).

## Engine

Based on Kernarium's native Linux kernel (mainline 6.18) running on iOS. The guest gets 2 GiB RAM and a 32 GiB persistent disk, so installs survive reboots.

## What you get

- Debian trixie (arm64) with `apt`
- Python, Node.js, git, and whatever you `apt install`
- A persistent disk, so installs survive reboots
- A terminal with a key row, paste, long-press paste, and separate arrow keys

## Status

In development. No release yet.

## Install

Sideload the IPA with SideStore, AltStore, or LiveContainer. You need a developer certificate or a sideloading setup. iOS 27 or later.

## Build

Build on Linux with clang-18 and ld64.lld-18 against the iOS 26.5 SDK. The Linux runtime framework `KRuntime_6_18_4K` has to be built on a Mac first, because upstream Kernarium refuses non-Apple hosts.

```sh
git clone https://github.com/imxieyi/Kernarium
cd Kernarium
Kernarium/scripts/package-ios-frameworks.sh --sdk device
```

Copy the device slice `KRuntime_6_18_4K.framework` into `Frameworks/` here, then:

```sh
./build.sh
```

That produces `build/TermX.ipa`, an ad-hoc signed IPA. Your installer re-signs the bundle at install time.

## License

GPL-2.0-or-later (`LICENSE-GPL-2.0`). TermX derives from
[imxieyi/Kernarium](https://github.com/imxieyi/Kernarium) (GPL-2.0).
Embedding the GPL runtime makes TermX a GPL-2.0-or-later derivative:
source travels with it. See `PORT-NOTE.md` for the full derivation story.
Terminal UI notices are in `NOTICES-NEWTERM.md`.
