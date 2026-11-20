# TermX — BUILD-NOTE

TermX is a Linux terminal on iOS on the Kernarium runtime: it boots a
minimal Debian (trixie) rootfs straight to a shell prompt in a
NewTerm-modelled terminal view — no Android guest, no ADB, no Termux
APK. See PORT-NOTE.md for the architecture and why Android is gone.

## The IPA — NOT BUILT

- **Path:** `termx/build/TermX.ipa` — does not exist.
- **`termx/build.sh` exits 1 at its preflight**, verbatim:

```
ERROR: Frameworks/KRuntime_6_18_4K.framework is missing.
The Linux runtime framework is not in any Kernarium release and
cannot be built on this Linux VM (upstream CMake refuses
non-Apple hosts). Build it on a Mac:
  git clone https://github.com/imxieyi/Kernarium
  cd Kernarium
  Kernarium/scripts/package-ios-frameworks.sh --sdk device
then copy .build/kernarium-xcframeworks/.../KRuntime_6_18_4K.framework
into Frameworks/ here and re-run this script. See BUILD-NOTE.md.
```

The Linux runtime framework `KRuntime_6_18_4K.framework` is not in
any Kernarium release, is not in the Andarium IPA (that one carries
the Android flavour only), and cannot be built on this Linux VM —
upstream's CMake refuses non-Apple hosts (`CMakeLists.txt:46-48`,
FATAL_ERROR) and the build needs Xcode, the Metal toolchain,
Swift/SPM and codesigning. No IPA was fabricated; the build refuses
to link without the framework. A Mac build of the framework is the
blocker (see below).

- **Update 2026-11-20 (from the OpenCode Kernarium rebuild, same
  upstream):** the packaging script alone is not enough. Its Mac
  build run 44667335172 failed in 27 s at "Package iOS frameworks"
  because the workflow skipped Kernarium's upstream build phase —
  `package-ios-frameworks.sh` only verifies prebuilt artifacts, so
  the apple-gpu-vulkan-experiment prefix was never built. The Mac
  build must first run the upstream build steps (`prepare.sh`, the
  full GPU prefix build, the runtime-tree CMake build producing
  `KRuntime_6_18_4K`) and only then package the frameworks. The
  TermX framework build needs the same sequence; the bare
  `package-ios-frameworks.sh --sdk device` command above will fail
  the same way on a fresh clone.

## What was verified, and how

**App sources compile clean (2026-11-20, re-checked after the
TermX rename)**
- `clang-18 -target arm64-apple-ios27.0 -isysroot
  ~/workspace/spytube-ios/sdks/iPhoneOS26.5.sdk
  -miphoneos-version-min=27.0 -fobjc-arc -O2` compiled all six
  sources with zero warnings and zero errors: `main.m`,
  `AppDelegate.m`, `TerminalViewController.m`, `KernEngine.m`,
  `GuestInstall.m`, `vt.c`. (Objects in `/tmp/termx-compile/`;
  no link was attempted — the framework is missing.) The rename
  is therefore compile-verified, not just grep-verified.
- `termx/build.sh` was also re-run after the rename: exits 1 at
  the preflight with the missing-framework error, as expected.
- Re-checked 2026-11-20 after filling the rootfs hashes into
  `GuestInstall.m`: same result, zero warnings/errors (objects in
  `/tmp/termx-compile-check/`). `termx/build.sh` re-run the same
  day: still exits 1 at the preflight, as expected.

**VT parser host test (2026-11-20) — 9/9 pass**
- Host test `/tmp/vt_test2.c` against `termx/src/vt.c`:
  25 rows; SGR fg red (31) and reset; bold+green (1;32) stored as
  fg 2 + bold (brightening is render-time, as xterm does); 256-colour
  fg 200; erase keeps the current background (44 → bg 4); render
  contains the login prompt; 30 lines fed on a 25-row screen leaves
  line01 in the scrollback. All 9 assertions pass.

