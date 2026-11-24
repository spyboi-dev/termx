# TermX

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE-GPL-2.0)

TermX is a Linux terminal for iPhone. It runs Debian on Kernarium's native Linux kernel (mainline 6.18).

## Features

- Debian trixie (arm64) with `apt`
- systemd as init

## Guest

Debian trixie arm64, boots straight to a shell as user `termx` (passwordless sudo). Standard Debian repos are enabled. The image is slim (171 packages); install Python, Node.js, and Docker with `apt`. Docker runs: `sudo docker run --rm hello-world` pulls the arm64 image and prints "Hello from Docker!".

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

The guest boots from a read-only system image, with a persistent data disk on top. The UI is a native iOS terminal.

## Limitations

- Device info is incomplete: fastfetch reports the CPU as Unknown and the host as Virtual Machine, because the guest kernel does not know it runs on an Apple A16.
- When you leave the app, the guest pauses (its disk is saved first) and resumes when you return. It does not run in the background.
- Memory: the IPA is adhoc-signed, so the increased-memory-limit entitlement is not granted; the guest runs under iOS's standard per-process memory limit, with a 1 GiB reserve. That entitlement needs a provisioning profile that carries it, which a free developer account cannot get.
- Sideload only. A free Apple ID certificate expires after 7 days and must be refreshed.

## Build from source

Build on Linux with clang-18 and ld64.lld-18 against the iOS 26.5 SDK. The runtime framework `KRuntime_6_18_4K` must be built on a Mac first; upstream Kernarium only builds on Apple hosts.

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
Embedding the GPL runtime makes TermX a GPL-2.0-or-later derivative, and the source is included. See `PORT-NOTE.md` for the derivation.
Terminal UI notices are in `NOTICES-NEWTERM.md`.
