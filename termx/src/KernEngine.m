// SPDX-License-Identifier: GPL-2.0-or-later
#import "KernEngine.h"
#import "KernariumRuntime.h"
#import "GuestInstall.h"
#import "TXBootPathCheck.h"
#import "TXLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <limits.h>
#import <mach/mach.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>

NSString* const kTermXStateChanged = @"TermXStateChanged";

// Build marker: the short commit this IPA was built from, passed by
// build.sh as -DTERMX_BUILD_COMMIT="..."; logged at every launch so a
// device log always identifies its build (the 2bbe39f crash logs had
// no version marker, which cost a diagnosis cycle).
#ifndef TERMX_BUILD_COMMIT
#define TERMX_BUILD_COMMIT "nogit"
#endif

// The Linux guest: 2 vCPUs, and as much RAM as iOS gives the app
// minus a 1 GiB reserve for iOS and the app itself (see
// TXComputeGuestMemoryMiB). The iPhone 15 Plus has 6 GiB, so the
// guest gets 5 GiB there. 2048 is the default until the first boot
// computes it, and the floor: a smaller device never gets less.
// The value must satisfy the pre-flight (min 512, step 64), so the
// computation rounds down to a 64 MiB step. 512 MiB was the old
// fixed value, set when 1024 MiB was suspected of being killed by
// jetsam twice in a row (2026-11-22, build 2bbe39f); the later
// sampler proved those deaths were the /init mkdir panic, not
// jetsam, so the 512 MiB cut is no longer needed.
static uint32_t kGuestMemoryMiB = 2048;
static const uint32_t kGuestCPUs = 2;
// The guest's persistent data disk, in GiB: one sparse file at a fixed
// path (see dataDiskPath), created once and reused on every boot, so
// the size is capacity, not allocated size — the file only grows as
// the guest writes, like Andarium's "628 MiB of 8 GiB". The size a
// new disk gets comes from the user setting (+dataDiskGiB, default
// 2 GiB, stored in NSUserDefaults); an existing disk keeps whatever
// size it was created at until the user erases it (see
// createDataDiskIfNeeded).
static const uint64_t kDefaultDataDiskGiB = 2;

@interface KernEngine () {
    const kernarium_runtime_api* _api;
    void* _runtimeHandle; // dlopen handle; held for the process lifetime
    BOOL _running;
    // Held for the whole run: the boot struct hands the runtime C strings,
    // and they must stay alive until run() returns. All four are __strong
    // (verified: no weak/assign anywhere) — the paths are built once in
    // init, the session record once per boot in the pre-flight, and
    // nothing reassigns them while a run is in flight.
    __strong NSString* _sessionRecordPath;
    __strong NSString* _dataDiskPath;
    __strong NSString* _guestDir;
    __strong NSString* _rootfsPath;
    BOOL _dataDiskReady;
    // Footprint sampler (diagnostic): a GCD timer logging one memory
    // line every 100 ms until the guest is Running or the run ends.
    // Created in startMemorySampler, cancelled in stopMemorySampler;
    // nil when not running. Guarded by @synchronized(self).
    dispatch_source_t _samplerTimer;
    // Background quiesce (the reboot-crash fix, 2026-11-22): a serial
    // queue that orders the guest lifecycle calls (quiesce on
    // background, resume on foreground), so a fast background /
    // foreground cycle can never run a resume against a quiesce still
    // in flight. The runtime serialises lifecycle calls itself, but
    // the queue makes the app's own ordering explicit and keeps both
    // calls off the main thread — a quiesce can block ~20 s.
    dispatch_queue_t _lifecycleQueue;
    // YES once quiesce_resident has suspended the guest: the
    // foreground must call resume() before the guest can run again.
    // Only set when the settle report says the guest suspended.
    BOOL _quiesced;
    // Timing diagnostic (second-launch crash, 2026-11-22): YES while
    // the launch update check (full image hash, only when the
    // fingerprint cannot answer) is still running; its completion
    // only sets the flag when this is still set, so a user Install
    // tapped meanwhile owns the state instead.
    BOOL _launchUpdateCheckInFlight;
}
// Runs on _lifecycleQueue only: suspends the guest and settles its
// disk (see quiesceGuestForBackground).
- (void)quiesceGuestForBackground;
// Launch update check: settles whether the installed image is this
// build's release, on a background queue (see
// checkForImageUpdateForLaunch). It never blocks booting: the state
// is Ready from the cheap installed check, and this only sets
// updateAvailable.
- (void)checkForImageUpdateForLaunch;
// Readwrite here so the console callback and the boot/install paths
// (which run outside the @implementation) can move the phase.
@property (nonatomic, readwrite) TXBootPhase bootPhase;
@property (nonatomic, readwrite) NSInteger failedStep;
@property (nonatomic, readwrite) BOOL updateAvailable;
@property (nonatomic, readwrite) int64_t downloadReceived;
@property (nonatomic, readwrite) int64_t downloadExpected;
// Console output buffered since boot for the terminal's replay (see
// bufferedConsoleOutput). Appended on the runtime thread, read on
// the main thread, so every access is under @synchronized(self).
@property (nonatomic, strong) NSMutableData *consoleBuffer;
// Rolling tail for the console marker search (see ConsoleOutput):
// the last 64 bytes of the previous chunk, prepended to the current
// chunk for the marker search only. Written and read on the runtime
// thread, so every access is under @synchronized(self).
@property (nonatomic, strong) NSMutableData *consoleMarkerTail;
@end

// A/B revert (2026-11-22): the console ring buffer was compiled OUT
// while the second-launch crash was being chased. The crash turned
// out to be the /init mkdir bug (fixed in 6ae75e2), not this buffer,
// which was audited safe three times. Re-enabled 2026-11-23: with it
// off, bufferedConsoleOutput is always empty, so the terminal replay
// has nothing to show and the terminal opens on a bare placeholder
// instead of the boot log and the login prompt. Set this to 0 to turn
// the buffer off again; 1 keeps the most recent 128 KiB of console
// output for the replay.
#define TERMX_RING_BUFFER_AB 1

// The console replay buffer keeps the most recent output (the boot
// log and the login prompt are ~10-20 KiB); older bytes are dropped
// from the front, so the buffer never grows without bound.
static const NSUInteger kConsoleBufferMaxBytes = 128 * 1024;

static NSString* TXStateName(TermXState state) {
    switch (state) {
        case TermXStateIdle: return @"Idle";
        case TermXStateDownloading: return @"Downloading";
        case TermXStateReady: return @"Ready";
        case TermXStateBooting: return @"Booting";
        case TermXStateRunning: return @"Running";
        case TermXStateStopped: return @"Stopped";
        case TermXStateFailed: return @"Failed";
    }
}

static void ConsoleOutput(void* context, const void* buffer, size_t length) {
    KernEngine* engine = (__bridge KernEngine*)context;
    NSData* data = [NSData dataWithBytes:buffer length:length];
    // Every console byte also goes to Documents/Engine/guest.log.
    TXLogConsoleData(data);
#if TERMX_RING_BUFFER_AB
    // And into the in-memory replay buffer, so a terminal presented
    // later can still show the boot log and the login prompt.
    @synchronized (engine) {
        if (!engine.consoleBuffer) engine.consoleBuffer = [NSMutableData data];
        [engine.consoleBuffer appendData:data];
        if (engine.consoleBuffer.length > kConsoleBufferMaxBytes) {
            [engine.consoleBuffer replaceBytesInRange:NSMakeRange(0, engine.consoleBuffer.length - kConsoleBufferMaxBytes)
                                            withBytes:NULL length:0];
        }
    }
#endif
    id<KernEngineDelegate> delegate = engine.delegate;
    if (delegate) {
        // The callback runs on a runtime thread; the terminal view renders
        // from its own timer, so no main-queue hop is needed here.
        [delegate kernEngineDidReceiveConsoleOutput:data];
    }
    // Rolling tail for the marker search: the runtime delivers
    // console output a few bytes at a time, and a marker can straddle
    // two chunks ("login: " split as "log" + "in: "). Searching each
    // chunk alone misses it, so the app stays in Booting forever and
    // the terminal never presents. Keep the last 64 bytes of the
    // previous chunk and prepend them for the search only — the
    // delegate callback and the log above already got exactly this
    // chunk. 64 bytes is more than the longest marker (30 bytes), so
    // any straddled marker is whole in the joined text.
    NSData *joinedData = nil;
    @synchronized (engine) {
        if (engine.consoleMarkerTail.length) {
            NSMutableData *joined = [NSMutableData dataWithData:engine.consoleMarkerTail];
            [joined appendData:data];
            joinedData = joined;
        }
        NSUInteger tailLen = MIN((NSUInteger)64, data.length);
        engine.consoleMarkerTail = [[data subdataWithRange:NSMakeRange(data.length - tailLen, tailLen)] mutableCopy];
    }
    NSString* text = nil;
    if (joinedData) {
        text = [[NSString alloc] initWithBytes:joinedData.bytes length:joinedData.length encoding:NSUTF8StringEncoding];
    }
    if (!text) {
        // No tail, or the join split a multi-byte character: fall back
        // to this chunk alone (the old behaviour).
        text = [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
    }
    if (!text) return;
    if ([text containsString:@"UML_BOOT_ERROR:"]) {
        engine.failedStep = (engine.bootPhase == TXBootPhaseServices)
            ? TXBootStepStartup : TXBootStepKernel;
        engine.bootPhase = TXBootPhaseFailed;
        engine.state = TermXStateFailed;
        engine.statusText = [@"Guest boot failed: " stringByAppendingString:text];
        return;
    }
    if (engine.state == TermXStateBooting) {
        if ([text containsString:@"UML_BOOT_SWITCH_ROOT:/sbin/init"]) {
            // The kernel booted and init is running: systemd is now
            // starting services, and the login prompt comes next.
            engine.bootPhase = TXBootPhaseServices;
            engine.statusText = @"Starts services";
        }
        // The serial getty prints "kterm login: " once systemd is up.
        // That is the moment the shell is usable.
        if ([text containsString:@"login: "]) {
            engine.bootPhase = TXBootPhaseReady;
            engine.state = TermXStateRunning;
            engine.statusText = @"Debian shell — logged in as termx";
        }
    }
}

@implementation KernEngine

+ (instancetype)shared {
    static KernEngine* s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[KernEngine alloc] init]; });
    return s;
}