**Rootfs build (failed once on the proxy, resumed 2026-11-20 ~02:00 IST)**
- `debootstrap --foreign --arch=arm64 --variant=minbase trixie`
  first stage done; second stage done ("Base system installed
  successfully").
- The configure step's `apt-get install` then failed, exit 100:
  every one of the 112 package fetches failed with `Connection
  failed [IP: 198.18.3.1 3128]` — the VM's egress proxy refused
  deb.debian.org in a burst. The base system is intact (238–321 MiB
  tree in `/opt/termx-rootfs-build/rootfs/`); nothing was installed.
  The host proxy works again (direct curl to deb.debian.org
  returns 200), so this was transient, not a dead mirror.
- Fix applied: `configure-rootfs.sh` now retries `apt-get update`
  (up to 5 attempts) and `apt-get install` (up to 3 attempts), and
  a resume script `rootfs-build/resume-rootfs.sh` re-runs only the
  configure + image steps (first/second stages already done).
- The first resume (started 01:48 UTC / 07:18 IST) failed on its
  own retry check: the main trixie InRelease fetched fine on every
  attempt, but trixie-security and trixie-updates kept failing
  through the proxy, and the check treated any "Failed to fetch"
  as fatal — 5 attempts, exit 1. The check was too strict: every
  package installed here comes from main, so the check now retries
  only when the main trixie index itself fails (security/updates
  failures are warnings; the guest re-runs apt update on its own
  network later). Second resume launched 01:54 UTC / 07:24 IST.
- **VM restart wiped the build (2026-11-20 ~07:30 IST).** The
  second resume was killed by SIGTERM mid-attempt-4, and
  `/opt/termx-rootfs-build/` is gone entirely (build.log, rootfs
  tree, everything) — `/opt` is ephemeral across restarts, and
  `uptime` showed the VM 1 minute old. The restart also wiped
  apt-installed clang-18, ld64.lld-18 and qemu-user-static
  (debootstrap/mke2fs/e2fsck survive — they are base-image tools).
  What survived, in `~/workspace`: the rootfs scripts
  (`rootfs-build/`), all app sources, and the SDKs.
- Recovery: `/opt/termx-rootfs-build/` recreated from the
  workspace script copies. The pipeline script
  (`rootfs-build/pipeline.sh`) ran 02:17–02:37 UTC: the apt lock
  freed after 490 s; `apt-get update` fetched 35.6 MB fine; the
  toolchain needed nothing (`clang-18`, `lld-18`,
  `qemu-user-static` were already the newest versions — the other
  agent had installed them); TOOLCHAIN-EXIT=0. The full rootfs
  build then ran: debootstrap first stage and second stage both
  OK ("Base system installed successfully"), but the configure
  step's `apt-get update` failed 5/5 attempts again and the
  pipeline exited 1. The proxy backend changed after the restart
  (failures now cite 198.18.19.77:3128, previously 198.18.3.1),
  and host curl to deb.debian.org returns 200 at the same time —
  the proxy works from the host but the chroot apt under qemu
  cannot connect to it in bursts. Direct (no-proxy) internet is
  blocked from this VM (curl returns 000), so the proxy is the
  only route.
- Fix tried next: `configure-rootfs.sh` now serializes apt's
  fetches (`-o Acquire::Queue-Mode=access` on update and install).
  The third resume attempt failed the same way — serializing
  changed nothing, which proved the proxy was not a burst problem.
- **Root cause found (2026-11-20, resume 3 diagnosis):** the
  egress proxy hostname resolves to an IPv6 address that works
  (`fd8b:4f84:7d32:99::1`, curl through it: 200) and an IPv4 pool
  that is dead (curl through `198.18.19.77:3128`: 000, though the
  TCP port opens). Host tools resolve IPv6-first and succeed; apt
  inside the chroot under qemu picks IPv4 and fails. A `/etc/hosts`
  pin to the IPv6 address did NOT fix it (resume 4): apt's
  resolver path is IPv4-only and ignores an IPv6-only hosts entry
  — getent in the chroot returned only the IPv6, yet apt still
  connected to 198.18.19.77. The fix that works is giving apt the
  proxy as an IPv6 literal, which needs no resolution: tested
  directly in the chroot, `apt-get update` fetched all three
  indexes (7,186 kB in 11 s, exit 0). `resume-rootfs.sh` and
  `build-rootfs.sh` now resolve the proxy's IPv6 live on the host
  and export the proxy env vars with the IPv6 literal for the
  chroot invocation only; credentials stay in the environment and
  nothing proxy-related is written into the image. The `/etc/hosts`
  pin stays in `configure-rootfs.sh` for other tools, and never
  ships — the hostname section overwrites `/etc/hosts` with the
  clean guest entries.
- Resume 5 (proxy fixed) installed all 190 packages (199 MB:
  docker.io 26.1.5 + containerd + runc, nodejs 20.19.2, python3
  3.13.5 + pip, git 2.47.3, build-essential, systemd 257.13) then
  died at the networking step: `systemd-resolved.service does not
  exist` — `systemd-resolved` is a separate package in trixie, not
  part of base `systemd`. Fix: added it to the install list.
- Resume 6 installed `systemd-resolved`, then died at the versions
  check: `systemd: command not found` (no `/usr/bin/systemd` in
  Debian — the binary is `/usr/lib/systemd/systemd`) and `docker:
  command not found` — the `docker` CLI is in the separate
  `docker-cli` package, only a Recommends of `docker.io`, skipped
  by `--no-install-recommends`; `dockerd` itself was present at
  `/usr/sbin/dockerd`. Fix: added `docker-cli`, fixed the systemd
  version path.
- Resume 7 died in 123 ms: `cp: not writing through dangling
  symlink` on `/etc/resolv.conf` — systemd-resolved's postinst had
  converted it to a symlink to the stub resolver, which dangles
  while resolved is not running. Fix: `rm -f` the destination
  before copying (in both `resume-rootfs.sh` and
  `build-rootfs.sh`); the shipped image still ends up with the
  correct stub symlink, re-created by configure's networking
  section.
- Resume 8 finished configure (`CONFIGURE DONE`, versions all
  verified in the chroot) then the image build failed: `mke2fs:
  Could not allocate block` — `mke2fs` takes its size in 1K units,
  not 4K blocks, so 393,216 produced a 384 MiB filesystem for a
  1,173 MiB rootfs. Fix: `BLOCKS=$(( IMG_MB * 1024 ))`, headroom
  raised 30% → 40%.
- **Resume 9 finished the build (2026-11-20 03:30 UTC,
  RESUME9-EXIT=0).** Image `termx-debian-trixie-arm64.ext4`:
  1,648 MiB (1,728,053,248 bytes), ext4 label `termx-root`,
  chmod 444; gzip -9 archive 385,788,644 bytes (368M).
  SHA-256 image
  `a11e2dd31cce3ab20630b48ff288586b9cc6691a7cf1992ff7d0193b00ba2f14`,
  archive
  `7bc05dcf82a48d7b1f04413c2d3a8c3cafa5ea4450cc2284b82725e7aba79676`
  (in `vendor/SHA256SUMS`; `sha256sum -c` passes on the vendor
  copies). `e2fsck` clean (27,792/105,664 files, 325,300/421,888
  blocks). debugfs checks on the image: `default.target` →
  `multi-user.target`, `serial-getty@ttyS0` enabled with autologin
  drop-in (`TERM=xterm-256color`), user `termux` (uid 1000,
  `/bin/bash`, passwordless sudo), all three trixie repos in
  `sources.list`, `/etc/hosts` clean (no proxy pin),
  `/etc/resolv.conf` the resolved stub symlink, `docker` (29 MB)
  + `dockerd` (69 MB) + `node` + `git` + `curl` + `python3` +
  `gcc`/`g++` present, no qemu binary, `/etc/machine-id` empty,
  motd as written. The hashes are filled into `GuestInstall.m`
  (`kRootfsGzSHA256`, `kRootfsSHA256`, `kRootfsSize =
  1728053248`); the `.ext4`, `.ext4.gz` and `SHA256SUMS` are in
  `vendor/`. What is still missing is only the release publish
  (see below) and the Mac framework build.

**KTerm (the superseded Android build) — for the record**
- The previous build's IPA (21,618,414 bytes, SHA-256
  `507f5a722101f8c4ac8c0483af8d87fb0a16dd643dbe0fb2680d5635d0f79c39`)
  is preserved as `vendor/KTerm-20261120.ipa` (the `kterm/` dir was
  renamed to `termx/`, so the only copy had been the stale one in
  `termx/build/` — build.sh wipes that directory on a successful
  run, so the IPA was moved to `vendor/` first). It is superseded
  by this rework and is not the deliverable. Its vendor files
  (Andarium IPA, LineageOS tarball, Termux APK) remain in `vendor/`
  as the record of that build.

