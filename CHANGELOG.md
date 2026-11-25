# TermX changelog

Releases are per-commit builds: the version changes at a milestone,
and the build commit in About is the exact identity of any build.
Before 0.2.0 the version was never bumped, so the early history is
grouped under 0.1.0 by date and commit.

## 0.3.0 — 2026-11-24 — Phase 5: architecture and code quality

### UI bug-fix round 2: renderer, startup, and design tokens

Three fresh audits of the 083c97a build found real bugs in the
incremental renderer, the startup flow, and the Log screen, plus
a design pass over the startup screen, key rows, and theme.
All fixed here; nothing in this section changes the guest image,
the state machine, or the clear-on-boot gating.

Slop removal (at the user's direction, 2026-11-25): the
device-info note is gone from the About screen, the README, and
BUILD.md, and the About header no longer claims the screen says
anything about backgrounding. It never comes back.

- A clear plus heavy output in one 60 ms burst defeated the
  incremental renderer's clear detection: the dispatcher only
  noticed a clear when the scrollback count shrank, and a burst
  could push the count back above the rendered count, leaving
  pre-clear lines on screen and dropping the first post-clear
  lines. A monotonic clear-generation counter in `vt_t`,
  bumped on every clear, now forces a full rebuild.
- Pinch and double-tap zoom stalled when the terminal was idle
  with the keyboard dismissed: the flush early-return never
  checked `_fullRebuildNeeded`. It does now, so a zoom
  re-renders even with no new output.
- Two pinches with no flush between them lost the first zoom
  ratio (`_rebuildOffsetScale` was overwritten, not composed).
  Ratios now multiply.
- The guest-dead notice said "swipe down to return", but the
  exit gesture required being at the top of the scrollback —
  exactly where the user is not when the guest dies. The exit
  gesture now works from any scroll position while the notice
  is visible. The pill also has real padding now and is opaque,
  and its detail allows three lines instead of truncating.
- "Copied" feedback is no longer cut short by a second tap
  (generation counter on both the terminal and Log Copy
  buttons) and is announced to VoiceOver.
- `resetCursorBlink` now restarts the blink timer phase, so
  the cursor stays visible for a full cycle after input
  instead of hiding again almost immediately.
- The secondary and Fn key rows now use the same FillEqually
  layout and 3 pt spacing as the primary row, so all three
  rows align.
- The download rate never showed on any download after the
  first: the rate baseline was never reset, so after one
  install it sat at ~121 MB and the strict `>` never fired
  again. The baseline now resets on the transition into
  Downloading.
- The terminal never auto-presented if About was open when the
  shell came up: `terminalPresented` was set before the 0.7 s
  block bailed, and nothing re-armed it. A non-Log modal now
  re-arms the flag, with a guard so a manual Terminal tap in
  the meantime cannot double-present.
- An invisible 5 s auto-retry raced the user's Erase tap: if
  the retry fired while the Erase confirmation was open, the
  confirmed erase was refused. Tapping Erase now cancels the
  pending retry.
- One non-UTF-8 byte in the guest console made the whole guest
  section vanish from the Log screen (strict UTF-8 read
  returned nil). The log now decodes lossily, replacing bad
  bytes instead of dropping the section.
- "Start anyway" was missing when the crash choice showed
  alongside an update: the buttons were Update and Start fresh
  with no way to boot the old image as-is. The crash choice
  now takes priority — the action button is "Start anyway",
  Start fresh stays second, and Update remains available
  afterwards.
- Row detail strings are capped at 100 chars with the detail
  label limited to two lines, so the corrupt-disk message no
  longer overflows the fixed 68 pt row.
- The kernel row showed the fallback "2 GiB RAM" before the
  first boot; guest RAM is now computed at engine init, so the
  pending detail shows the real value (~5 GiB on a 15 Plus).
- The Log cap rewrite is atomic now (temp file + rename), so a
  refresh can never catch an empty file — and the crash
  logger reopens its fd after a cap, so crash lines written
  after a cap still land in the visible engine.log.
- Design: the primary action button is teal with white text
  while Log and About stay quiet; the Erase button has a 44 pt
  hit area; disabled buttons dim (teal at 0.35 alpha, never
  grey); the startup info line and About secondary text are
  white 0.6 instead of 0.45; the 120 pt spacer is 48 pt so the
  startup screen fits without scrolling on a 15 Plus; the Log
  screen lost its duplicate in-page header and fills the height
  on iPad; row titles, status, and timer are all 16 pt.
- Theme tokens: the grey scale, corner radii, and the 48 pt /
  68 pt heights are named in TXTheme and used everywhere, with
  the near-duplicates consolidated (log background 0.12 → card
  0.11, progress track 0.20 → button 0.22).

### Immersive keyboard-style key row

The key rows now match the iOS keyboard they sit above: 42 pt
tall keys at 6 pt spacing, on a solid black toolbar instead of
the SystemChromeMaterial blur, so the whole screen reads as one
black surface. Arrow glyphs, the paste icon, and the
hide-keyboard glyph are 18 pt to fill the taller keys.

### Mockup key design and Font Awesome clipboard

The keys now follow the user's mockup: a darker fill (white
0.22, down from 0.30), a thin light border around each key
(white 0.25 alpha) so the key reads against the black toolbar,
a 9 pt corner radius, and white sans-serif labels instead of
monospaced. The Paste button uses the Font Awesome solid
clipboard icon (FAClipboard PNGs, rendered from the Font Awesome
Free 6.7.2 clipboard SVG, CC BY 4.0), not the SF Symbol
doc.on.clipboard. The icon's holes are transparent, so the key's
grey shows through them.