// Data disk size setting (NSUserDefaults "termx.dataDiskGiB", in
// GiB, default 2): the size a NEW data disk gets. The startup screen
// offers a picker that writes it through +setDataDiskGiB:. A stored
// 0 (never set, or explicitly cleared) means the default; a negative
// value is invalid and also means the default. An existing disk is
// never resized by this setting — it keeps its size until erased
// (see createDataDiskIfNeededWithError:).
+ (uint64_t)dataDiskGiB {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:@"termx.dataDiskGiB"];
    if (stored <= 0) return kDefaultDataDiskGiB;
    return (uint64_t)stored;
}

+ (void)setDataDiskGiB:(uint64_t)giB {
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)giB forKey:@"termx.dataDiskGiB"];
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = TermXStateIdle;
        _bootPhase = TXBootPhaseIdle;
        _failedStep = -1;
        _statusText = @"Not installed yet — tap Install";
        NSString* docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        // Canonicalize once, here: /var is a symlink to /private/var,
        // so the raw Documents path starts with /var/mobile/... while
        // the framework resolves /private/var/mobile/... . Every guest
        // path below is built from this one, so all of them are
        // canonical from the start. (Side effect, one time: the
        // install fingerprint is keyed by the exact path string, so
        // the first launch of this build does one full hash verify
        // and re-records the fingerprint under the canonical path.)
        _guestDir = TXCanonicalizePath([docs stringByAppendingPathComponent:@"guest"]);
        TXLogEngine(@"Guest dir: %@", _guestDir);
        _rootfsPath = [_guestDir stringByAppendingPathComponent:kRootfsName];
        // Fixed path in the data container, NOT the tmp directory: iOS
        // may purge tmp, and a persistent disk must survive. The file
        // is created once and reused on every boot (see
        // createDataDiskIfNeededWithError:).
        _dataDiskPath = [_guestDir stringByAppendingPathComponent:@"termx-data.ext4"];
        // The runtime framework is deliberately NOT loaded here: the
        // app binary carries no framework load commands, and the
        // framework (53 MB, kernel inside) is dlopen()ed on Start
        // instead, so launch stays light. See loadRuntimeWithError:.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(enterBackground)
                                                     name:@"TermXEnterBackground" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(enterForeground)
                                                     name:@"TermXEnterForeground" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(memoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        // Serial queue for the guest lifecycle calls (background
        // quiesce, foreground resume, terminate quiesce): the order
        // is the fix — a resume must wait for a quiesce in flight.
        _lifecycleQueue = dispatch_queue_create("app.termx.ios.lifecycle", DISPATCH_QUEUE_SERIAL);
        _quiesced = NO;
        // Refresh the state from disk on launch: an installed guest means Ready.
        // A version difference is an update, not a failure: the
        // installed image boots as-is, whatever release it is, so
        // Ready is declared at once from the cheap installed check
        // and the terminal is never blocked on the update check
        // below. TIMING DIAGNOSTIC (second-launch crash, 2026-11-22):
        // the launch still runs a full SHA-256 over the 1 GiB image
        // when the fingerprint cannot answer which release it is —
        // that re-warms the image in the page cache and makes the
        // second launch take seconds like the first — but it only
        // sets the update flag now; it can no longer fail the boot.
        // The 5 s pre-boot delay in the startup screen is the other
        // half of the diagnostic and is unchanged.
        BOOL installed = [self guestInstalled];
        if (installed) {
            _state = TermXStateReady;
            _statusText = @"Guest ready — starting the engine…";
            _launchUpdateCheckInFlight = YES;
            TXLogEngine(@"Launch: guest installed, ready to boot; checking for an image update in the background");
            TXLogFlush();
            [self checkForImageUpdateForLaunch];
        }
        // Build marker, every launch: the commit this IPA was built
        // from plus the guest RAM, so a device log always identifies
        // its build. Runs right after the "--- App launch ---" marker.
        TXLogEngine(@"TermX build %s · guest %u MiB RAM · %u vCPUs",
                    TERMX_BUILD_COMMIT, kGuestMemoryMiB, kGuestCPUs);
#if TERMX_RING_BUFFER_AB
        TXLogEngine(@"A/B: console ring buffer ON");
#else
        TXLogEngine(@"A/B: console ring buffer OFF (revert build)");
#endif
        TXLogEngine(@"TermX engine init: state %@, guest %@",
                    TXStateName(_state), installed ? @"installed" : @"not installed");
        // The runtime records how the last guest's session ended in
        // guest/session.json ("running" from boot on, then the end,
        // a kernel panic with its message). Read it before booting
        // again: after a failed run it says what the last one did.
        // Layout (uml-session 8, 19,200 bytes, upstream
        // darwin/runtime/session_record.hpp): memory slot 0..8192,
        // stall slot 8192..12288, network 12288..12800, storage
        // 12800..13056, camera 13056..14080, state 14080..19200.
        // The old code logged only the first 2000 characters, the
        // memory slot's head; the state (the end word) and the stall
        // slot (vCPU stalls, thermal / power / pressure transitions)
        // were never seen. Log the whole file, slot by slot, plus
        // one-line summaries, and flush it to disk: the next run may
        // kill the process, and this record is the runtime's own
        // witness of the previous death. What the end word means:
        // "running" = killed from outside with no further
        // instruction (SIGKILL); "host-fault" = host fault, signal
        // and registers in the message; "guest-panic" /
        // "kernel-abort" = the kernel crashed; "process-exit" = the
        // process exited while the guest ran; "failed" = run()
        // returned an error.
        NSString* sessionPath = [_guestDir stringByAppendingPathComponent:@"session.json"];
        NSData* recordData = [NSData dataWithContentsOfFile:sessionPath];
        NSString* record = nil;
        if (recordData.length) {
            record = [[NSString alloc] initWithData:recordData encoding:NSUTF8StringEncoding];
            if (!record) record = [[NSString alloc] initWithData:recordData encoding:NSISOLatin1StringEncoding];
        }
        if (record.length) {
            NSCharacterSet* pad = [NSCharacterSet whitespaceAndNewlineCharacterSet];
            NSString* firstLine = [[record componentsSeparatedByString:@"\n"] firstObject] ?: @"";
            TXLogEngine(@"Previous session record: %lu bytes, layout %@", (unsigned long)recordData.length, firstLine);
            // Slice a byte range of the record and trim its padding
            // (slots are padded with spaces or newlines to their
            // fixed size). Character offsets equal byte offsets:
            // the record is printable text.
            NSString* (^TXSessionSlice)(NSUInteger, NSUInteger) = ^NSString* (NSUInteger off, NSUInteger len) {
                if (off >= recordData.length) return @"";
                NSUInteger n = MIN(len, recordData.length - off);
                NSData* sub = [recordData subdataWithRange:NSMakeRange(off, n)];
                NSString* s = [[NSString alloc] initWithData:sub encoding:NSUTF8StringEncoding];
                if (!s) s = [[NSString alloc] initWithData:sub encoding:NSISOLatin1StringEncoding];
                if (!s) return @"";
                return [s stringByTrimmingCharactersInSet:pad];
            };
            // Slot offsets by layout version; the pinned framework
            // writes uml-session 8. An unrecognized layout logs the
            // whole trimmed file as one block instead of mis-slicing.
            NSUInteger layoutVersion = 0;
            if ([firstLine hasPrefix:@"uml-session "]) {
                layoutVersion = (NSUInteger)[[firstLine substringFromIndex:12] integerValue];
            }
            BOOL knownLayout = (layoutVersion >= 1 && layoutVersion <= 8);
            NSUInteger memoryBytes = 8192, stallOffset = 8192, networkOffset = 12288;
            NSUInteger storageOffset = 12800, cameraOffset = 13056, stateOffset = 14080;
            if (layoutVersion == 7) {
                stateOffset = 13056; cameraOffset = NSNotFound;
            } else if (layoutVersion == 6) {
                stateOffset = 12800; storageOffset = NSNotFound; cameraOffset = NSNotFound;
            } else if (layoutVersion == 5) {
                memoryBytes = 4096; stallOffset = 4096; networkOffset = 8192; stateOffset = 8704;
                storageOffset = NSNotFound; cameraOffset = NSNotFound;
            } else if (layoutVersion == 4) {
                stateOffset = 12288; networkOffset = NSNotFound; storageOffset = NSNotFound; cameraOffset = NSNotFound;
            } else if (layoutVersion >= 1 && layoutVersion <= 3) {
                stateOffset = 8192; stallOffset = NSNotFound; networkOffset = NSNotFound;
                storageOffset = NSNotFound; cameraOffset = NSNotFound;
            }
            if (!knownLayout) {
                TXLogEngine(@"Session record (unrecognized layout, whole file):\n%@", [record stringByTrimmingCharactersInSet:pad]);
            } else {
                NSString* memoryText = TXSessionSlice(0, memoryBytes);
                NSString* stallText = (stallOffset == NSNotFound) ? @"" : TXSessionSlice(stallOffset, 4096);
                NSString* networkText = (networkOffset == NSNotFound) ? @"" : TXSessionSlice(networkOffset, 512);
                NSString* storageText = (storageOffset == NSNotFound) ? @"" : TXSessionSlice(storageOffset, 256);
                NSString* cameraText = (cameraOffset == NSNotFound) ? @"" : TXSessionSlice(cameraOffset, 1024);
                NSString* stateText = TXSessionSlice(stateOffset, recordData.length - MIN(stateOffset, recordData.length));
                if (memoryText.length) TXLogEngine(@"Session memory slot:\n%@", memoryText);
                if (stallText.length) TXLogEngine(@"Session stall slot:\n%@", stallText);
                if (networkText.length) TXLogEngine(@"Session network slot:\n%@", networkText);
                if (storageText.length) TXLogEngine(@"Session storage slot:\n%@", storageText);
                if (cameraText.length) TXLogEngine(@"Session camera slot:\n%@", cameraText);
                if (stateText.length) TXLogEngine(@"Session state:\n%@", stateText);
                // One-line summaries, readable at a glance.
                NSString* memoryFirstLine = [[memoryText componentsSeparatedByString:@"\n"] firstObject] ?: @"";
                if (memoryFirstLine.length) TXLogEngine(@"Session memory: %@", memoryFirstLine);
                NSString* stallFirstLine = [[stallText componentsSeparatedByString:@"\n"] firstObject] ?: @"";
                NSRange totalRange = [stallFirstLine rangeOfString:@" total "];
                if (totalRange.location != NSNotFound) {
                    NSString* afterTotal = [stallFirstLine substringFromIndex:totalRange.location + totalRange.length];
                    NSString* total = [[afterTotal componentsSeparatedByString:@" "] firstObject] ?: @"?";
                    TXLogEngine(@"Session stall: total %@ recorded", total);
                } else if (stallFirstLine.length) {
                    TXLogEngine(@"Session stall: %@", stallFirstLine);
                }
                NSString* endWord = nil, *bootWord = nil, *messageText = nil;
                for (NSString* line in [stateText componentsSeparatedByString:@"\n"]) {
                    if ([line hasPrefix:@"end "]) endWord = [line substringFromIndex:4];
                    else if ([line hasPrefix:@"boot "]) bootWord = [line substringFromIndex:5];
                    else if ([line hasPrefix:@"message "]) messageText = [line substringFromIndex:8];
                }
                if (endWord.length) TXLogEngine(@"Session end state: %@", endWord);
                if (bootWord.length) TXLogEngine(@"Session boot: %@", bootWord);
                if (messageText.length) TXLogEngine(@"Session message: %@", messageText);
            }
            TXLogFlush();
        } else {
            TXLogEngine(@"No previous session record");
        }
        // No sampler here: it is started by bootOnView: for the boot
        // window only. Starting it in init would log every 100 ms
        // forever on a fresh install (Idle), where there is no boot
        // to watch, and drain the battery.
    }
    return self;
}