## File map

```
kernarium-termux/
  PORT-NOTE.md              architecture, Linux boot contract, verdict
  BUILD-NOTE.md             this file
  upstream/                 shallow clone of imxieyi/Kernarium @ fbe12ee
  upstream-newterm/         shallow clone of hbang/NewTerm (UI model + license)
  vendor/
    Andarium-1.0-15.ipa     release IPA (framework source, KTerm build)
    lineage24-...-r28.tar.gz
    com.termux_1022.apk     F-Droid Termux APK (KTerm build only)
    andarium-extract/       IPA contents: Frameworks + andarium-system
    termx-debian-trixie-arm64.ext4      1,648 MiB, SHA-256 a11e2dd3…
    termx-debian-trixie-arm64.ext4.gz   368M, SHA-256 7bc05dcf…
    SHA256SUMS              both hashes (sha256sum -c passes)
  rootfs-build/             build-rootfs.sh + configure-rootfs.sh
                            (durable copies; the live build runs in
                            /opt/termx-rootfs-build/, which is ephemeral)
  termx/
    LICENSE-GPL-2.0         GPL-2.0 text from upstream root
    NOTICES-NEWTERM.md      NewTerm license (Apache-2.0, with the
                            pre-a745b49f47 GPL note) copied from upstream
    build.sh                SPYTube-style build (see below)
    Frameworks/             the 3 GPU frameworks (KosmicKrisp, MesaEGL,
                            MesaGallium) + README.md;
                            KRuntime_6_18_4K.framework MISSING
    attic-android/          KTerm Android code + Android framework
                            (reference only: GuestViewController,
                            AdbClient, AdbKey, targz, KRuntime_Android)
    src/
      main.m                UIApplicationMain
      AppDelegate.h/.m      one window, TerminalViewController root;
                            TermXEnterBackground/Foreground notifications
      TerminalViewController.h/.m
                            the terminal screen: status bar (Install/Boot/
                            Stop), terminal UITextView (monospace 13pt,
                            black, xterm colours, block cursor), hidden
                            MTKView behind it, hidden keyboard field,
                            NewTerm toolbar rows (primary / secondary /
                            Fn), Ctrl latch, 60 ms flush timer
      KernEngine.h/.m       runtime wrapper: states Idle/Downloading/
                            Ready/Booting/Running/Stopped/Failed; boot
                            (1024 MiB, 2 vCPUs, 4 GiB sparse overlay
                            recreated each boot, use_jit=0); console
                            callback watches UML_BOOT_ERROR: and
                            login: ; GPU hold on background
      GuestInstall.h/.m     downloads termx-debian-trixie-arm64.ext4.gz,
                            SHA-256 of archive + extracted image,
                            streaming gunzip (zlib), chmod 0444,
                            skip-if-present. Hashes/size filled
                            2026-11-20 from the finished build
                            (archive 7bc05dcf…, image a11e2dd3…,
                            size 1728053248 bytes).
      KernariumRuntime.h    upstream header, copied verbatim (SPDX intact)
      vt.c/vt.h             own VT parser: 25 rows, per-cell fg/bg/bold,
                            SGR colours, erase-with-current-bg,
                            100-line plain scrollback
      Info.plist            bundle app.termx.ios, TermX 0.1.0 (1),
                            MinimumOSVersion 27.0, arm64 + metal
      TermX.entitlements  Increased Memory Limit + Extended Virtual
                            Addressing + get-task-allow (see limits)
      icons/                generic >_ icons (from CrateTerm)
    build/                  build outputs (wiped by build.sh; stale
                            KTerm IPA was inside before the rework)
```

