# TermX — a Linux terminal on iOS, on the Kernarium runtime

## What this is

TermX is a new Objective-C UIKit app that boots a minimal Debian
(trixie) rootfs inside the Kernarium runtime on an iPhone and opens
straight into a shell prompt. The shell has real Debian packages
(`apt`/`dpkg`, plus python3, git, curl, vim, nodejs, build tools
and docker.io baked into the image — see "Docker and the kernel
config" for what Docker can and cannot do here).
There is no Android guest, no ADB, no Termux APK: the guest is Linux,
the terminal is the whole app.

**Name collision, recorded honestly:** "TermX" is already the name
of an existing open-source SSH client. The user was told and chose
the name anyway. The bundle id `app.termx.ios` is distinct, so there
is no install-time conflict on iOS, but the name collides in search
results and in any App Store listing; that is a known, accepted
collision, not an oversight.

**Rename history:** KTerm (2026-11-20, Android guest) → X-Shell
(2026-11-20, Linux guest) → TermX (2026-11-20, same Linux guest,
new name). Display name "TermX", bundle id `app.termx.ios`, IPA
`TermX.ipa`.

It derives from [imxieyi/Kernarium](https://github.com/imxieyi/Kernarium)
under GPL-2.0-or-later (see `LICENSE-GPL-2.0` in `termx/`, and the SPDX
headers kept on every file taken from upstream). Embedding the GPL
runtime makes TermX a GPL-2.0-or-later derivative: its source must
travel with it. The terminal UI is modelled on
[hbang/NewTerm](https://github.com/hbang/NewTerm) (Apache-2.0; license
in `termx/NOTICES-NEWTERM.md`) — adapted into Objective-C, not copied:
NewTerm is Swift/SwiftUI with the external SwiftTerm VT emulator, and
this VM has no Swift toolchain. Our VT emulation is our own `vt.c`,
our UI is UIKit, and NewTerm's local-shell spawning is deliberately
not reproduced — the shell lives in the guest, never on iOS.

## Why Android is gone

KTerm (the previous build) booted LineageOS 24 (~994 MiB) and installed
the Termux APK into it over ADB. That was a workaround for literal
Termux: Termux is an Android app, and an Android guest was the only
way to run the literal app. On 2026-11-20 the user corrected the
design — "why we need android os we just need a shell terminal that
can run linux tools like termux or real deb pkg apt" — and he is right.
The goal was always a shell with real packages; Android added a
~1 GiB guest, an ADB client and an APK install for nothing the shell
needs. The Linux runtime framework is the correct flavour for the job,
and it boots a Linux guest straight to a shell.

This is not literal Termux any more: Termux's `pkg` is an Android-only
wrapper around its own Bionic packages, and it cannot exist without
Android. What the user named as the alternative — real Debian `apt` —
is what TermX is: a real Linux userspace, a real kernel, real deb
packages, in a terminal.

## The runtime, and why its Linux framework is not built here

Kernarium runs a real mainline Linux 6.18 kernel natively on iOS
through User-mode Linux: the kernel is compiled to native arm64 and
linked into an iOS framework, while userspace is emulated with an
iSH-style threaded interpreter (the "gadget" engine). There is also a
JIT engine, but TermX runs on gadgets, so no JIT, no StikDebug and
no debugger are needed at any point.

There are two runtime frameworks: `KRuntime_6_18_4K` (Linux) and
`KRuntime_Android_6_18_4K` (Android). The Kernarium app embeds both
and loads exactly one per process lifetime. The Linux framework is
**not obtainable on this Linux VM**, and that is proven, not assumed:

- `CMakeLists.txt:46-48`: `if(NOT APPLE) message(FATAL_ERROR "The UML
  Apple emulator requires an Apple SDK")` — CMake refuses to configure.
- `cmake/toolchains/Apple.cmake` shells out to `xcrun` for the SDK on
  every configure; the build needs Xcode, the Metal toolchain, Swift/SPM
  and codesigning. None of that exists on Linux.
- No `*.framework` exists anywhere in the repo clone, and Kernarium's
  releases carry only the Andarium IPA, the Android kernel bundle and
  the LineageOS system image — no prebuilt Linux framework.
- The Andarium IPA contains only the Android framework plus the three
  GPU frameworks (verified by listing it).

So the final IPA cannot be linked on this VM. The Linux framework must
be built on a Mac first (see BUILD-NOTE.md), then copied into
`termx/Frameworks/`; `build.sh` refuses to link without it. Do not
fake it with a stub framework.

One more Mac-build trap, learned 2026-11-20 from the OpenCode
Kernarium rebuild (same upstream): `package-ios-frameworks.sh` only
verifies prebuilt artifacts — on a fresh clone it fails because the
upstream build phase never ran (their run 44667335172 died in 27 s
at "Package iOS frameworks", the apple-gpu-vulkan-experiment prefix
never built). The Mac build must run the upstream build steps first
(`prepare.sh`, the full GPU prefix build, the runtime-tree CMake
build producing `KRuntime_6_18_4K`) and only then package the
frameworks.

The Android framework cannot boot a Linux guest either — proven from
source (`Kernarium/Runtime/KernariumRuntime.mm`): the run
implementation is compile-time branched
(`#if KERNARIUM_RUNTIME_ANDROID_GUEST`); the Android flavour requires
`android_data_disk_path` + `android_release_path` and returns
`-UML_EMULATOR_INVALID_ARGUMENT` ("incomplete Android bundle")
otherwise, with no Linux rootfs path handling. The App Store Android
runtime's `send_console_input` also answers `-ENOTSUP`, so even a
booted Linux guest could not receive keystrokes through it. The old
Android code (GuestViewController, AdbClient, AdbKey, targz, and the
Android framework) is kept for reference in `termx/attic-android/`.

## The Linux boot contract (from upstream source)

- Boot request supplies `rootfs_path` + `overlay_path`; the runtime
  embeds the base initramfs (`uml-boot-base-aarch64.cpio.gz`,
  release starter-20260928-boot-base-r1, 1,398,138 bytes, SHA-256
  `5ee756a9a42f8ad6765d5950234357e9e10089be81205160cd41f3f44da7cf01`)
  plus a per-run segment (`/init`, `/boot.env`).
- `/boot.env` is fixed by the runtime: `UML_BOOT_ROOT=/dev/ubda`,
  `UML_BOOT_ROOT_TYPE=erofs|ext4`, `UML_BOOT_UPPER=ext4`,
  `UML_BOOT_UPPER_DEVICE=/dev/ubdb`, `UML_BOOT_ENTRY=/sbin/init`.
- Rootfs image may be erofs or ext4; if named `*.ext4` it must carry
  NO write permission bits (`immutableExt4Rootfs` — chmod 444).
- The overlay is a sparse file the app creates (TermX: 4 GiB,
  recreated each boot) that `/init` formats fresh on ubd1 at every
  boot — **a Linux guest's writes do not persist across boots; apt
  installs live for one session only. Bake the tools into the image.**
- Entry is always `/sbin/init` (systemd); the image's default target
  controls the boot — set to `multi-user.target` in the image (no
  runtime knob).
- Kernel cmdline includes `console=tty0` and `console=ttyS0`, so
  systemd's getty generator spawns `serial-getty@ttyS0`
  automatically; the runtime mirrors ttyS0 to the host via
  `set_console_output_callback` / `send_console_input` (present in the
  release Linux runtime). That serial console is the terminal's I/O.
- Linux guests have no `boot_completed=1` signal — "up" is detected
  by the `login: ` prompt on the console; `/init` prints
  `UML_BOOT_SWITCH_ROOT:/sbin/init` on success and
  `UML_BOOT_ERROR:<reason>` on failure.
- `run()` requires a non-null `MTKView` (it returns an error on a
  null view) — TermX keeps a full-screen MTKView behind the terminal
  and passes it. The terminal view is opaque, so the guest
  framebuffer is never seen: the console is the interface.
- The app-facing API is `KernariumRuntime.h` (API version 43, entry
  `kernarium_runtime_get_api_v28()`); the low-level API is
  `darwin/api/include/uml/emulator.h`.

## The guest image

Upstream's Linux rootfs images are unsuitable: the accepted KDE
desktop image is 3.8 GiB of graphical desktop, and the Phrog and
postmarketOS images are graphical or user-supplied. None is a minimal
terminal image. So the image is built here:

- `debootstrap --foreign --arch=arm64 --variant=minbase trixie`,
  second stage under qemu-aarch64-static, then configured in chroot:
  systemd, `multi-user.target`, `serial-getty@ttyS0` with autologin
  as user `termux` + passwordless sudo, systemd-networkd DHCP on
  eth0, hostname `termx`, `TERM=xterm-256color` in the getty
  drop-in `Environment=` and in `/home/termux/.bashrc`, and
  apt/python3 (+pip)/git/curl/vim/nodejs/build-essential/docker.io
  baked in (full list in BUILD-NOTE.md).
- Packed with `mke2fs -t ext4 -d <dir>`, `e2fsck` + `debugfs`
  checks, chmod 444, gzip -9 + SHA-256.
- Name: `termx-debian-trixie-arm64.ext4` (`.ext4.gz` for download).
  The app downloads it into `Documents/guest/`, verifies the archive
  SHA-256 and the extracted image SHA-256, and skips the download if
  the image is already in place with the right hash (so it can also be
  dropped in via Files).
- Build environment notes (observed 2026-11-20): the VM is x86_64;
  `binfmt_misc` does not persist between exec calls, so the build
  script mounts/registers it inside the same invocation, writing the
  registration verbatim from `/usr/lib/binfmt.d/qemu-aarch64.conf`
  (expanding the `\x..` escapes first writes a malformed handler
  whose mask matches every ELF and breaks host execution); `chown`
  does not work under `~/workspace` (overlay `nouserxattr`), so the
  build runs in `/opt/termx-rootfs-build/` (ephemeral — the finished
  image + SHA256SUMS are copied into `vendor/` promptly; the scripts
  are kept in `rootfs-build/` so a rebuild is one command).
- The image URL is `https://github.com/spyboi-dev/termx/releases/
  download/rootfs-20261120/termx-debian-trixie-arm64.ext4.gz` — the
  release does not exist yet; publishing it is a pending step. The
  image itself is finished (built 2026-11-20): 1,648 MiB ext4
  (1,728,053,248 bytes, SHA-256
  `a11e2dd31cce3ab20630b48ff288586b9cc6691a7cf1992ff7d0193b00ba2f14`),
  gzip -9 archive 385,788,644 bytes (SHA-256
  `7bc05dcf82a48d7b1f04413c2d3a8c3cafa5ea4450cc2284b82725e7aba79676`),
  both in `vendor/` with `SHA256SUMS`; `e2fsck` clean and the
  contents verified via debugfs (see BUILD-NOTE.md). The hashes
  are filled into `GuestInstall.m`.

## Docker and the kernel config

Upstream's README claims the runtime can run "advanced workloads
including Docker containers". That claim is **unproven on a device**:
no guest has run dockerd in this runtime yet, and TermX has never
booted anywhere. What is proven is the kernel configuration: the
config below was extracted from the shipped Android kernel
(`IKCONFIG` in the `__TEXT,__uml_elf` section of
`KRuntime_Android_6_18_4K`, Linux/um 6.18.60, 94,975 bytes). The
Linux kernel TermX boots is built from the same shared fragment
(`kernel/common/config/darwin-uml.fragment`) plus the Linux overlay
(`kernel/mainline-6.18/config/mainline.fragment`) instead of the
Android overlay, so the table maps the Android values through those
overlay deltas; symbols set by neither overlay resolve to their
Kconfig default under `olddefconfig`.

Present in the Linux kernel — everything standard standalone
containers need:

- Namespaces: `NAMESPACES`, `USER_NS`, `PID_NS`, `NET_NS`, `IPC_NS`,
  `UTS_NS`, `TIME_NS` (all `y`).
- Cgroups: `CGROUPS`, `CGROUP_SCHED`, `FAIR_GROUP_SCHED`,
  `CFS_BANDWIDTH`, `MEMCG`, `BLK_CGROUP`, `CGROUP_PIDS`,
  `CGROUP_FREEZER`, `CGROUP_DEVICE`, `CGROUP_CPUACCT`,
  `CGROUP_PERF`, `CGROUP_MISC`, `CGROUP_BPF`, `CGROUP_NET_PRIO`,
  `CGROUP_NET_CLASSID`, `CPUSETS` (all `y`).
- Storage: `OVERLAY_FS`, `EXT4_FS_POSIX_ACL`,
  `EXT4_FS_SECURITY`, `BLK_DEV_LOOP`, `BLK_DEV_DM`,
  `DM_THIN_PROVISIONING`, `FUSE_FS` (all `y`); `XFS_FS` and
  `BTRFS_FS` are `y` in the Linux overlay.
- Networking: `VETH`, `BRIDGE`, `BRIDGE_NETFILTER`, `MACVLAN`,
  `DUMMY`, `TUN`, `IPV6`, `IP_MULTICAST` (all `y`).
- Netfilter/NAT: `NF_CONNTRACK`, `NF_NAT`, `NF_TABLES`,
  `NFT_CT/NAT/MASQ/COMPAT`, `NETFILTER_XTABLES`,
  `XT_MATCH_ADDRTYPE/CONNTRACK/STATE`, `XT_TARGET_MASQUERADE`,
  `IP_NF_IPTABLES/FILTER/NAT`, `IP_NF_TARGET_MASQUERADE/NETMAP`,
  `IP6_NF_IPTABLES/FILTER` (all `y`); `IP6_NF_NAT` is `y` in the
  Linux overlay. The base fragment's own comment says this path is
  there for Docker: "Docker's default bridge needs built-in
  connection tracking, NAT, bridge filtering, and the xtables
  compatibility expressions used by iptables-nft."
- Security: `SECCOMP` and `SECCOMP_FILTER` are `y` in the Linux
  kernel via the Kconfig default (`default y` in `arch/Kconfig`
  since commit 282a181b1a0d, and `HAVE_ARCH_SECCOMP=y` /
  `HAVE_ARCH_SECCOMP_FILTER=y` in the extracted config); the
  Android overlay pins them explicitly and
  `android-required-builtins.txt` requires them. Also `KEYS`,
  `POSIX_MQUEUE`, `BPF_SYSCALL` (`y`). `CHECKPOINT_RESTORE` is `y`
  in the Linux overlay (docker checkpoint/CRIU).

Missing or degraded in the Linux kernel — none of it blocks a
plain `docker run`:

- `IP_VS` (`n`) and `VXLAN` (`n`): Docker Swarm's ingress/routing
  mesh and swarm overlay networks are unavailable. Standalone
  containers on the default bridge are unaffected.
- `IPVLAN` (`n`): the docker ipvlan network driver is unavailable
  (the macvlan driver works: `MACVLAN=y`). `MACVTAP` (`n`) and
  `VLAN_8021Q` (`n`): macvtap setups and 802.1Q VLAN tagging are
  unavailable.
- `RT_GROUP_SCHED` (`n`): `--cpu-rt-runtime` is unavailable.
  `BLK_DEV_THROTTLING` (`n`): blkio throttling is unavailable
  (`--blkio-weight` works: `BLK_CGROUP=y`).
  `CGROUP_HUGETLB`: absent (hugetlbfs is off), so hugetlb limits
  are unavailable.
- `IP_NF_TARGET_REDIRECT`: `y` in Android, not set by any Linux
  fragment (Kconfig default `n`). Standard port publishing does
  not need it (it uses DNAT + MASQUERADE + docker-proxy).
- `IP6_NF_TARGET_MASQUERADE` / `IP6_NF_TARGET_REDIRECT`: likely
  `n` in the Linux kernel (hidden behind `IP6_NF_NAT=n` in
  Android; visible once the Linux overlay sets `IP6_NF_NAT=y`,
  with a Kconfig default of `n`). Docker with `--ipv6` would lack
  ip6tables MASQUERADE, so IPv6 NAT is degraded. Docker's default
  is IPv4-only.
- `CGROUP_NS`: not in the shipped config (Kconfig default);
  Docker works with or without it.

**Would a Mac-built kernel fix the missing pieces?** Rebuilding
the same fragments changes nothing — the shipped kernel is already
built from them. A missing symbol needs a change to the shared
config fragment (upstream treats every kernel configuration change
as shared across all maintained kernel lines, so it lands in the
base fragment or an overlay with a recorded reason) **and** a
rebuilt, accepted kernel artifact (upstream's release rules: an
embedded artifact's inputs reach users only through a rebuilt and
accepted artifact). So yes, fixable that way — but it is a config
change plus a rebuild, not a rebuild alone.

Guest caveats beyond the kernel: the guest has 1024 MiB of RAM,
so containers are tight (hello-world and alpine are fine; large
images will OOM). dockerd, containerd and runc all run in the
emulated userspace, so they will be slow. And the overlay is
stateless: `docker.io` is pre-installed in the image so it survives
reboots, but images pulled with `docker pull` live in the overlay
and vanish on reboot.

## The terminal UI (NewTerm model)

- 80 columns x 25 rows, term `xterm-256color`, scrollback 100 lines,
  system monospace font, black background `#000000`, text `#f2f2f2`,
  cursor `#f2f2f2` (drawn as a reversed block cell), line-based
  scrolling, auto-scroll to bottom.
- Keyboard toolbar above the software keyboard:
  - Primary row: Ctrl (toggle), Esc, Tab, More (toggle), then the
    butterfly arrows (left, up/down stacked, right), plus a keyboard
    dismiss key.
  - Secondary row (shown when More is on): Home, End, PgUp, PgDn,
    Del, Fn (toggle).
  - Fn row (shown when Fn is on): F1–F12, horizontally scrollable.
  - Keys play an input click; toggles highlight when active.
- Key bytes (NewTerm's `TerminalConstants`, exact): Esc `\x1b`, Tab
  `\t`, up `\x1b[A`, down `\x1b[B`, left `\x1b[D`, right `\x1b[C`,
  home `\x1b[H`, end `\x1b[F`, PgUp `\x1b[5~`, PgDn `\x1b[6~`, Del
  `\x1b[3~`, F1–F12 = `\x1bOP`, `\x1bOQ`, `\x1bOR`, `\x1bOS`,
  `\x1b[15~`, `\x1b[17~`, `\x1b[18~`, `\x1b[19~`, `\x1b[20~`,
  `\x1b[21~`, `\x1b[23~`, `\x1b[24~`; backspace `\x7f`, return `\r`.
  Ctrl is a latch applied to the next typed key (letter → control
  byte), then released.
- Guest output feeds the terminal through the console callback; the
  screen is re-rendered at most every 60 ms (the guest sends a few
  bytes at a time and redrawing on every one would thrash).
- `vt.c` is our own VT parser (adapted from the CrateTerm one):
  SGR colours (0 reset, 1/22 bold, 30–37/40–47 fg/bg, 90–97/100–107
  bright, 38;5;n/48;5;n 256-colour, 39/49 default), erase leaves the
  current background behind (back colour erase), blank cells default
  to fg/bg -1, scrollback stays plain text. Bold in colours 0–7
  renders as the bright variant at render time, as xterm does.
- Known gaps in the terminal: no long-press key repeat, no pinch
  font resize, scrollback keeps no colours, no split panes.

## What changed vs KTerm

- `kterm/` → `termx/`; display name "TermX", bundle id
  `app.termx.ios`, IPA `TermX.ipa`, entitlements
  `TermX.entitlements`, notification names `TermXEnterBackground` /
  `TermXEnterForeground`.
- Android guest + ADB + Termux APK removed from the app:
  `GuestViewController`, `AdbClient`, `AdbKey`, `targz` and the
  Android runtime framework moved to `termx/attic-android/`
  (reference only).
- `KernEngine` rewritten for the Linux boot: states
  Idle/Downloading/Ready/Booting/Running/Stopped/Failed; guest
  1024 MiB RAM, 2 vCPUs, 4 GiB sparse overlay in the temp dir
  recreated each boot; boot request with `rootfs_path` /
  `overlay_path`, `use_jit=0`; console callback watches for
  `UML_BOOT_ERROR:` (→ Failed) and `login: ` (→ Running).
- `GuestInstall` rewritten for the Debian image: streaming gunzip
  via zlib, SHA-256 of the archive and of the extracted image,
  chmod 0444, skip-if-present.
- `TerminalViewController` (new) replaces `GuestViewController` as
  the root screen: status bar (Install/Boot/Stop), the terminal,
  the hidden MTKView, the hidden keyboard field, the NewTerm
  toolbar rows.
- `vt.c`/`vt.h`: 25 rows (was 24), per-cell fg/bg/bold, SGR colour
  handling, erase-with-current-bg, per-cell blanking.
- `AppDelegate` roots to `TerminalViewController`.
- Guest image: LineageOS 24 tarball + Termux APK are gone from the
  app's install flow (the vendor copies remain in `vendor/` as the
  record of the KTerm build). The Debian rootfs is built here; see
  BUILD-NOTE.md for its hashes once the build finishes.
- `Frameworks/`: the three GPU frameworks stay; the Linux runtime
  framework is missing (see above) — `build.sh` fails at its
  preflight until a Mac-built copy lands here.

## Verdict

Not literal Termux — a real Debian shell with apt/dpkg, which is
what the user asked for once the Android detour was questioned.
What is NOT proven here is our own reassembly: the Linux framework
has never been linked into this app (it does not exist on this VM),
the Debian image has never booted in the runtime, and nothing has
run on a device. Until the Mac framework build and the phone test
pass, the honest label is "Debian shell on the Kernarium runtime,
unproven in our own app".

## Known limits

- The IPA cannot be linked on this VM — the Linux runtime framework
  must be built on a Mac first. This is the blocker, not a detail.
- The release IPA must be sideloaded with the Increased Memory Limit
  and Extended Virtual Addressing entitlements; an adhoc signature
  cannot grant them, and a free developer profile may not carry them
  either. Without them the guest still boots, but under the
  process's normal memory ceiling — hence the 1024 MiB guest.
- Guest writes do not survive a reboot (the overlay is formatted
  fresh every boot). Apt installs live for one session; bake tools
  into the image instead.
- The runtime's GPU budget check (`plan_gpu_budget`) can warn that
  the process is short of headroom; the app boots anyway and says so.
- One guest, one shell. No desktop UI, no file browser, no
  statistics — terminal-first by design.
- GPL-2.0-or-later: TermX embeds the GPL runtime, so its source
  must travel with any distribution of the IPA. The terminal UI model
  is Apache-2.0 (NewTerm); the combined licensing is recorded
  honestly in `NOTICES-NEWTERM.md` and `LICENSE-GPL-2.0`.
