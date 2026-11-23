# TermX

TermX is a Linux terminal for iPhone. It runs a Debian system on the phone, with a shell, `apt`, and a persistent disk.

## What you get

- Debian trixie (arm64) with `apt`
- Python, Node.js, git, and whatever you `apt install`
- A persistent disk, so installs survive reboots
- 2 GiB RAM, 32 GiB disk
- A terminal with a key row, paste, long-press paste, and separate arrow keys

## How it works

The Linux kernel is mainline 6.18, running as a User-mode Linux guest through the [Kernarium](https://github.com/imxieyi/Kernarium) runtime. The guest is a Debian image with systemd, booted from a read-only system image with a persistent data disk on top. The UI is a native iOS terminal.

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

GPL-2.0. See `LICENSE-GPL-2.0`. The Kernarium runtime is GPL-2.0-or-later. Terminal UI notices are in `NOTICES-NEWTERM.md`.
