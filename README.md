# TermX

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE-GPL-2.0)

TermX is a Linux terminal for iPhone. It runs Debian on Kernarium's native Linux kernel (mainline 6.18).

## Features

- Debian trixie (arm64) with `apt`
- systemd as init
- A native terminal: incremental rendering, Alt/Ctrl keys, pinch to zoom, tap-URL, haptics

## Guest

Debian trixie arm64, boots straight to a shell as user `termx` (passwordless sudo). Standard Debian repos are enabled. The image is slim (173 packages, fastfetch preinstalled); install Python, Node.js, and Docker with `apt`. Docker runs: `sudo docker run --rm hello-world` pulls the arm64 image and prints "Hello from Docker!".

Guest image:
[termx-debian-trixie-arm64-slim.ext4.gz](https://github.com/spyboi-dev/termx/releases/download/rootfs-20261124-slim-fix6/termx-debian-trixie-arm64-slim.ext4.gz)
(150 MB, SHA-256 `417011127ba253532a8339cade70a7723d6135707b71a6a08cfeb7b25c430025`, extracts to 1 GiB, SHA-256 `995940f8690a338752730b89ff5bfedd28d4af320b89651b9fd9c872e7912a0a`).

## Requirements

- iPhone or iPad, iOS 27 or later
- A sideloading setup (SideStore, AltStore, or LiveContainer) with a developer certificate

## Installation

1. Download the latest development IPA from [Releases](https://github.com/spyboi-dev/termx/releases). There is no stable release yet.
2. Sideload it with SideStore, AltStore, or LiveContainer.
3. Open TermX. Tap Install to download the Debian image, then the shell starts on its own.

## Getting started

```sh
fastfetch
sudo apt update
sudo apt install python3 git
```

`~/.local/bin` is on PATH, and plain `pip3 install` works once Python is installed.

## How it works

The guest boots from a read-only system image, with a persistent data disk on top. The UI is a native iOS terminal. The app version, image version, and runtime version are shown on the About screen.

## Limitations

- Device info is incomplete: on a fresh install fastfetch shows Host, CPU, and GPU as Unknown. The guest kernel genuinely does not know what phone it runs on, and the app never types a command into the terminal at boot, so it cannot pass the model in. The runtime has no channel for it either (the boot struct carries no kernel command line). Older installs may still show values written by earlier builds.
- The terminal is 48 columns wide. The width does not follow the phone orientation or pinch zoom: there is no winsize channel from the app to the guest, so the shell sets `stty cols 48` at login and stays there. Pinch zoom changes only the display size.
- When you leave the app, the guest pauses (its disk is saved first) and resumes when you return. It does not run in the background. Background audio, location, or fetch modes would violate Apple's rules if used to keep a Linux guest alive, so none are used.
- Memory: the IPA is adhoc-signed, so the increased-memory-limit entitlement is not granted; the guest runs under iOS's standard per-process memory limit, with a 1 GiB reserve. That entitlement needs a provisioning profile that carries it, which a free developer account cannot get.
- Sideload only. A free Apple ID certificate expires after 7 days and must be refreshed.

## Build from source

See [BUILD.md](BUILD.md) for the full step-by-step guide: SDKs, the runtime framework (built by the [CI workflow](.github/workflows/build-framework.yml) — the primary route), the toolchain, and how to verify the IPA.

The short version: the runtime framework `KRuntime_6_18_4K` must be built on a Mac first (upstream Kernarium only builds on Apple hosts); copy it into `Frameworks/`, then run `./build.sh` in `termx/`. That produces `build/TermX.ipa`, an ad-hoc signed IPA. Your installer re-signs the bundle at install time.

## License

GPL-2.0-or-later (`LICENSE-GPL-2.0`). TermX derives from
[imxieyi/Kernarium](https://github.com/imxieyi/Kernarium) (GPL-2.0).
Embedding the GPL runtime makes TermX a GPL-2.0-or-later derivative, and the source is included. See `PORT-NOTE.md` for the derivation.
Terminal UI notices are in `NOTICES-NEWTERM.md`.
