# TermX — Build an IPA from scratch

This is the guide. `BUILD-NOTE.md` is the chronological diary of how
we got here; read it for history, not for instructions.

## What you need

| Piece | Where it comes from |
|---|---|
| A Linux host | Any Debian/Ubuntu machine or VM. The build runs on Linux. |
| `clang-18`, `ld64.lld-18`, `zip` | `apt` (see below) |
| iOS SDK `iPhoneOS26.5.sdk` | The sibling `spytube-ios` checkout, at `~/workspace/spytube-ios/sdks/iPhoneOS26.5.sdk`. It is **not** in this repo. |
| `KRuntime_6_18_4K.framework` | The CI workflow (primary) or a manual Mac build (fallback). See below. |
| `git`, `gh` | `apt` / GitHub CLI, for the commit marker and releases. |

## 1. The runtime framework

The Linux runtime framework cannot be built on Linux: upstream
Kernarium's CMake refuses non-Apple hosts, and the build needs Xcode,
the Metal toolchain, Swift/SPM, and codesigning. The app `dlopen()`s
it at Start, so the framework is a build input, not something this
repo compiles.

**Primary route — CI.** `.github/workflows/build-framework.yml`
builds it on an `xcode-27` runner from the pinned Kernarium commit
(`fbe12ee`). Run the workflow manually from the Actions tab (or push
a change to the workflow file), download the `KRuntime_6_18_4K`
artifact, and copy the framework into `termx/Frameworks/`:

```sh
cp -r KRuntime_6_18_4K.framework termx/Frameworks/
```

The framework's provenance (upstream commit, runtime API version,
SHA-256) is recorded in `termx/Frameworks/README.md`. If the hash
there does not match the file you copied, the framework was rebuilt
from a different upstream commit or CI run — update the README and
check the runtime still boots before shipping.

**Fallback — manual Mac build.** On a Mac with Xcode, CMake 3.27+,
Ninja, Meson, and Python 3.11+:

```sh
git clone https://github.com/imxieyi/Kernarium
cd Kernarium
Kernarium/scripts/package-ios-frameworks.sh --sdk device
# output in .build/kernarium-xcframeworks/
```

Copy the device-slice `KRuntime_6_18_4K.framework` into
`termx/Frameworks/` as above. The three GPU frameworks
(`KosmicKrisp`, `MesaEGL`, `MesaGallium`) are already in
`termx/Frameworks/` (extracted from Andarium's release IPA); you do
not need to rebuild them.

## 2. Toolchain and SDKs

```sh
sudo apt-get update -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20
sudo apt-get install -y clang-18 lld-18 zip git
```

The iOS SDK lives in the sibling `spytube-ios` checkout:

```sh
ls ~/workspace/spytube-ios/sdks/iPhoneOS26.5.sdk
```

If it is not there, get it from that checkout — this repo does not
carry the SDK, and `build.sh` fails its preflight without it.

**VM restarts wipe the apt tools.** `clang-18` and `ld64.lld-18`
live in `/usr/bin`, not the workspace, so a restart removes them.
The SDKs and the framework survive (they are under `~/workspace`).
If a build fails with `command not found`, re-run the `apt-get
install` above; `build.sh` also names the restore command in its
preflight error.

## 3. Build

```sh
cd termx
./build.sh
```

What it does:

1. Preflight: `clang-18`, `ld64.lld-18`, `zip`, the SDK, and the
   runtime framework must exist, or it stops with a named error.
2. Compiles the ObjC sources and `vt.c` with `clang-18` against the
   iOS 26.5 SDK, and links with `ld64.lld-18` (adhoc codesign).
   The build marker (`-DTERMX_BUILD_COMMIT`) is the short git hash
   of the source, and the framework SHA-256 is baked in the same
   way, so the About screen and any device log identify the build.
3. Assembles the bundle (Info.plist, icons, all four frameworks)
   and zips `build/TermX.ipa`.
4. Post-build verification: the binary must be arm64, the bundle id
   must be `app.termx.ios`, the version must come from Info.plist,
   the build marker must be present in the binary, and the runtime
   framework must be embedded. Any failure exits non-zero with a
   named cause instead of shipping an IPA that looks fine.

## 4. Verify the IPA

```sh
mkdir -p ~/workspace/verify && cd ~/workspace/verify
unzip -q ~/workspace/kernarium-termux/termx/build/TermX.ipa
file Payload/TermX.app/TermX
# Mach-O 64-bit executable arm64
python3 -c "import plistlib; p=plistlib.load(open('Payload/TermX.app/Info.plist','rb')); print(p['CFBundleIdentifier'], p['CFBundleShortVersionString'], p['CFBundleVersion'])"
# app.termx.ios 0.3.0 3
strings -a Payload/TermX.app/TermX | grep -i termx | head
```

Never unzip under `/tmp`: it is a 512 MB tmpfs and a large unzip
stalls on a disk-full prompt. Use a directory under `~/workspace`.

## 5. Ship it

```sh
cp termx/build/TermX.ipa ~/workspace/your_files/TermX-<short-hash>.ipa
gh release create termx-<short-hash> ~/workspace/your_files/TermX-<short-hash>.ipa \
  --title "TermX <short-hash>" --notes "<what changed>"
```

The release tag is `termx-<short-hash>`; the IPA is attached to it.
There is no formal stable release — every build is a per-commit
development release, and the changelog entry goes in `CHANGELOG.md`.

## 6. The guest image

The app downloads the Debian image from a GitHub release; it is not
in the IPA. The current image is pinned by URL + two SHA-256s in
`termx/src/GuestInstall.m` (`kRootfsURL`, `kRootfsGzSHA256`,
`kRootfsSHA256`). To ship a new image:

```sh
cd rootfs-build
./rebuild-image.sh fix7
```

That runs the whole loop — patch, drift check, `mke2fs`, `e2fsck`,
`gzip`, hashes, `SHA256SUMS-slim`, publish the release, and update
the app constants — and refuses to proceed if the live tree has
drifted from `configure-rootfs-slim.sh`. See the script header and
`rootfs-build/README.md` for the details. A full from-scratch image
build is `build-rootfs-slim.sh` (debootstrap under qemu; slow and
fragile behind the VM egress proxy, retried in-script).

## Architecture decisions (the short version)

- The guest **suspends** when the app backgrounds; it does not run
  in the background. Audio/location/fetch modes would violate
  Apple's rules if used to keep a Linux guest alive.
- The terminal is **48 columns**, fixed. There is no winsize
  channel from the app to the guest, and the app never types a
  command into the terminal at boot, so nothing can re-run `stty`
  when the size changes. Fixing it needs a runtime winsize channel.
- The app runs **no command at boot**: boot is a local clear plus a
  bare newline, nothing typed into the terminal.

The longer versions live in `PORT-NOTE.md`, the code comments in
`termx/src/KernEngine.m` and `termx/src/TerminalViewController.m`,
and `~/workspace/termx-production-plan.md`.