// Canonicalize a path with realpath(): /var is a symlink to
// /private/var, so the guest paths the app builds start with
// /var/mobile/... while the framework's own dlopen path in the log
// reads /private/var/mobile/... . The runtime's std::filesystem
// checks should not care about a symlinked prefix, but a symlinked
// prefix is the one difference between the path the app stats and
// the path the framework resolves — remove it, so both sides name
// the same file the same way. Falls back to canonicalizing the
// parent directory and re-appending the last component when the
// file itself does not exist yet (the session record is created by
// the runtime during the run; the guest dir may not exist before
// the first install).
static NSString* TXCanonicalizePath(NSString* path) {
    if (!path.length) return path;
    char resolved[PATH_MAX];
    if (realpath(path.UTF8String, resolved)) {
        return [NSString stringWithUTF8String:resolved];
    }
    NSString* parent = [path stringByDeletingLastPathComponent];
    NSString* name = [path lastPathComponent];
    if (parent.length && realpath(parent.UTF8String, resolved)) {
        return [[NSString stringWithUTF8String:resolved] stringByAppendingPathComponent:name];
    }
    return path;
}

// Whether a host path can be named in a `ubd<n>=` kernel argument
// as itself: the runtime's uml::block::usable_ubd_path, replicated
// here so the pre-flight names the exact check that fails it. UML
// joins its arguments with spaces, and the kernel splits at
// whitespace (including byte 0xa0), quotes, and reads a comma or
// colon in a UBD specification as another field.
static BOOL TXPathUsableOnKernelCommandLine(NSString* path) {
    if (!path.length) return NO;
    const char* s = path.UTF8String;
    for (const char* p = s; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' ||
            c == '\r' || c == 0xa0 || c == '"' || c == ',' || c == ':') return NO;
    }
    return YES;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Load the runtime framework on Start, not at launch (see the header).
// The framework's own load commands pull in the three GPU frameworks,
// so nothing else needs loading. The handle is held forever: the
// runtime owns one host runtime per process lifetime, and its API
// table stays valid until process exit.
- (BOOL)loadRuntimeWithError:(NSString**)error {
    if (_api) return YES;
    // The framework lives in the bundle's Frameworks/ subdirectory,
    // which pathForResource:ofType: does NOT search on its own: the
    // bare call always returned nil, so every Boot failed with
    // "runtime framework is missing from the app bundle" even though
    // the framework is in the IPA. Look in Frameworks/ explicitly,
    // and fall back to the direct bundle-path construction.
    NSString* frameworkPath = [[NSBundle mainBundle] pathForResource:@"KRuntime_6_18_4K"
                                                              ofType:@"framework"
                                                         inDirectory:@"Frameworks"];
    if (!frameworkPath) {
        frameworkPath = [[[NSBundle mainBundle] bundlePath]
                         stringByAppendingPathComponent:@"Frameworks/KRuntime_6_18_4K.framework"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:frameworkPath]) frameworkPath = nil;
    }
    if (!frameworkPath) {
        // Diagnosable miss: log where we looked and what is there.
        NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
        NSString* frameworksDir = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
        NSArray* contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:frameworksDir error:nil];
        TXLogEngine(@"Runtime framework not found. Bundle: %@. Frameworks/: %@",
                    bundlePath, contents ?: @[]);
        if (error) *error = @"runtime framework is missing from the app bundle";
        return NO;
    }
    NSString* binaryPath = [frameworkPath stringByAppendingPathComponent:@"KRuntime_6_18_4K"];
    TXLogEngine(@"Loading runtime framework (dlopen): %@", binaryPath);
    // RTLD_GLOBAL, not RTLD_LOCAL: the kernel's ELF loader resolves
    // its Darwin imports through dlsym(RTLD_DEFAULT), so the
    // framework's symbols (e.g. darwin_uml_guest_shutdown) must be
    // globally visible or the guest exits with status 126.
    _runtimeHandle = dlopen(binaryPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!_runtimeHandle) {
        const char* why = dlerror();
        TXLogEngine(@"dlopen failed: %s", why ?: "?");
        if (error) *error = [NSString stringWithFormat:@"runtime framework did not load: %s", why ?: "?"];
        return NO;
    }
    typedef const kernarium_runtime_api* (*TXGetRuntimeAPIFn)(void);
    TXGetRuntimeAPIFn getAPI = (TXGetRuntimeAPIFn)dlsym(_runtimeHandle, "kernarium_runtime_get_api_v28");
    if (!getAPI) {
        TXLogEngine(@"dlsym failed: no kernarium_runtime_get_api_v28 in the framework");
        if (error) *error = @"runtime framework has no API entry point";
        return NO;
    }
    _api = getAPI();
    if (!_api) {
        if (error) *error = @"runtime framework returned no API";
        return NO;
    }
    TXLogEngine(@"Runtime loaded: ABI v%u, footprint %@", _api->abi_version,
                TXFormatBytes(TXCurrentFootprintBytes()));
    return YES;
}