### Native localhost: guest 127.0.0.1 reachable from the iPhone

A service on guest localhost was not reachable from the iPhone:
the guest sits behind slirp NAT, outbound only, and the runtime's
public API has no port-forward call, so a pairing URL like
http://127.0.0.1:3773 opened in Safari went nowhere. The runtime
does expose a vsock stream to the guest, so TermX now proxies
localhost over vsock: the app listens on the iPhone's 127.0.0.1
for each configured port and forwards each connection to the
guest bridge, which forwards it to guest 127.0.0.1. A guest
localhost service answers at the iPhone's localhost, the way it
would on a native OS — for any port, any tool, any agent.

- Guest bridge `tx-vsock-bridge` (static aarch64, rootfs-build):
  listens on vsock 5999, reads the target TCP port from the first
  two bytes of each stream, connects to guest 127.0.0.1, and
  shuttles both ways with clean half-close handling. Runs as a
  systemd service from boot (image fix7). Verified end to end on
  the VM (TCP test variant): byte-exact at 1 MB, clean EOF on a
  refused port, five concurrent connections.
- App proxy `TXLocalhostProxy`: listeners on 127.0.0.1, vsock
  connect with a retry for the bridge's boot race, clean close
  (drain, so a refused connection is an EOF, not a reset). Runs
  only while the guest is up, so a stopped guest reads as a clean
  refused connection in Safari.
- About screen gains a Localhost card: the forwarded ports, with
  add and remove. Defaults are 3000, 3773, 4096, 5000, 8000, 8080,
  8888; changes take effect at once while the guest is up.
- Guest image fix7 (rootfs-20261125-slim-fix7) carries the bridge
  and its service; the motd notes the new behaviour. Phones on
  fix6 are offered fix7 as an Update.
- Auto-mirror (image fix8): the configured list is now only the
  manual override. The proxy polls the bridge once a second for
  the guest's listening TCP ports (a port-0 control request; the
  bridge scans LISTEN sockets with sock_diag, falling back to
  /proc/net/tcp when the kernel lacks the TCP diag handler) and
  forwards those too, so any tool or agent that starts listening
  in the guest is reachable at the same 127.0.0.1 port on the
  iPhone within about a second, with no configuration. When a
  service stops, its port is dropped again. The bridge also falls
  back to the slirp guest IP 10.0.2.15 when forwarding, so a
  service bound to that address only still answers. About shows
  auto-detected ports as read-only Auto rows, refreshed live.
  Verified on the VM (TCP test variant): the scan finds
  127.0.0.1 and 0.0.0.0 listeners, the forward still works, and a
  refused port still closes cleanly.

### UI bug-fix round: leaks, stale flags, and polish

Three fresh audits of the 81d40f4 build found one real leak, one
out-of-bounds read, and a long tail of smaller bugs. All fixed
here; nothing in this section changes the guest image, the
state machine, or the clear-on-boot gating.

- The terminal view controller leaked on every presentation:
  the 60 ms flush timer's block and the Fn-row and `addKey:`
  `UIAction` blocks all captured `self` strongly, so `dealloc`
  (which invalidates the timers and frees the VT) never ran.
  Every open leaked a VC, its ~2 MB scrollback, and a timer
  that kept firing forever. All three now use `weakSelf`, the
  pattern the blink and arrow-repeat timers already used, and
  `dealloc` logs so the fix is visible in engine.log.
- A line exactly 80 columns full with the cursor past the last
  column (`cx == 80`, deferred wrap) extended the rendered row
  to 81 cells and read `cells[80]` — the next row's first cell
  for rows 0–23, past the grid into adjacent struct fields for
  row 24, rendered inverted as a garbage cursor cell. The cursor
  is now clamped to column 79 when rendering, and `appendCellRow`
  clamps its count to `VT_COLS` as well. vt.c's deferred wrap is
  untouched.
