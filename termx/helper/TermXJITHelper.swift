// TermXJITHelper - the built-in StikJIT helper for TermX.
//
// The built-in JIT enabler: a second process that attaches a debugger to
// TermX. TermX can't do it itself, because attaching stops every thread of
// the process being attached to, the one talking to the debugger included.
//
// A classic app extension on Apple's AR viewer point with a FALSEPREDICATE
// activation rule, so nothing but TermX ever starts it: TermX begins a
// request with NSExtension's private calls (TXStikJITTransport). One
// request, one reply, each the item's userInfo:
//
//   in:  "op": "enable" (the default) or "prepare" or "reset";
//        "pairing", the pairing file's bytes;
//        for enable, "pid", the process to attach to, and "forceScript",
//        whether to run the script even when no TXM/SPTM is detected
//        (default false)
//   out: "ok" (Bool), "summary" (String), and "log" ([String]), this
//        helper's lines (there's no channel to stream them back on)
//
// "prepare" only readies the device (reaches it through the tunnel, mounts
// the developer disk image), for the setup sheet; "enable" does that too,
// then attaches and runs the script; "reset" removes the cached developer
// disk image files so the next preparation downloads them again.
//
// StikJIT (MPL-2.0, Frameworks/StikJIT.xcframework, device builds only)
// does the work: through LocalDevVPN's tunnel it mounts the developer disk
// image when needed, attaches, and runs universal.js, which authorizes the
// regions TermX's JIT allocator asks for with `brk #0xf00d` and detaches.
// So the reply comes once TermX has its code regions, or with what went
// wrong. The script is fixed to .universal in backend code; it is never a
// user setting.
//
// The helper owns one persistent DDI cache (Library/StikJIT in this
// extension's own container) and runs all StikJIT work on one private
// serial queue, in order, one operation at a time: StikJIT's APIs are
// synchronous and blocking. The pairing file is written to a temporary
// file of this process's own and deleted as soon as the operation is
// done; its bytes are never logged.
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(StikJIT)
import StikJIT
#endif

@objc(TermXJITHelper)
final class TermXJITHelper: NSObject, NSExtensionRequestHandling {
    /// StikJIT's calls block and must run in order, one at a time.
    private static let queue = DispatchQueue(label: "app.termx.ios.jithelper")

    func beginRequest(with context: NSExtensionContext) {
        let request = (context.inputItems.first as? NSExtensionItem)?.userInfo ?? [:]
        Self.queue.async {
            var lines: [String] = []
            var reply: [String: Any] = [:]
            do {
                let log: (String) -> Void = { lines.append($0) }
                switch request["op"] as? String ?? "enable" {
                case "prepare": reply["summary"] = try Self.prepare(request, log: log)
                case "reset": reply["summary"] = try Self.reset(log: log)
                default: reply["summary"] = try Self.enable(request, log: log)
                }
                reply["ok"] = true
            } catch {
                reply["ok"] = false
                reply["summary"] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            reply["log"] = lines
            let item = NSExtensionItem()
            item.userInfo = reply
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }

    private static func enable(_ request: [AnyHashable: Any], log: @escaping (String) -> Void) throws -> String {
        guard let pid = request["pid"] as? Int, pid > 0 else { throw HelperError("no pid to attach to") }
        let forceScript = request["forceScript"] as? Bool ?? false
        #if canImport(StikJIT)
        return try withPairingFile(request) { pairingURL in
            let started = Date.now
            log("attaching to \(pid)")
            try StikJIT.enableJIT(
                targetPID: Int32(pid),
                pairingFile: pairingURL,
                ddiPaths: ddiPaths,
                script: .universal,
                forceScript: forceScript,
                preparationProgress: { stage in log("prepare: \(stage)") },
                progress: { line in log(line) })
            return String(format: "attached, authorized and detached in %.1f s", Date.now.timeIntervalSince(started))
        }
        #else
        throw HelperError("this helper was built without StikJIT (Simulator builds have none)")
        #endif
    }

    private static func prepare(_ request: [AnyHashable: Any], log: @escaping (String) -> Void) throws -> String {
        #if canImport(StikJIT)
        return try withPairingFile(request) { pairingURL in
            let readiness = StikJIT.prepareDevice(pairingFile: pairingURL, paths: ddiPaths) { stage in
                log("prepare: \(stage)")
            }
            switch readiness {
            case .ready(let security):
                let txm = security.isTXMPresent.map { $0 ? "TXM present" : "no TXM" } ?? "TXM unknown"
                return "ready, \(txm)"
            case .unreachable(let reason):
                throw HelperError("couldn't reach this iPhone through LocalDevVPN: \(reason)")
            case .preparationFailed(let reason):
                throw HelperError(reason)
            @unknown default:
                throw HelperError("StikJIT gave an answer this helper doesn't know")
            }
        }
        #else
        throw HelperError("this helper was built without StikJIT (Simulator builds have none)")
        #endif
    }

    private static func reset(log: @escaping (String) -> Void) throws -> String {
        #if canImport(StikJIT)
        log("removing cached developer disk image")
        try StikJIT.resetCachedDDI(at: ddiPaths)
        return "cached developer disk image removed; the next preparation downloads it again"
        #else
        throw HelperError("this helper was built without StikJIT (Simulator builds have none)")
        #endif
    }

    #if canImport(StikJIT)
    /// The developer disk image, downloaded once and kept here between requests.
    private static var ddiPaths: DDIPaths {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return DDIPaths.default(in: library.appendingPathComponent("StikJIT"))
    }
    #endif

    /// StikJIT reads the pairing file from disk: a file of this process's own,
    /// gone again as soon as `body` is done. Never logged.
    private static func withPairingFile<T>(_ request: [AnyHashable: Any], _ body: (URL) throws -> T) throws -> T {
        guard let pairing = request["pairing"] as? Data, !pairing.isEmpty else { throw HelperError("no pairing file") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
        try pairing.write(to: url, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }
}

struct HelperError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