- (void)memoryWarning:(NSNotification*)note {
    (void)note;
    TXLogEngine(@"MEMORY WARNING: state %@, footprint %@",
                TXStateName(self.state), TXFormatBytes(TXCurrentFootprintBytes()));
}

// Footprint sampler (diagnostic, 2026-11-22): the 08:00 runs on
// 20ec5ad died ~1 s into boot at kernel ~0.2-0.3 s with no crash
// record, at ~61 MiB footprint against ~4 GiB per-process jetsam
// headroom — per-process-limit jetsam is ruled out, but system-wide
// free memory was never measured, so vm-pageshortage (system-wide
// memory pressure) is the leading hypothesis and the Analytics
// JetsamEvent that would name it has not arrived. This sampler
// makes the next engine.log alone settle it: one synchronously
// flushed line every 100 ms from app launch until the guest is
// Running (or the run ends), with the process footprint, the
// per-process jetsam headroom, and system-wide free memory. If the
// last lines show a small footprint and collapsing system free
// memory, it is vm-pageshortage; if the footprint itself spikes, the
// cause is app-side. Cheap by design: two syscalls and one log line
// on a background queue, never touching the boot thread; a slow log
// flush only delays the next sample.
- (void)sampleMemoryOnce {
    // Process footprint + per-process jetsam headroom.
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
    unsigned long long footprint = 0, headroom = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &vmCount) == KERN_SUCCESS) {
        footprint = (unsigned long long)vmInfo.phys_footprint;
        headroom = (unsigned long long)vmInfo.limit_bytes_remaining;
    }
    // System-wide free memory: free + inactive pages. This is the
    // number per-process headroom cannot see: vm-pageshortage kills
    // the foreground app when the system runs out, even while this
    // process is small.
    unsigned long long sysFree = 0;
    vm_statistics64_data_t hostInfo;
    mach_msg_type_number_t hostCount = HOST_VM_INFO64_COUNT;
    vm_size_t pageSize = 0;
    if (host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS &&
        host_statistics64(mach_host_self(), HOST_VM_INFO, (host_info_t)&hostInfo, &hostCount) == KERN_SUCCESS) {
        sysFree = (unsigned long long)(hostInfo.free_count + hostInfo.inactive_count) * (unsigned long long)pageSize;
    }
    TXLogEngine(@"SAMPLER footprint=%@ (%llu B) headroom=%@ (%llu B) sysfree=%@ (%llu B)",
                TXFormatBytes(footprint), footprint,
                TXFormatBytes(headroom), headroom,
                TXFormatBytes(sysFree), sysFree);
    TXLogFlush(); // synchronously on disk: a kill a millisecond later must leave this line
}

- (void)startMemorySampler {
    @synchronized (self) {
        if (_samplerTimer) return; // already running (e.g. boot retry)
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        _samplerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        if (!_samplerTimer) return;
        __weak KernEngine *weakSelf = self;
        dispatch_source_set_event_handler(_samplerTimer, ^{
            KernEngine *strongSelf = weakSelf;
            if (strongSelf) [strongSelf sampleMemoryOnce];
        });
        dispatch_source_set_timer(_samplerTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  (uint64_t)(100 * NSEC_PER_MSEC),
                                  (uint64_t)(10 * NSEC_PER_MSEC));
        dispatch_resume(_samplerTimer);
    }
    TXLogEngine(@"SAMPLER started (100 ms)");
}

- (void)stopMemorySampler {
    BOOL wasRunning = NO;
    @synchronized (self) {
        if (_samplerTimer) {
            wasRunning = YES;
            dispatch_source_cancel(_samplerTimer);
            _samplerTimer = nil;
        }
    }
    if (wasRunning) TXLogEngine(@"SAMPLER stopped");
}

- (void)setState:(TermXState)state {
    if (state == _state) return;
    _state = state;
    TXLogEngine(@"State: %@ — %@", TXStateName(state), self.statusText ?: @"");
    // The sampler's job ends when the guest is up, stopped, or
    // failed — and when the state leaves the boot window for Idle
    // or Ready: on a fresh install (Idle) there is no boot to watch,
    // and on Ready the boot has not started yet, so the sampler
    // would otherwise log every 100 ms forever. A failed boot's
    // retry re-starts it from bootOnView:.
    if (state == TermXStateRunning || state == TermXStateStopped || state == TermXStateFailed ||
        state == TermXStateIdle || state == TermXStateReady) {
        [self stopMemorySampler];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kTermXStateChanged object:nil];
    id<KernEngineDelegate> delegate = self.delegate;
    if (delegate) [delegate termXEngineDidChangeState:state status:self.statusText];
}

- (void)setStatusText:(NSString*)statusText {
    // The download watcher reports the same step text every 0.25 s;
    // log only when the text actually changes, or the log drowns.
    BOOL changed = ![_statusText isEqualToString:statusText ?: @""];
    _statusText = [statusText copy];
    if (changed) TXLogEngine(@"%@", _statusText);
    [[NSNotificationCenter defaultCenter] postNotificationName:kTermXStateChanged object:nil];
    id<KernEngineDelegate> delegate = self.delegate;
    if (delegate) [delegate termXEngineDidChangeState:self.state status:self.statusText];
}

- (double)bootProgress {
    switch (self.state) {
        case TermXStateDownloading:
            return self.progress; // install fraction, 0..1, real
        case TermXStateBooting:
            // Real phase transitions only: run() started, then init.
            return (_bootPhase == TXBootPhaseServices) ? 0.7 : 0.35;
        case TermXStateRunning:
            return 1.0;
        case TermXStateFailed:
            return self.progress; // keep the last real value
        default:
            return 0.0;
    }
}

- (unsigned long long)storageUsedBytes {
    struct stat st;
    if (stat(_dataDiskPath.UTF8String, &st) != 0) return 0;
    return (unsigned long long)st.st_blocks * 512ULL;
}

- (unsigned long long)storageTotalBytes {
    // The actual file size, not the constant: an install that kept
    // its older 8 GiB disk must report 8 GiB, not the size a new
    // disk gets. A missing disk reports the size a new one will get
    // (the user setting, default 2 GiB).
    struct stat st;
    if (stat(_dataDiskPath.UTF8String, &st) == 0) return (unsigned long long)st.st_size;
    return (unsigned long long)[KernEngine dataDiskGiB] << 30;
}

- (BOOL)dataDiskReady {
    return _dataDiskReady;
}

- (NSString*)kernelDetail {
    NSString* ram = kGuestMemoryMiB >= 1024
        ? [NSString stringWithFormat:@"%u GiB RAM", kGuestMemoryMiB / 1024]
        : [NSString stringWithFormat:@"%u MiB RAM", kGuestMemoryMiB];
    return [NSString stringWithFormat:@"6.18.60 · %u vCPUs · %@", kGuestCPUs, ram];
}

- (NSString*)imageDetail {
    return @"trixie slim · read-only";
}

// Words for the quiesce settle report (KernariumRuntime.h: the
// KERNARIUM_RUNTIME_GUEST_STORAGE_* and
// KERNARIUM_RUNTIME_GUEST_SUSPENSION_* values), so the log reads
// instead of numbering.
static NSString* TXGuestStorageWord(uint32_t storage) {
    switch (storage) {
        case KERNARIUM_RUNTIME_GUEST_STORAGE_NOT_REPORTED: return @"not-reported";
        case KERNARIUM_RUNTIME_GUEST_STORAGE_CONFIRMED: return @"confirmed";
        case KERNARIUM_RUNTIME_GUEST_STORAGE_NO_GUEST: return @"no-guest";
        case KERNARIUM_RUNTIME_GUEST_STORAGE_UNCONFIRMED: return @"unconfirmed";
        case KERNARIUM_RUNTIME_GUEST_STORAGE_REFUSED: return @"refused";
        case KERNARIUM_RUNTIME_GUEST_STORAGE_UNREACHABLE: return @"unreachable";
        default: return @"?";
    }
}

static NSString* TXGuestSuspensionWord(uint32_t suspension) {
    switch (suspension) {
        case KERNARIUM_RUNTIME_GUEST_SUSPENSION_NOT_ASKED: return @"not-asked";
        case KERNARIUM_RUNTIME_GUEST_SUSPENSION_SUSPENDED: return @"suspended";
        case KERNARIUM_RUNTIME_GUEST_SUSPENSION_NOT_SUSPENDED: return @"not-suspended";
        default: return @"?";
    }
}

