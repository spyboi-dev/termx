# TermX

A real Linux shell on iOS: a Debian guest running on the Kernarium
User-mode Linux kernel, in an Objective-C UIKit app with NewTerm's
terminal UI. No JIT, no StikDebug, no Android guest.

- **Guest:** Debian trixie arm64, boots straight to a shell as user
  `termux` (passwordless sudo). Python 3, Node.js, Docker, git and
  build tools are baked in; standard Debian repos are enabled, so
  `apt install` works. Guest image:
  [termx-debian-trixie-arm64.ext4.gz](https://github.com/spyboi-dev/termx/releases/download/rootfs-20261120/termx-debian-trixie-arm64.ext4.gz)
  (368 MB, SHA-256 `7bc05dcf82a48d7b1f04413c2d3a8c3cafa5ea4450cc2284b82725e7aba79676`).
- **Engine:** Kernarium's real mainline Linux 6.18 kernel running
  natively on iOS (User-mode Linux), userspace emulated with the
  iSH-style interpreter ("gadget" engine). No JIT anywhere.
- **UI:** NewTerm's terminal UI, adapted to the guest console.

## License

GPL-2.0-or-later (`LICENSE-GPL-2.0`). TermX derives from
[imxieyi/Kernarium](https://github.com/imxieyi/Kernarium) (GPL-2.0)
and uses [hbang/NewTerm](https://github.com/hbang/NewTerm) UI code;
see `termx/NOTICES-NEWTERM.md`. Embedding the GPL runtime makes
TermX a GPL-2.0-or-later derivative: source travels with it.
See `PORT-NOTE.md` for the full derivation story.

## Layout

- `termx/` — the app: `src/` (Objective-C sources), `build.sh`,
  `Frameworks/` (GPU frameworks vendored from Andarium's release
  IPA; the Linux runtime framework is built by CI, see below),
  `attic-android/` (the superseded Android-guest code, reference only).
- `rootfs-build/` — scripts that built the Debian guest image.
- `BUILD-NOTE.md` — file map, hashes, verification, on-device steps.
- `PORT-NOTE.md` — architecture, the runtime and why its Linux
  framework is not built on Linux, known limits.

## Building

### 1. The Linux runtime framework (Mac, via GitHub Actions)

`KRuntime_6_18_4K.framework` cannot be built on Linux: upstream's
CMake refuses non-Apple hosts. `.github/workflows/build-framework.yml`
builds it on a `macos-26` runner from the pinned Kernarium commit
(full `prepare.sh` + GPU prefix + kernel bundle + runtime-tree CMake
build — the same steps as upstream, no shortcuts) and uploads the
device-slice framework as an artifact. Run it from the Actions tab
(`workflow_dispatch`), download the `KRuntime_6_18_4K` artifact, and
copy the framework into `termx/Frameworks/`.

### 2. The app (Linux VM, SPYTube workflow)

```sh
cd termx
./build.sh   # clang-18 + iPhoneOS26.5.sdk + ld64.lld-18, adhoc codesign
# produces build/TermX.ipa
```

### 3. On the phone (iPhone, iOS 27, untested)

Install the IPA via SideStore with a development profile (the runtime
needs the Increased Memory Limit + Extended Virtual Addressing
entitlements), tap Install (~368 MB guest download), tap Boot, log in
as `termux` (autologin on the console).

## Honest limits

- Docker is config-plausible (namespaces, cgroups, overlayfs present
  in the kernel config) but has never run in this runtime.
- The guest overlay is recreated each boot, so `apt` installs in a
  session do not persist; only what is baked into the image survives.
- Nothing here has run on a device yet.
