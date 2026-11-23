# TermX

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE-GPL-2.0)

A real Linux terminal for iPhone, based on the native Linux kernel by Kernarium.

TermX runs a Debian system on the phone. You get a shell, `apt`, and a persistent disk. Everything runs on-device.

## Features

- Debian trixie (arm64) with `apt`
- Python, Node.js, git, and whatever you `apt install`
- A persistent disk, so installs survive reboots
- 2 GiB RAM, 32 GiB disk
- A terminal with a key row, paste, long-press paste, and separate arrow keys

## Guest

Debian trixie arm64, boots straight to a shell as user `termx` (passwordless sudo). Standard Debian repos are enabled, so `apt install` works. The image is slim (171 packages); Python, Node.js, and Docker are not baked in, install them with `apt` when you need them.

Guest image:
[termx-debian-trixie-arm64-slim.ext4.gz](https://github.com/spyboi-dev/termx/releases/download/rootfs-20261123-slim-fix2/termx-debian-trixie-arm64-slim.ext4.gz)
(116 MB, SHA-256 `c59a7943aee33562a401dbe480e603ae22c0a1cbe5d392ca50e6b5345a56ce62`, extracts to 1 GiB).

## Requirements

- iPhone or iPad, iOS 27 or later
- A sideloading setup (SideStore, AltStore, or LiveContainer) with a developer certificate

## Installation

1. Download the latest development IPA from [Releases](https://github.com/spyboi-dev/termx/releases). There is no stable release yet.
2. Sideload it with SideStore, AltStore, or LiveContainer.
3. Open TermX. Tap Install to download the Debian image, then the shell starts on its own.

## Getting started

```sh
sudo apt update
sudo apt install fastfetch
fastfetch
```

`~/.local/bin` is on PATH, and plain `pip3 install` works once Python is installed.

## How it works

TermX is based on the native Linux kernel by Kernarium (mainline 6.18). The guest is a Debian image with systemd, booted from a read-only system image with a persistent data disk on top. The UI is a native iOS terminal.

## Limitations

- Device info is incomplete: fastfetch reports the CPU as Unknown and the host as Virtual Machine, because the guest kernel does not know it runs on an Apple A16.
- Docker is config-plausible but has not been run in this runtime yet.
- The app must stay in the foreground; iOS can suspend it, and the guest stops with the app.
- Sideload only. A free Apple ID certificate expires after 7 days and must be refreshed.

## Build from source

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