// Runs on _lifecycleQueue only (see enterBackground): has the guest
// write its filesystems back, trims its cold page cache, enters full
// system suspend and flushes the host's files, then releases the
// guest's disk locks — the runtime's own suspend protocol. Sets
// _quiesced only when the report says the guest suspended; a guest
// that refused or did not answer is still running, and there is
// nothing to resume.
- (void)quiesceGuestForBackground {
    if (!_api || !_running) return;
    kernarium_runtime_settle settle;
    memset(&settle, 0, sizeof(settle));
    settle.struct_size = (uint32_t)sizeof(settle);
    TXLogEngine(@"Background: quiescing the guest so the data disk is clean on the next launch");
    TXLogFlush();
    int rc = _api->quiesce_resident(&settle);
    TXLogEngine(@"Background: quiesce returned %d, storage %@, suspension %@",
                rc, TXGuestStorageWord(settle.guest_storage),
                TXGuestSuspensionWord(settle.guest_suspension));
    TXLogFlush();
    _quiesced = (rc >= 0 &&
                 settle.guest_suspension == KERNARIUM_RUNTIME_GUEST_SUSPENSION_SUSPENDED);
    if (_quiesced) {
        TXLogEngine(@"Background: guest suspended — the data disk is clean, resume on foreground");
    } else {
        TXLogEngine(@"Background: guest did not suspend — still running, nothing to resume");
    }
    TXLogFlush();
}

// Best effort for applicationWillTerminate: end the guest with a
// full request_stop so run() returns and the session record ends
// "stopped" instead of "running" + suspended. The terminate-path
// quiesce (0d01a7f) settled the disk but left the session "running"
// — quiesce suspends, it does not end the run — and the second
// launch still died, so this is session hygiene, not a boot fix by
// itself. request_stop is async: run() returns on its own thread.
// Wait bounded (3 s) for _running to clear; never stall
// termination past that. The background quiesce (enterBackground)
// is unchanged — it is what lets a foreground return resume — and
// a force-quit never calls applicationWillTerminate at all, so this
// only covers a terminate that arrives while foregrounded. No-op
// when no guest is running. If the guest was quiesced on
// background, request_stop ends the suspended run all the same, and
// _quiesced is cleared because there is nothing left to resume.
- (void)stopGuestForTermination {
    if (!_api || !_running) return;
    TXLogEngine(@"Terminate: stopping the guest so the session ends clean");
    TXLogFlush();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __weak typeof(self) weakSelf = self;
    dispatch_async(_lifecycleQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_api->request_stop();
            // Poll for run() returning: _running clears on the run
            // thread when run() returns and the session ends.
            // Bounded at 3 s so termination is never stalled.
            NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
            while (strongSelf->_running && [deadline timeIntervalSinceNow] > 0) {
                [NSThread sleepForTimeInterval:0.05];
            }
            if (!strongSelf->_running) {
                strongSelf->_quiesced = NO;
                TXLogEngine(@"Terminate: guest stopped — session ended clean");
            } else {
                TXLogEngine(@"Terminate: guest did not stop in 3 s — process dies with the session running");
            }
            TXLogFlush();
        }
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
}

- (void)enterBackground {
    // Quiesce the guest so the next launch does not find a dirty data
    // disk. The reboot crash (2026-11-22): TermX never stopped the
    // guest when the user left the app, so every restart was a
    // force-quit that left the data disk dirty — an ext4 journal of
    // uncommitted transactions — and the next boot died in early
    // kernel init (the 12:54 run booted on a fresh empty disk; the
    // 12:58 restart on the reused 137 MiB disk died at kernel
    // 0.19-0.32 s, and the session record said end "running", stall
    // total 0, memory healthy). The resident variant keeps the guest
    // RAM in the process and writes no hibernation image (a plain
    // quiesce writes up to 2 GiB to TMPDIR on every backgrounding,
    // and a fresh run() discards stale hibernation images anyway);
    // the disk settling is identical. Only when the guest is fully
    // up: a mid-boot guest cannot suspend, and the quiesce would burn
    // its bounded waits for nothing. Runs on the lifecycle queue,
    // never the main thread — a quiesce can block ~20 s — under a
    // background task so iOS gives it the time.
    if (!_api || !_running || self.state != TermXStateRunning) return;
    // Hold the guest GPU while backgrounded: iOS revokes the GPU within
    // seconds, and the runtime must not submit work while it is gone.
    // Only once the state check above has passed: a mid-boot guest
    // gets no quiesce, so it must get no hold either. A hold set
    // before the check would survive a boot that then fails while
    // backgrounded, and the retry would boot with the GPU held.
    _api->set_gpu_hold(1);
    __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
    __block BOOL bgTaskEnded = NO;
    // End the background task exactly once, on the main queue, from
    // either the quiesce finishing or the expiration handler: both
    // paths run through here, so the flag is race-free.
    void (^endBgTask)(void) = ^{
        if (!bgTaskEnded && bgTask != UIBackgroundTaskInvalid) {
            bgTaskEnded = YES;
            [[UIApplication sharedApplication] endBackgroundTask:bgTask];
        }
    };
    bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        TXLogEngine(@"Background time expired during guest quiesce — ending the background task; the quiesce keeps running and the foreground resume waits for it");
        dispatch_async(dispatch_get_main_queue(), endBgTask);
    }];
    if (bgTask == UIBackgroundTaskInvalid) {
        TXLogEngine(@"Could not begin a background task for the guest quiesce — quiescing anyway");
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(_lifecycleQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { dispatch_async(dispatch_get_main_queue(), endBgTask); return; }
        [strongSelf quiesceGuestForBackground];
        dispatch_async(dispatch_get_main_queue(), endBgTask);
    });
}

- (void)enterForeground {
    // Resume a quiesced guest, then release the GPU hold. The resume
    // runs on the lifecycle queue so it waits for any quiesce still
    // in flight (a fast background/foreground cycle); the GPU hold
    // is released on the main queue after the resume returns, as
    // today. When the guest never quiesced, the resume is skipped
    // and only the hold is released.
    __weak typeof(self) weakSelf = self;
    dispatch_async(_lifecycleQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_quiesced && strongSelf->_api && strongSelf->_running) {
            TXLogEngine(@"Foreground: resuming the quiesced guest");
            strongSelf->_api->resume();
            strongSelf->_quiesced = NO;
            TXLogEngine(@"Foreground: guest resumed");
            TXLogFlush();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // Release unconditionally (guard only on _api): a boot
            // that failed while backgrounded leaves _running NO, and
            // gating on _running would skip the release and leave
            // the retry booting with the GPU held.
            if (strongSelf->_api) strongSelf->_api->set_gpu_hold(0);
        });
    });
}

- (NSString*)dataDiskPath {
    return _dataDiskPath;
}

- (BOOL)guestInstalled {
    NSString* error = nil;
    return [GuestInstall guestInstalledAt:_rootfsPath error:&error];
}

// Explicit getter: the ivar is declared in the class extension
// above, so no synthesis is wanted for this readonly property.
- (BOOL)launchUpdateCheckInFlight {
    return _launchUpdateCheckInFlight;
}

// Launch update check (timing diagnostic, 2026-11-22): settles
// whether the installed image is this build's release, on a
// background queue — never the main thread, it reads 1 GiB. It
// sets updateAvailable, and when a newer image is available it
// holds the guest stopped (Ready -> Stopped) so the startup screen
// offers a tappable Update button instead of racing the auto-boot
// into "Starting...". Applies only while the launch check is still
// the thing holding the flag: if the user tapped Install meanwhile,
// the install completion owns the flag instead, and this completion
// stands down.
- (void)checkForImageUpdateForLaunch {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Cheap first: the fingerprint recorded by the install
        // pipeline carries the hash it verified. A recorded hash
        // answers the question with no 1 GiB hash at all — equal
        // means current, different means an older release.
        NSString* recordedHash = [GuestInstall installedImageVerifiedHashAt:strongSelf->_rootfsPath];
        BOOL answered = recordedHash != nil;
        BOOL current = answered && [recordedHash isEqualToString:kRootfsSHA256];
        if (!answered) {
            // No fingerprint hash to answer from (image installed by
            // an older build, or the fingerprint predates the hash
            // field): one full hash settles it, and on success the
            // fingerprint is re-recorded with the hash, so the next
            // launch answers cheaply. A mismatch is an older
            // release — an update — never a failure.
            NSString* error = nil;
            current = [GuestInstall guestImageHashValidAt:strongSelf->_rootfsPath error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf2 = weakSelf;
            if (!strongSelf2 || !strongSelf2->_launchUpdateCheckInFlight) return;
            strongSelf2->_launchUpdateCheckInFlight = NO;
            // An update holds the boot: the guest stays stopped so
            // the startup screen shows a tappable Update button (and
            // a Start button to boot as-is) instead of racing the
            // auto-boot into "Starting...". Only while the guest is
            // still Ready — if it already booted, the Update button
            // is offered from Running instead. The state moves first,
            // so no refresh in between can schedule the auto-boot.
            if (!current && strongSelf2.state == TermXStateReady) {
                strongSelf2.statusText = @"Update available — tap Update to install it, or Start to boot as-is";
                strongSelf2.state = TermXStateStopped;
            }
            strongSelf2.updateAvailable = !current;
            TXLogEngine(@"Image update check: installed image is %@",
                        current ? @"the current release" : @"an older release — update available");
            TXLogFlush();
        });
    });
}

