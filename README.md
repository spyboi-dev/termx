# TermX

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE-GPL-2.0)

A Linux terminal for iPhone. Debian on Kernarium's native Linux kernel (mainline 6.18).

## Features

- **Debian trixie (arm64)**: `apt`, systemd, persistent data disk.
- **Docker**: `sudo docker run --rm hello-world` works.
- **Ghostty terminal**: Built on `libghostty`.
- **Localhost proxy**: Guest ports forward to the phone's `127.0.0.1`.
- **Built-in JIT**: StikJIT in-app. Pairs on the phone on iOS 27.

## Requirements

- iPhone or iPad, iOS 27 or later
- SideStore, AltStore, or LiveContainer with a developer certificate

## Installation

1. Download the latest IPA from [Releases](https://github.com/spyboi-dev/termx/releases).
2. Sideload it.
3. Open TermX. Tap Install to download the Debian image.

## Getting started

```sh
fastfetch
sudo apt update
sudo apt install python3 git
```

`~/.local/bin` is on PATH.

## Run in the background

Turn on **Keep running in background** in About. It uses low-precision location and needs Location Always.

## Build from source

See [BUILD.md](BUILD.md). The runtime framework `KRuntime_6_18_4K` must be built on a Mac first. Copy it into `Frameworks/`, then run `./build.sh` in `termx/`.

## License

GPL-2.0-or-later (`LICENSE-GPL-2.0`). TermX derives from
[imxieyi/Kernarium](https://github.com/imxieyi/Kernarium) (GPL-2.0). See `PORT-NOTE.md`.
