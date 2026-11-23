# TermX

<img src="icon.png" width="128" alt="TermX icon">

A real Linux terminal for iPhone. No jailbreak, no server. A Debian system runs on your phone, and you get a shell.

## What it is

TermX runs a real Debian Linux guest on iOS. The guest is a full system: `apt`, Python, Node.js, git, and anything else you install. It is not a remote shell and not an emulator front end. The Linux kernel runs on the phone itself.

## What you get

- Debian trixie (arm64) with `apt`
- Python, Node.js, git, and whatever you `apt install`
- A persistent disk, so installs survive reboots
- 2 GiB RAM, 32 GiB disk
- A terminal with a key row, paste, long-press paste, and separate arrow keys

## How it works

The Linux kernel is mainline 6.18, running as a User-mode Linux guest through the [Kernarium](https://github.com/imxieyi/Kernarium) runtime. The guest is a Debian image with systemd, booted from a read-only system image with a persistent data disk on top. The UI is a native iOS terminal, modeled on NewTerm.

## Status

In development. Not stable yet, and there is no release. Expect rough edges.

## Install

Sideload the IPA with SideStore, AltStore, or LiveContainer. You need a developer certificate or a sideloading setup. iOS 27 or later.

No release is published yet. Builds are shared as development IPAs while the app is stabilizing.

## Build

The app is built on Linux with clang-18 and ld64.lld-18 against the iOS 26.5 SDK. The runtime framework is not built here: upstream Kernarium refuses non-Apple hosts, so the Linux framework `KRuntime_6_18_4K` has to be built on a Mac first.

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