## How the build works

`termx/build.sh`, modelled on `~/workspace/spytube-ios/native/build26.sh`:

- Preflight: refuses to run unless
  `Frameworks/KRuntime_6_18_4K.framework` exists (see the error
  above). No stub, no fake IPA.
- `clang-18 -target arm64-apple-ios27.0 -isysroot
  ~/workspace/spytube-ios/sdks/iPhoneOS26.5.sdk
  -miphoneos-version-min=27.0` compiles the 6 sources (5 .m + vt.c).
- `ld64.lld-18 -arch arm64 -platform_version ios 27.0 26.5
  -rpath @executable_path/Frameworks -adhoc_codesign` links them with
  `-framework KRuntime_6_18_4K -framework KosmicKrisp
  -framework MesaEGL -framework MesaGallium` (`-F Frameworks`) plus
  the system frameworks, `-lz -lobjc -lSystem`.
- The 4 frameworks are copied into `TermX.app/Frameworks/` (their
  `_CodeSignature` dirs stripped), Info.plist + icons + PkgInfo added,
  then zipped as `Payload/TermX.app` into `build/TermX.ipa`.

**Toolchain note:** clang-18/lld-18 were wiped by a VM restart (as
before). Reinstalling needed `apt-get update` first; the update was
slow (22 kB/s average for the lists) and the first attempt was killed
by a 150 s timeout — the retry with a 900 s timeout completed.
Final toolchain: Ubuntu clang 18.1.3, `ld64.lld-18`, both at
`/usr/bin/`.