// The update flag is a state of its own: the startup screen reads
// it on every refresh, so a change must notify like a state change.
- (void)setUpdateAvailable:(BOOL)updateAvailable {
    if (_updateAvailable == updateAvailable) return;
    _updateAvailable = updateAvailable;
    [[NSNotificationCenter defaultCenter] postNotificationName:kTermXStateChanged object:nil];
}

- (void)installGuestWithCompletion:(void (^)(BOOL, NSString*))completion {
    self.bootPhase = TXBootPhaseDownloading;
    self.failedStep = -1;
    self.downloadReceived = 0;
    self.downloadExpected = 0;
    self.state = TermXStateDownloading;
    self.statusText = @"Downloading Debian image…";
    TXLogEngine(@"Install started: %@", kRootfsURL);
    __weak typeof(self) weakSelf = self;
    [GuestInstall installGuestTo:_rootfsPath progress:^(double f, NSString* step, int64_t received, int64_t expected) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.progress = f;
        strongSelf.downloadReceived = received;
        strongSelf.downloadExpected = expected;
        // The install fraction is the real phase: the download
        // occupies 0..0.6, verify/extract/verify the rest.
        strongSelf.bootPhase = (f < 0.6) ? TXBootPhaseDownloading : TXBootPhaseVerifying;
        strongSelf.statusText = step;
    } completion:^(BOOL ok, NSString* error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { if (completion) completion(ok, error); return; }
        if (ok) {
            strongSelf.bootPhase = TXBootPhaseIdle;
            strongSelf.state = TermXStateReady;
            strongSelf.statusText = @"Guest ready — starting the engine…";
            // The install just put this build's release in: no
            // update is available any more.
            strongSelf.updateAvailable = NO;
            // Distinct from the pipeline's "Install complete: guest
            // image verified" line: that one is the pipeline finishing,
            // this one is the completion reaching the engine. The two
            // used to share one string, which read as the pipeline
            // running twice (the 10:32 log) when the completion was
            // merely delayed behind the per-tick re-hash on the main
            // queue.
            TXLogEngine(@"Install done — guest ready");
        } else if ([error isEqualToString:@"cancelled"]) {
            // A user cancel is not a failure: back to Idle, and the
            // next Install resumes from the saved resume data.
            strongSelf.bootPhase = TXBootPhaseIdle;
            strongSelf.state = TermXStateIdle;
            strongSelf.statusText = @"Download cancelled — tap Install to resume";
        } else {
            strongSelf.bootPhase = TXBootPhaseFailed;
            strongSelf.failedStep = TXBootStepImage;
            strongSelf.state = TermXStateFailed;
            strongSelf.statusText = error ?: @"Install failed";
        }
        if (completion) completion(ok, error);
    }];
}

