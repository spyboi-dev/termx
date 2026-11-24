# TermX changelog

Releases are per-commit builds: the version changes at a milestone,
and the build commit in About is the exact identity of any build.
Before 0.2.0 the version was never bumped, so the early history is
grouped under 0.1.0 by date and commit.

## 0.3.0 — 2026-11-24 — Phase 5: architecture and code quality

### Double prompt after boot, fixed for real

- The clear-on-boot no longer sends its newline unconditionally:
  it waits for a short quiet period (300 ms with no new console
  output, up to 2 s) and only then checks the VT — a prompt already
  on screen means no newline, and only a quiet, empty VT gets one
  newline to elicit a fresh prompt. The old unconditional newline
  sat in the tty input buffer when the guest's first bash prompt
  was still in flight (slow login, cold boot, first boot after an
  image update): the prompt arrived as prompt one, bash read the
  newline as an empty command and printed prompt two. A fixed
  delay would only have moved the race to a slower login.
  Verified with a host harness against vt.c: the old sequence
  reproduces exactly two prompts, the gated sequence exactly one
  in both the late-prompt and the wiped-prompt case.
- The replay can no longer feed a chunk twice: the terminal takes
  over live delivery and reads the buffered output in one atomic
  step (`beginConsoleDeliveryWithDelegate:`), so a chunk arriving
  between setting the delegate and reading the snapshot is neither
  duplicated nor missed.
- `vt_is_empty` (vt.c): 1 when the grid is all blank and the
  scrollback is empty — the gate's "has the guest printed yet"
  test.

### Key row: all eleven keys the same width

- Paste is a clipboard icon (SF Symbol `doc.on.clipboard`)
  instead of the word, and the hide-keyboard key lost its fixed
  44 pt width: with the primary row distributing equally, every
  key — ctrl, alt, esc, tab, more, paste, the four arrows,
  hide-keyboard — is ~35 pt on a 430 pt screen. The arrows were
  the smallest keys in the row (squeezed into the leftover width
  of a nested stack); they now take one equal share each. The
  four-letter labels shrink slightly to fit instead of clipping.
  Paste behaviour, the Paste VoiceOver label, and every other
  key are unchanged.

A refactoring release: no behaviour changes, only structure.

- One flow state: the startup screen's eight flow flags (one
  automatic boot, one automatic retry, terminal presented once,
  pending update, crash acknowledged) moved into a single
  `TXGuestFlow` object owned by the engine, with named transitions
  (`resetForInstall`, `resetRetry`, `acknowledgeCrash`). The flow
  *decisions* still live on the startup screen — moving them would
  re-time the whole flow, so that stays deferred and documented.
- One config: the tuning constants (flush interval, arrow repeat,
  paste/replay chunk, font clamp, pinch dead zone, row heights,
  exit-pan thresholds, pinned threshold, container width, line
  spacing, free-space thresholds, sampler intervals, console buffer)
  gathered into `TXConfig.h`; every literal use now names one.
  Values unchanged. The scrollback cap stays `VT_SCROLLBACK_MAX`
  in vt.h because that file is shared with CrateTerm.
- Debug logging toggle: `termx.debugLogging`, off by default,
  gates the verbose lines (memory sampler, session-record dumps).
  Normal logging is untouched. A switch in About turns it on for
  diagnosis without a rebuild.
- Versioning: the app is 0.3.0 (build 3); About shows it, and the
  build marker and the displayed version are the same thing.
  This changelog starts here.
- Git hygiene: `rootfs-build/build-rootfs-slim.sh` is tracked;
  the 53 MB runtime framework is ignored (its provenance — CI
  run, upstream commit, SHA-256 — is recorded in
  `termx/Frameworks/README.md`); the dead `attic-android` code
  and a stray crash log are out of the tree.
- Build script: a toolchain preflight (clear error naming the
  restore command when a VM restart wiped clang/lld) and
  post-build verification (arm64, bundle id, version, build
  marker present, framework embedded). `set -euo pipefail`.

### Phase 6: developer experience and docs (docs and tooling only — no app behaviour change)

- README updated to the fix6 image (150 MB, correct hashes) and
  to the current Limitations: fastfetch Unknown on a fresh install
  and why, fixed 48-col width with no winsize channel, guest
  pauses in background, standard memory limit.
- `BUILD.md`: a step-by-step guide to build an IPA from a fresh
  clone (SDKs, framework via the CI workflow, toolchain restore
  after a VM restart, build, verify). `BUILD-NOTE.md` is now
  marked as a diary, not a guide.