- The stale `presentAfterLogCloses` flag could yank the user
  into a cleared terminal: the 0.7 s auto-present block set it
  whenever *any* screen was presented, and About never consumed
  it. It is now set only when the Log screen is presented, the
  delayed block re-checks that the guest is still Running or
  Suspended, and the flag is cleared on any manual terminal
  presentation, on About Done, and on swipe-dismiss (iPad).
- If the guest fails or stops while the terminal is open, a
  label now says so over the terminal ("Guest failed/stopped —
  swipe down to return", plus the short status text). The
  terminal is never auto-dismissed and nothing is sent to the
  guest.
- Erasing the data disk no longer fails silently: a failure
  shows an alert ("Couldn't erase the data disk") instead of
  only a log line, in both the Erase button and the Start fresh
  path. Erase is disabled when no data disk exists.
- A corrupt data disk no longer dead-ends on Install: when the
  failed step is Storage and a disk exists, the action button
  reads "Erase data disk and start fresh" and runs the erase
  confirmation flow. After a successful erase it goes back to
  Install. Other failure steps are unchanged.
- Tapping Copy could swallow a pending screen update:
  `vt_render` cleared the dirty flag as a side effect although
  it is only a transcript builder. Only the flush clears dirty
  now. Copy also trims the up-to-24 trailing blank lines from
  the transcript, shows "Copied" for 1.5 s (the Log screen's
  pattern), and its VoiceOver hint says it copies the transcript
  instead of claiming it sends a key.
- Selecting text while output streams no longer fights the
  flush: the rebuild is skipped while a selection is active or
  the edit menu is open, and the dirty flag stays set so the
  next tick renders the output.
- Pinch zoom (and double-tap reset) preserves the scroll
  position when scrolled up: the saved offset is scaled by the
  font-size ratio. Pinned-to-bottom still goes through
  scroll-to-bottom.
- The progress bar no longer lies on failure: the Failed case
  returned the stale download fraction (1.0 after an install),
  so a failed first boot showed a full bar under a "Failed"
  header. It now returns 0 — the boot-phase mapping cannot
  rescue it, because every failure path overwrites the phase
  before setting the state.
- The Log screen no longer re-reads up to 1 MB on the main
  thread every second: reads run on a serial background queue,
  and the text view is rebuilt only when length plus hash show
  the content changed. Scroll preservation is unchanged.
- Download detail wraps to two lines instead of truncating the
  transfer rate on a 430 pt screen, and a stalled download
  drops the rate to 0 after a second with no new bytes instead
  of showing a stale MB/s forever.
- The header says "Not installed" (grey) when nothing is
  installed instead of "Ready". The elapsed timer resets when a
  boot or install starts instead of showing the app's lifetime.
  Storage reads "X used of Y" in both branches. The pending
  image detail reads "116 MiB", not "116 MB". The failure reason
  is capped at 200 chars like the crash notice. The crash notice
  is plain words now — the raw kernel panic line stays in the
  log only. The update row and About name the installed release
  alongside the update when its tag is known; an older image's
  tag is not pinned anywhere, so it reads "older release"
  rather than guessing.
- Smaller terminal fixes: double-tap reset uses
  `TXConfigTermFontSizeDefault` instead of a literal 14; the
  `NSDataDetector` for tap-URL is cached instead of rebuilt per
  tap; the cursor blink restarts visible on input (typed keys,
  backspace, paste, key buttons); the four-letter key labels fit
  down to a 320 pt screen (2 pt insets, 0.6 minimum scale); the
  toggle ON colour is the teal accent, not blue; the keyboard
  animation uses the keyboard's own curve; the exit pan is one
  finger only, so a pinch cannot dismiss the terminal.
- Checklist rows now tell VoiceOver their state ("System image,
  done" / "Linux kernel, in progress" / "Storage, failed").

Left undone, deliberately: the hardcoded kernel version
("6.18.60") and upstream commit ("fbe12ee") stay — the runtime
header exposes no kernel version, the framework Info.plist
carries only "6.18" and the ABI version, and no binary symbol
reports the commit, so there is no real source to read them
from. Dynamic Type on the startup, About, and Log screens
needs a layout rework (fixed 68 pt rows, fixed spacer) and was
not half-done. The clear-on-boot gate's residual timing hole
(silence is not proof the prompt is coming) is unconfirmed in
practice and the gating logic is untouched. The vt.c OOM path
and DECSTBM items from the audits were unconfirmed and are
untouched.

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