// Create the persistent data disk if it does not exist yet; reuse it
// otherwise. The path must name no spaces, quotes, commas or colons
// (the runtime names it on the kernel command line); Documents/guest
// is safe. The file is sparse (ftruncate), so a 32 GiB disk costs
// nothing until the guest writes, and it is excluded from backup: a
// multi-gigabyte guest disk must never ride along in an iCloud backup.
// The stock upstream boot-ramdisk /init formats the upper layer on
// every boot, which would wipe this file's contents each time; TermX
// ships a framework built with that step changed to
// format-only-when-unformatted, so a reused file keeps its data.
- (BOOL)createDataDiskIfNeededWithError:(NSString**)error {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSDictionary* attrs = [fm attributesOfItemAtPath:_dataDiskPath error:nil];
    // The size a NEW disk gets comes from the user setting (default
    // 2 GiB). An existing disk is reused at its own size below and
    // never resized by this setting.
    off_t size = (off_t)[KernEngine dataDiskGiB] << 30;
    if (attrs) {
        // Reuse whatever disk is already there, whatever its size.
        // An existing install keeps its disk (8 GiB from before this
        // build) until the user erases it: deleting it here to resize
        // would wipe every installed package and file. Only a missing
        // disk is created, at the current size.
        TXLogEngine(@"Reusing data disk: %@ used of %@",
                    TXFormatBytes(self.storageUsedBytes),
                    TXFormatBytes(self.storageTotalBytes));
        return YES;
    }
    int fd = open(_dataDiskPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        if (error) *error = @"could not create the data disk";
        return NO;
    }
    BOOL ok = ftruncate(fd, size) == 0;
    close(fd);
    if (!ok) {
        // Remove the empty/partial file: if it stays, the next boot
        // "reuses" it (the pre-flight only checks it is a regular
        // file) and fails the same way again, forever.
        unlink(_dataDiskPath.UTF8String);
        if (error) *error = @"could not size the data disk";
        return NO;
    }
    NSURL* url = [NSURL fileURLWithPath:_dataDiskPath];
    [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    TXLogEngine(@"Created data disk: %@ at %@", TXFormatBytes(self.storageTotalBytes), _dataDiskPath);
    return YES;
}

- (BOOL)eraseDataDiskWithError:(NSString**)error {
    if (self.state == TermXStateRunning || self.state == TermXStateBooting ||
        self.state == TermXStateDownloading) {
        if (error) *error = @"stop the guest before erasing the data disk";
        return NO;
    }
    NSFileManager* fm = [NSFileManager defaultManager];
    NSError* removeError = nil;
    if ([fm fileExistsAtPath:_dataDiskPath] &&
        ![fm removeItemAtPath:_dataDiskPath error:&removeError]) {
        if (error) *error = @"could not erase the data disk";
        return NO;
    }
    _dataDiskReady = NO;
    TXLogEngine(@"Data disk erased");
    return YES;
}

// Pre-flight: replicate the runtime's runtimeRun() validation
// with the real values, before run() is called. The 13:42 run
// failed with "Guest run failed (-1)" — -UML_EMULATOR_INVALID_
// ARGUMENT — three times, and the runtime prints the exact failing
// check to stderr, which the app never captured (main() now does).
// This check names the cause here instead: a failure returns NO
// with *error set to the exact check, the engine goes Failed with
// that text, and run() is never called. On success it logs the
// validated values in one line and hands back the display size
// run() must use. The checks run in the runtime's own order, so the
// first failure named is the first failure the runtime would hit.
- (BOOL)preflightBootOnView:(MTKView*)view
                      width:(uint32_t*)outWidth
                     height:(uint32_t*)outHeight
                      error:(NSString**)error {
    // 1. The request itself: the runtime refuses a struct smaller
    // than everything before the adb key. The app's header is the
    // upstream header at the pinned commit fbe12ee, the same commit
    // the Mac framework was built from, and the framework reports
    // ABI v43, which the header declares — but log the numbers, so
    // a mismatch shows up instead of being assumed away.
    uint32_t structSize = (uint32_t)sizeof(kernarium_runtime_boot);
    size_t minStructSize = offsetof(kernarium_runtime_boot, android_adb_public_key);
    TXLogEngine(@"Pre-flight: boot struct %u bytes (runtime needs >= %zu), ABI v%u",
                structSize, minStructSize, KERNARIUM_RUNTIME_API_VERSION);
    if (structSize < minStructSize) {
        if (error) *error = @"Boot refused: boot request is too small for this runtime (struct_size)";
        TXLogEngine(@"Pre-flight FAILED: struct_size %u < %zu", structSize, minStructSize);
        return NO;
    }
    // 2. Display geometry: the runtime refuses a zero side, a side
    // over its 4095 maximum, or zero DPI.
    CGFloat scale = [UIScreen mainScreen].scale;
    uint32_t width = (uint32_t)(view.bounds.size.width * scale);
    uint32_t height = (uint32_t)(view.bounds.size.height * scale);
    uint32_t dpi = 160;
    TXLogEngine(@"Pre-flight: display %lux%lu pt @%.0fx = %ux%u px @%u DPI (max 4095)",
                (unsigned long)view.bounds.size.width, (unsigned long)view.bounds.size.height,
                (double)scale, width, height, dpi);
    if (width == 0 || height == 0 || width > 4095 || height > 4095 || dpi == 0) {
        if (error) *error = [NSString stringWithFormat:
            @"Boot refused: guest display is %ux%u — the view has not laid out yet", width, height];
        TXLogEngine(@"Pre-flight FAILED: invalid display geometry %ux%u @%u DPI", width, height, dpi);
        return NO;
    }
    // 3. CPU and memory: the runtime admits 512 MiB through its
    // ceiling in 64 MiB steps, and no more vCPUs than the host has.
    // The ceiling never exceeds physical RAM, so that is the bound
    // checked here; the GPU-budget call below reports the runtime's
    // own limit as well.
    NSUInteger hostCPUs = [NSProcessInfo processInfo].processorCount;
    unsigned long long physicalMiB = [NSProcessInfo processInfo].physicalMemory >> 20;
    TXLogEngine(@"Pre-flight: %u vCPUs (host %lu), %u MiB RAM (host %llu MiB, min 512, step 64)",
                kGuestCPUs, (unsigned long)hostCPUs, kGuestMemoryMiB, physicalMiB);
    if (kGuestCPUs == 0 || kGuestCPUs > (hostCPUs == 0 ? 1 : (uint32_t)hostCPUs)) {
        if (error) *error = @"Boot refused: guest vCPU count is not admitted on this phone";
        TXLogEngine(@"Pre-flight FAILED: %u vCPUs vs host %lu", kGuestCPUs, (unsigned long)hostCPUs);
        return NO;
    }
    if (kGuestMemoryMiB < 512 || (kGuestMemoryMiB - 512) % 64 != 0 ||
        kGuestMemoryMiB > physicalMiB) {
        if (error) *error = @"Boot refused: guest memory size is not admitted on this phone";
        TXLogEngine(@"Pre-flight FAILED: %u MiB RAM vs host %llu MiB", kGuestMemoryMiB, physicalMiB);
        return NO;
    }
    // 4. Session record path: empty or PATH_MAX long is refused.
    // Canonicalized like the other boot paths (see
    // TXCanonicalizePath): the file itself may not exist yet, so
    // the parent directory is what realpath() resolves.
    _sessionRecordPath = TXCanonicalizePath([_guestDir stringByAppendingPathComponent:@"session.json"]);
    TXLogEngine(@"Pre-flight: session record path %@ (%lu bytes)",
                _sessionRecordPath, (unsigned long)_sessionRecordPath.length);
    if (_sessionRecordPath.length == 0 || _sessionRecordPath.length >= PATH_MAX) {
        if (error) *error = @"Boot refused: session record path is invalid";
        TXLogEngine(@"Pre-flight FAILED: session record path length %lu",
                    (unsigned long)_sessionRecordPath.length);
        return NO;
    }
    // 5. Rootfs and overlay: both must be regular files. The rootfs
    // must also be an .ext4 image with no write bits at all — the
    // runtime's immutableExt4Rootfs. The image on the phone was
    // installed by build 11f547d; the pipeline chmods it to 0444
    // after verify, and the 13:42 legacy hash running proves it had
    // no write bits then — but bits can change (a restore, a file
    // provider), so re-assert them here instead of assuming: if
    // they are wrong, fix them and log it; only fail when the fix
    // does not stick.
    struct stat rootSt;
    if (stat(_rootfsPath.UTF8String, &rootSt) != 0 || !S_ISREG(rootSt.st_mode)) {
        if (error) *error = @"Boot refused: guest image is missing or not a file";
        TXLogEngine(@"Pre-flight FAILED: rootfs %@ is not a regular file", _rootfsPath);
        return NO;
    }
    if ((unsigned long long)rootSt.st_size != (unsigned long long)kRootfsSize) {
        if (error) *error = @"Boot refused: guest image has the wrong size";
        TXLogEngine(@"Pre-flight FAILED: rootfs size %@, expected %@",
                    TXFormatBytes((unsigned long long)rootSt.st_size),
                    TXFormatBytes((unsigned long long)kRootfsSize));
        return NO;
    }
    if (![[_rootfsPath.pathExtension lowercaseString] isEqualToString:@"ext4"]) {
        if (error) *error = @"Boot refused: guest image is not an .ext4 image";
        TXLogEngine(@"Pre-flight FAILED: rootfs extension is %@", _rootfsPath.pathExtension);
        return NO;
    }
    mode_t rootMode = rootSt.st_mode & 0777;
    if (rootMode & 0222) {
        TXLogEngine(@"Pre-flight: rootfs has write bits (mode %04o) — re-applying read-only", rootMode);
        chmod(_rootfsPath.UTF8String, 0444);
        if (stat(_rootfsPath.UTF8String, &rootSt) != 0 || (rootSt.st_mode & 0222)) {
            if (error) *error = @"Boot refused: guest image could not be made read-only";
            TXLogEngine(@"Pre-flight FAILED: rootfs still writable after chmod 0444");
            return NO;
        }
        TXLogEngine(@"Pre-flight: rootfs is read-only again (mode %04o)", rootSt.st_mode & 0777);
    }
    // The runtime checks only the extension and the bits, but a file
    // with the right name and bits could still be the wrong bytes:
    // confirm the ext4 superblock magic (0xEF53 at offset 1080).
    int magicFd = open(_rootfsPath.UTF8String, O_RDONLY);
    if (magicFd >= 0) {
        unsigned char magic[2] = {0, 0};
        ssize_t n = pread(magicFd, magic, sizeof(magic), 1080);
        close(magicFd);
        if (n == 2) {
            TXLogEngine(@"Pre-flight: rootfs ext4 magic %02x %02x (want 53 ef)", magic[0], magic[1]);
            if (magic[0] != 0x53 || magic[1] != 0xEF) {
                if (error) *error = @"Boot refused: guest image is not an ext4 filesystem";
                TXLogEngine(@"Pre-flight FAILED: rootfs superblock magic is not ext4");
                return NO;
            }
        } else {
            TXLogEngine(@"Pre-flight: could not read rootfs superblock magic — continuing");
        }
    }
    struct stat overlaySt;
    if (stat(_dataDiskPath.UTF8String, &overlaySt) != 0 || !S_ISREG(overlaySt.st_mode)) {
        if (error) *error = @"Boot refused: data disk is missing or not a file";
        TXLogEngine(@"Pre-flight FAILED: overlay %@ is not a regular file", _dataDiskPath);
        return NO;
    }
    TXLogEngine(@"Pre-flight: rootfs %@ (mode %04o), overlay %@",
                _rootfsPath, rootSt.st_mode & 0777, _dataDiskPath);
    // 6. Both paths are named in `ubd<n>=` kernel arguments, which
    // cannot carry whitespace, a quote, a comma or a colon.
    if (!TXPathUsableOnKernelCommandLine(_rootfsPath)) {
        if (error) *error = @"Boot refused: guest image path cannot be named on the kernel command line";
        TXLogEngine(@"Pre-flight FAILED: rootfs path fails the UBD check: %@", _rootfsPath);
        return NO;
    }
    if (!TXPathUsableOnKernelCommandLine(_dataDiskPath)) {
        if (error) *error = @"Boot refused: data disk path cannot be named on the kernel command line";
        TXLogEngine(@"Pre-flight FAILED: overlay path fails the UBD check: %@", _dataDiskPath);
        return NO;
    }
    // 7. The GPU budget the runtime will compute for this boot: its
    // process limit is the one LiveContainer (or SideStore) gives
    // this process, so log the numbers instead of assuming them.
    if (_api->plan_gpu_budget) {
        kernarium_runtime_gpu_budget budget;
        memset(&budget, 0, sizeof(budget));
        budget.struct_size = (uint32_t)sizeof(budget);
        _api->plan_gpu_budget(kGuestMemoryMiB, kGuestCPUs, 0, 0, 0, &budget);
        TXLogEngine(@"Pre-flight: GPU budget %@ of a %@ limit, short_of_floor=%u, footprint %@",
                    TXFormatBytes(budget.budget_bytes),
                    TXFormatBytes(budget.process_limit_bytes),
                    budget.short_of_floor,
                    TXFormatBytes(TXCurrentFootprintBytes()));
        if (budget.short_of_floor) {
            self.statusText = @"Warning: low memory headroom — booting anyway";
        }
    }
    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    TXLogEngine(@"Pre-flight OK: display %ux%u, %u vCPUs, %u MiB RAM, rootfs read-only ext4, overlay present",
                width, height, kGuestCPUs, kGuestMemoryMiB);
    return YES;
}

// Guest RAM from the device: all of physical memory except a 1 GiB
// reserve for iOS and the app itself, with a 2 GiB floor. Read once
// per boot (bootOnView: sets kGuestMemoryMiB from this before the
// pre-flight). Rounded down to a 64 MiB step, which the runtime
// requires (see the pre-flight). Falls back to 2 GiB if the sysctl
// fails, which is the old fixed value.
static uint32_t TXComputeGuestMemoryMiB(void) {
    uint64_t memsize = 0;
    size_t len = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &len, NULL, 0) != 0 || memsize == 0) {
        return 2048;
    }
    uint64_t physicalMiB = memsize >> 20;
    uint64_t guestMiB = (physicalMiB > 1024) ? (physicalMiB - 1024) : 0;
    guestMiB = (guestMiB / 64) * 64; // round down to a 64 MiB step
    if (guestMiB < 2048) guestMiB = 2048;
    return (uint32_t)guestMiB;
}