- `rootfs-build/rebuild-image.sh`: the image iteration loop in one
  command (patch → drift check → `mke2fs` → `e2fsck` → `gzip` →
  hashes → `SHA256SUMS-slim` → publish → update the app
  constants), with a `--dry-run` mode. It refuses to proceed on
  drift between the live tree and `configure-rootfs-slim.sh`.
- `rootfs-build/README.md` documents the image directory: which
  file is the source of truth, and the rule that tree and script
  must never drift.

## 0.2.0 — 2026-11-24 — Phase 4: first run and guest environment

- About screen: app version, build commit, installed image
  release, runtime API version, upstream commit, framework hash.
- Image fix6: fastfetch 2.40.4 installed by default, new motd,
  aliases (`ll`, `la`, `..`, `ff`); the app points at fix6 and
  offers it as an update to fix5 installs.
- Storage row shows "X used of Y" whenever the data disk exists,
  not only after a boot.
- Column width stays at a fixed 48: no clean orientation-aware
  solution exists without a runtime winsize channel, and the
  limit is now documented in the image config, the bashrc files,
  and the plan instead of silently shipped.

## 0.1.0 — 2026-11-22 to 2026-11-24 — the road to production

### Phase 3: lifecycle and background (f9c51ef)

- Background strategy documented in the app: the guest pauses
  when the app backgrounds and its disk is saved first; it does
  not run in the background.
- The session record drives recovery: after a guest panic or
  kernel abort the startup screen holds the auto-boot and shows
  a notice with Start anyway and Start fresh (erase the data
  disk, then boot).
- Data-disk integrity check at boot (ext4 magic; a corrupt disk
  fails on the Storage step with the erase remedy named).
- Force-quit mid-run is logged as "killed from outside".
- Entitlements removed: adhoc signing cannot grant them, so the
  file claimed a limit the IPA did not have; the guest runs
  under the standard per-process limit with a 1 GiB reserve.

### Phase 2: terminal quality (01c3da2)

- Incremental rendering: new scrollback lines appended, dropped
  front lines deleted, only the 25 grid rows re-rendered — the
  full rebuild every 60 ms is now only the first render, the
  font-change path, and a fallback.
- Alt key in the primary row next to Ctrl, latching, prefixes
  ESC to the next input.
- Cursor blinks (~530 ms) only while focused and the app is
  active.
- Scrollback keeps colour (cells stored per scrollback row,
  cap exactly 2000).
- Pinch zoom dead zone 0.1 pt, double-tap resets to 14 pt,
  line spacing scales with the font size.
- Light haptics on keys and toggles; BEL gives a medium haptic,
  no sound.
- Accessibility labels and hints on every key, the text view,
  and the toolbar; tap-URL (http/https) plus a Copy button for
  the whole transcript; one strict UTF-8 decoder.

### Phase 1: reliability and honesty (4b670d2)

- Atomic image swap (live to `.old`, `.new` to live, delete
  `.old`; the `.gz` is kept until the swap succeeds).
- Stopping (teal) and Suspended (orange) states in the engine
  and the startup screen; mid-boot background fails cleanly
  with a 5 s automatic retry on return.
- Per-boot diagnostic experiment removed; leaked block
  observer fixed; `_quiesced` reset on boot; Ctrl toggle-off
  colour fixed; stale jump-to-bottom comments removed.
- Memory sampler slows to one line every 5 s while the guest
  is up; download errors distinguish disk-full from network
  failure; the startup screen shows the installed image
  release tag.

### Earlier builds (2026-11-22 to 2026-11-24)

- First boot on device (ba05bc4); black-screen fix (44ce491);
  backspace fix (7f9038f); clear clears scrollback (badab5c);
  keyboard gap and ring buffer (9126067); UI and engine sweep
  with full guest RAM, storage picker, and app icon (0e08421).
- Second-launch crash fixed: the framework's `/init` ran
  `mkdir` without `-p` on a reused data disk (6ae75e2).
- Docker proven on device (`hello-world`).
- DNS fixed: image config files were built at mode 660 and
  broke networkd/DHCP; service-read config files are 644.
- Device detection saga: automatic detection added (d2835b8),
  fixed to read `hw.machine` (0caecfb), then removed entirely
  per the no-auto-run-commands direction (d1e4491) — fastfetch
  shows Unknown for Host/CPU/GPU on a fresh install.
- Pinch to zoom (7d64e03); arrows reordered to pairs, the
  jump-to-bottom button removed (5a68211); exactly one prompt
  after boot and keys matching the iOS keyboard (e53c27b).
- Slim images fix1–fix5: config files 644, `~/.local/bin` on
  PATH, pip `--user` works, hostname `iphone`, dynamic prompt,
  winsize at login, fastfetch device config.
