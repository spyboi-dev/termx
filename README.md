# TermX

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE-GPL-2.0)

A Linux terminal for iPhone. It runs Debian on Kernarium's native Linux kernel (mainline 6.18).

## Features

- **Debian trixie (arm64) with `apt`**: systemd as init, standard Debian repos, persistent data disk.
- **Docker runs**: `sudo docker run --rm hello-world` pulls the arm64 image and prints "Hello from Docker!".
- **Native Ghostty terminal**: Built on `libghostty` with incremental rendering, Alt/Ctrl keys, pinch to zoom, tap-URL, haptics.
- **Localhost proxy**: Ports the guest listens on are forwarded to the phone's `127.0.0.1` automatically.
- **Built-in JIT**: Enables native JIT for the guest in-app via StikJIT, no separate helper app needed. On iOS 27 it pairs on the phone itself.

## Requirements

- iPhone or iPad, iOS 27 or later
- A sideloading setup (SideStore, AltStore, or LiveContainer) with a developer certificate

## Installation

1. Download the latest IPA from [Releases](https://github.com/spyboi-dev/termx/releases). There is no stable release yet.
2. Sideload it with SideStore, AltStore, or LiveContainer.
3. Open TermX. Tap Install to download the Debian image, then the shell starts on its own.

## Getting started

```sh
fastfetch
sudo apt update
sudo apt install python3 git
```

`~/.local/bin` is on PATH, and plain `pip3 install` works once Python is installed.

## Run in the background

To keep the guest running in the background using low-precision location (which does not actually activate your GPS or drain your battery), turn on **Keep running in background** in About. This needs Location Always.

## Build from source

See [BUILD.md](BUILD.md) for the full guide. The short version: the runtime framework `KRuntime_6_18_4K` must be built on a Mac first (upstream Kernarium only builds on Apple hosts); copy it into `Frameworks/`, then run `./build.sh` in `termx/`. That produces `build/TermX.ipa`, an ad-hoc signed IPA. Your installer re-signs the bundle at install time.

## License

GPL-2.0-or-later (`LICENSE-GPL-2.0`). TermX derives from
[imxieyi/Kernarium](https://github.com/imxieyi/Kernarium) (GPL-2.0).
Embedding the GPL runtime makes TermX a GPL-2.0-or-later derivative, and the source is included. See `PORT-NOTE.md` for the derivation.
Terminal UI notices are in `NOTICES-NEWTERM.md`.