- (void)bootOnView:(MTKView*)view {
    // Guest RAM from the device (see TXComputeGuestMemoryMiB): set it
    // before the pre-flight, which validates it, and before the boot
    // struct is built. The value is the same on every boot (physical
    // memory does not change), so recomputing on a retry is harmless.
    kGuestMemoryMiB = TXComputeGuestMemoryMiB();
    TXLogEngine(@"Guest RAM: %u MiB (device physical memory minus 1 GiB reserve)", kGuestMemoryMiB);
    // Clear any GPU hold left over from a backgrounded boot that
    // failed: the retry must boot with the GPU free. (The hold is
    // released unconditionally in enterForeground, so this only
    // covers a path that never came back to the foreground.)
    if (_api) _api->set_gpu_hold(0);
    [self startMemorySampler]; // a failed boot stopped it; the retry re-starts it
    NSString* loadError = nil;
    if (![self loadRuntimeWithError:&loadError]) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepKernel;
        self.state = TermXStateFailed;
        self.statusText = loadError ?: @"Runtime framework did not load";
        return;
    }
    if (!view) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepKernel;
        self.state = TermXStateFailed;
        self.statusText = @"No guest display — this is an app bug";
        return;
    }
    // Canonicalize the boot paths before anything reads them: the
    // guest dir was canonicalized in init, so this is normally a
    // no-op, but a path built any other way (a restore, a file
    // provider) still gets the /var -> /private/var symlink resolved
    // here, so the install check, the pre-flight and the runtime all
    // name the same files the same way. Log it when it changes
    // anything: that is the evidence the fix fired.
    NSString* oldRootfs = _rootfsPath;
    NSString* oldDataDisk = _dataDiskPath;
    _rootfsPath = TXCanonicalizePath(_rootfsPath);
    _dataDiskPath = TXCanonicalizePath(_dataDiskPath);
    if (![_rootfsPath isEqualToString:oldRootfs] || ![_dataDiskPath isEqualToString:oldDataDisk]) {
        TXLogEngine(@"Canonicalized boot paths: rootfs %@ -> %@, overlay %@ -> %@",
                    oldRootfs, _rootfsPath, oldDataDisk, _dataDiskPath);
    }
    NSString* installError = nil;
    if (![GuestInstall guestInstalledAt:_rootfsPath error:&installError]) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepImage;
        self.state = TermXStateFailed;
        // The exact reason: absent ("not installed"), or genuinely
        // damaged. A version difference never reaches here — an
        // older valid image counts as installed and boots.
        self.statusText = installError ?: @"Guest is not installed — tap Install first";
        return;
    }
    _dataDiskReady = NO;
    self.failedStep = -1;
    NSString* error = nil;
    if (![self createDataDiskIfNeededWithError:&error]) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepStorage;
        self.state = TermXStateFailed;
        self.statusText = error;
        return;
    }
    _dataDiskReady = YES;
    // Pre-flight first: replicate the runtime's validation with the
    // real values. A failure names the exact check, goes Failed with
    // that text, and never calls run() — the 13:42 run failed three
    // times with a bare "Guest run failed (-1)" and no cause.
    uint32_t bootWidth = 0, bootHeight = 0;
    NSString* preflightError = nil;
    if (![self preflightBootOnView:view width:&bootWidth height:&bootHeight error:&preflightError]) {
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepKernel;
        self.state = TermXStateFailed;
        self.statusText = preflightError ?: @"Boot refused — see the log for the exact check";
        TXLogFlush(); // the named cause must be on disk even if the app is killed next
        return;
    }
    _api->set_console_output_callback(ConsoleOutput, (__bridge void*)self);
    kernarium_runtime_boot boot;
    memset(&boot, 0, sizeof(boot));
    boot.struct_size = (uint32_t)sizeof(boot);
    boot.width = bootWidth;
    boot.height = bootHeight;
    boot.dots_per_inch = 160;
    boot.guest_memory_mib = kGuestMemoryMiB;
    boot.guest_processor_count = kGuestCPUs;
    boot.rootfs_path = _rootfsPath.UTF8String;
    boot.overlay_path = _dataDiskPath.UTF8String;
    boot.session_record_path = _sessionRecordPath.UTF8String; // set by the pre-flight
    boot.use_jit = 0; // gadget (interpreter) engine: no JIT, no debugger
    // The boot struct's C strings must stay valid until run() returns,
    // on the run's own thread: copy them into buffers this boot owns,
    // so no NSString UTF8String lifetime question can remain. The
    // run's block frees them after run() returns; a second boot
    // allocates its own buffers, so the two can never share one.
    char* bootRootfs = boot.rootfs_path ? strdup(boot.rootfs_path) : NULL;
    char* bootOverlay = boot.overlay_path ? strdup(boot.overlay_path) : NULL;
    char* bootSession = boot.session_record_path ? strdup(boot.session_record_path) : NULL;
    if (!bootRootfs || !bootOverlay || (boot.session_record_path && !bootSession)) {
        free(bootRootfs); free(bootOverlay); free(bootSession);
        self.bootPhase = TXBootPhaseFailed;
        self.failedStep = TXBootStepKernel;
        self.state = TermXStateFailed;
        self.statusText = @"Boot refused: could not copy the guest paths";
        return;
    }
    boot.rootfs_path = bootRootfs;
    boot.overlay_path = bootOverlay;
    boot.session_record_path = bootSession;
    self.bootPhase = TXBootPhaseKernel;
    self.state = TermXStateBooting;
    self.statusText = @"Booting Debian…";
    TXLogEngine(@"Boot started: %ux%u display, %u vCPUs, %u MiB RAM, data disk %llu GiB",
                bootWidth, bootHeight, kGuestCPUs, kGuestMemoryMiB,
                (unsigned long long)(self.storageTotalBytes >> 30));
    _running = YES;
    // run() blocks until the guest stops, so it owns its own thread.
    // A Linux guest has no boot_completed signal: the console callback
    // flips the state to Running on the login prompt.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // The experiment, on the exact C strings run() is about to
        // read: log the raw bytes (pointer, length, full text, hex
        // dump), then repeat the runtime's exact std::filesystem
        // checks on them. If the strings are wrong here, the pointers
        // were the problem all along; if the checks fail here, the
        // log names which one and its error; if they pass here and
        // run() still fails with the runtime's line, the runtime sees
        // different bytes than the app hands it — that is the
        // distinction this build exists to draw. A failure refuses
        // the boot with the named cause instead of handing possibly
        // bad pointers to the runtime.
        NSUInteger rootfsBytes = [self->_rootfsPath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger overlayBytes = [self->_dataDiskPath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger sessionBytes = [self->_sessionRecordPath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        // Each logged separately (no && chain): a bad first string
        // must not hide the other two.
        BOOL rootfsStringOK = TXLogBootCString("rootfs", boot.rootfs_path, rootfsBytes);
        BOOL overlayStringOK = TXLogBootCString("overlay", boot.overlay_path, overlayBytes);
        BOOL sessionStringOK = TXLogBootCString("session", boot.session_record_path, sessionBytes);
        // The exact check runs even when a string looks wrong: the
        // two are independent evidence, and both belong in the log.
        BOOL pathsExactOK = TXCheckBootPathsExact(boot.rootfs_path, boot.overlay_path);
        BOOL stringsOK = rootfsStringOK && overlayStringOK && sessionStringOK;
        BOOL pathsOK = stringsOK && pathsExactOK;
        TXLogFlush(); // the experiment lines must be on disk even if the run kills the process
        if (!pathsOK) {
            free(bootRootfs); free(bootOverlay); free(bootSession);
            self->_running = NO;
            self.bootPhase = TXBootPhaseFailed;
            self.failedStep = TXBootStepKernel;
            self.state = TermXStateFailed;
            self.statusText = @"Boot refused: the runtime's own path check fails on the boot paths — see the log";
            return;
        }
        int result = self->_api->run(view, &boot);
        free(bootRootfs); free(bootOverlay); free(bootSession);
        self->_running = NO;
        if (result == 0) {
            self.bootPhase = TXBootPhaseIdle;
            self.state = TermXStateStopped;
            self.statusText = @"Guest powered off";
        } else if (result == KERNARIUM_RUNTIME_RESULT_RESTART_LOOP) {
            TXBootPhase phaseAtEnd = self.bootPhase;
            self.bootPhase = TXBootPhaseFailed;
            self.failedStep = (phaseAtEnd == TXBootPhaseServices)
                ? TXBootStepStartup : TXBootStepKernel;
            self.state = TermXStateFailed;
            self.statusText = @"Guest kept restarting — see the console";
        } else {
            TXBootPhase phaseAtEnd = self.bootPhase;
            self.bootPhase = TXBootPhaseFailed;
            self.failedStep = (phaseAtEnd == TXBootPhaseServices)
                ? TXBootStepStartup : TXBootStepKernel;
            self.state = TermXStateFailed;
            self.statusText = [NSString stringWithFormat:@"Guest run failed (%d)", result];
        }
    });
}

- (void)stopGuest {
    [self stopMemorySampler]; // clean shutdown ends the sampling window
    // Stopping a download cancels it (the background session saves
    // resume data) and goes back to Idle; stopping a running guest
    // asks the runtime to stop it.
    if (self.state == TermXStateDownloading) {
        TXLogEngine(@"Stop requested during download");
        [GuestInstall cancelDownload];
        return;
    }
    TXLogEngine(@"Stop requested");
    if (_api && _running) _api->request_stop();
}

- (NSData*)bufferedConsoleOutput {
    @synchronized (self) {
        return [self.consoleBuffer copy] ?: [NSData data];
    }
}

- (void)sendConsoleInput:(NSData*)data {
    if (!_api || !_running || data.length == 0) return;
    // On the Linux runtime this writes to the guest's ttyS0. (The Android
    // App Store runtime answers -ENOTSUP here; this app never links it.)
    (void)_api->send_console_input(data.bytes, data.length);
}

@end