## The guest image (Debian rootfs — building)

- Build: `debootstrap --foreign --arch=arm64 --variant=minbase
  trixie` + second stage under qemu-aarch64-static + configure in
  chroot (systemd, `multi-user.target`, `serial-getty@ttyS0`
  autologin as `termx` + passwordless sudo, systemd-networkd DHCP
  on eth0, hostname `termx`, `TERM=xterm-256color`), then
  `mke2fs -t ext4 -d <dir>`, chmod 444, gzip -9 + SHA-256.
- Packages baked into the image (so they survive the stateless
  overlay — anything installed later with apt lives for one boot
  only): apt/dpkg, ca-certificates, systemd, python3 + python3-pip,
  git, curl, wget, vim/nano/less, nodejs, build-essential (gcc,
  g++, make), docker.io + iptables, htop, openssh-client, sudo,
  iproute2, iputils-ping. Standard Debian repositories are enabled
  (`deb.debian.org/debian trixie main contrib non-free-firmware`,
  plus trixie-security and trixie-updates).
- **apt verification:** `apt-get update` and the full package
  install run inside the chroot during the build — the same apt
  against the same repositories — so a finished build proves apt
  works with the standard repos. Guest-side `apt update` on the
  phone (over the guest's slirp network) is still unproven until
  the device test.
- Exact install commands for things not pre-installed (run in the
  guest as `termux`, with `sudo`):
  - `sudo apt update && sudo apt install <package>` for anything
    in Debian trixie (python3, nodejs, git, curl, build-essential
    and docker.io are already in; reinstalling one is harmless).
  - Docker extras: `sudo apt install docker-buildx
    docker-compose-v2` (BuildKit and Compose; skipped from the
    image by `--no-install-recommends`).
  - Rootless Docker (advanced): `sudo apt install uidmap
    fuse-overlayfs slirp4netns dbus-user-session`, then follow
    Docker's rootless setup. Rootful Docker via `sudo docker`
    works without these.
- Docker kernel verdict: see PORT-NOTE.md ("Docker and the kernel
  config"). Short version: the Linux kernel has everything
  standard standalone containers need (namespaces, cgroup
  controllers, overlayfs, veth/bridge, netfilter/NAT, seccomp);
  Swarm (IPVS, VXLAN), the ipvlan driver, VLAN tagging, RT/blkio
  limits, hugetlb limits and IPv6 NAT are missing or degraded.
  Docker itself has never run in this runtime — the claim is
  config evidence plus upstream's README, not a device test. The
  evidence is the extracted Android-flavour kernel config
  (`kernel-config-android-6.18.60.txt`, 94,975 bytes, IKCONFIG
  from the `__TEXT,__uml_elf` section of the Android runtime
  framework); the Linux kernel differs only by the overlay deltas
  in `kernel/mainline-6.18/config/mainline.fragment` vs
  `android.fragment`.
- Driver: `rootfs-build/build-rootfs.sh` (runs in
  `/opt/termx-rootfs-build/` because `chown` does not work under
  `~/workspace`; the script mounts/registers binfmt_misc inside the
  same invocation, writing the registration verbatim from
  `/usr/lib/binfmt.d/qemu-aarch64.conf` — expanding the `\x..`
  escapes first writes a malformed handler that breaks host
  execution).
- Image name: `termx-debian-trixie-arm64.ext4`. Size: used + 30%
  headroom, min 1024 MiB, rounded to 16 MiB.
- Download URL (release does not exist yet — publishing is a
  pending step):
  `https://github.com/spyboi-dev/termx/releases/download/
  rootfs-20261120/termx-debian-trixie-arm64.ext4.gz`
- Hashes: **pending** — fill from `/opt/termx-rootfs-build/
  SHA256SUMS` when the build finishes, into `GuestInstall.m`
  (`kRootfsGzSHA256`, `kRootfsSHA256`, `kRootfsSize`), and copy the
  `.gz` + `SHA256SUMS` into `vendor/`.

## On-device steps (not yet tested — and not yet buildable)

1. Build the Linux runtime framework on a Mac (see below), copy
   `KRuntime_6_18_4K.framework` into `termx/Frameworks/`, run
   `termx/build.sh` — it should then produce `TermX.ipa`.
2. Sign TermX.ipa with a development profile and install with
   SideStore (or AltStore). Adhoc will not do: the app needs the
   Increased Memory Limit and Extended Virtual Addressing
   entitlements in `TermX.entitlements`, and a free developer
   profile may not carry them either. Without them the guest still
   boots, but under the process's normal memory ceiling — hence the
   1024 MiB guest.
3. Publish the rootfs release at the URL above (or drop the
   `.ext4` into `Documents/guest/` via Files — the app skips the
   download if the image is already there with the right hash).
4. Open TermX. Tap **Install**: downloads the Debian image
   (~1 GiB) from GitHub releases, verifies both SHA-256s.
5. Tap **Boot**: the guest boots (interpreter/gadget engine, no
   JIT, no StikDebug). Watch the status bar; the console callback
   flips the state to Running on the `login: ` prompt (autologin
   as `termux` follows). The terminal is the shell.
6. `apt update && apt install <package>` works for the session.
   Installs do not survive a reboot — the overlay is formatted
   fresh every boot, so bake tools into the image instead.

## Mac build (compile the Linux runtime framework from source)

This is the blocker, not an optional extra. On a Mac with Xcode
(Metal toolchain component installed), CMake 3.27+, Ninja, Meson,
Python 3.11+ and the dependencies from upstream
`dependencies/README.md`:

```
git clone https://github.com/imxieyi/Kernarium
cd Kernarium
Kernarium/scripts/package-ios-frameworks.sh --sdk device
# default --runtimes all: builds both KRuntime_6_18_4K and
# KRuntime_Android_6_18_4K; output in .build/kernarium-xcframeworks/
```

Copy the device-slice `KRuntime_6_18_4K.framework` into
`termx/Frameworks/` and re-run `termx/build.sh` here (or build
the whole app in Xcode). The public C API is
`darwin/api/include/uml/emulator.h`; the app-facing runtime header
is `Kernarium/Runtime/KernariumRuntime.h` (API version 43,
`kernarium_runtime_get_api_v28()`).

## Known limits / what remains

- **No IPA exists.** The Linux framework must be built on a Mac
  first; until then `build.sh` exits 1 at the preflight. The app
  sources compile clean and the VT parser passes its host test, but
  nothing has been linked and nothing has run on a device.
- **The Debian image is not finished.** The rootfs build is in the
  configure/apt-install step; when it finishes, fill the hashes in
  `GuestInstall.m`, copy the `.gz` + `SHA256SUMS` into `vendor/`,
  verify the image (`e2fsck -fn`, `debugfs`, chroot checks:
  `systemctl get-default` = multi-user.target,
  serial-getty@ttyS0 enabled, user `termux` exists, `apt-get
  update` works, python3/git present), re-run the compile check,
  and publish the release.
- The console I/O, the boot wiring and the image install flow are
  all new, untested code. The likeliest failure points on first
  run: the runtime failing to load (entitlements / memory ceiling),
  the Linux framework's console callback behaving differently from
  the Android preset, or the rootfs layout.
- Adhoc signature: SideStore with a development profile is required;
  a free profile may still lack the two memory entitlements.
- Guest writes do not survive a reboot (overlay formatted fresh
  every boot). One guest, one shell. No desktop UI, no file browser,
  no statistics — terminal-first by design.
- GPL-2.0-or-later: TermX embeds the GPL runtime, so its source
  must travel with any distribution of the IPA. Terminal UI model
  is Apache-2.0 (NewTerm); see `NOTICES-NEWTERM.md`.
