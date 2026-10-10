import Foundation
import CoreGraphics
import DisplayCore
import Darwin

struct Request: Decodable {
    let command: String
    let displayID: UInt32?
    let displayUUID: String?
    let factor: Float?
    let duration: Double?
    let renewable: Bool?
}

func reply(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    var line = data; line.append(10)
    try? FileHandle.standardOutput.write(contentsOf: line)
}

final class StopSignal {
    private let lock = NSLock()
    private var requested = false
    func request() { lock.lock(); requested = true; lock.unlock() }
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return requested }
}

final class Guardian {
    let store: RecoveryStore
    var journal: RecoveryJournal?
    var displayLock: DisplayMutationLock?
    var recoveryPending = false
    var lease: SessionLease?
    var shouldQuit = false
    init(store: RecoveryStore) { self.store = store }

    func ended(reason: String) {
        guard let current = journal else { return }
        let recovery = store.recover(current, heldLock: displayLock)
        lease = nil
        if recovery.succeeded {
            journal = nil
            displayLock = nil
            recoveryPending = false
        } else {
            // Retain exclusive ownership while this helper is alive so a failed
            // restoration cannot become another session's boosted baseline.
            // Stop/quit can retry recovery, and the durable journal survives exit.
            recoveryPending = true
        }
        var response: [String: Any] = ["ok": recovery.succeeded, "event": "ended", "reason": reason, "status": recovery.status, "message": recovery.message, "displayUUID": recovery.uuid]
        if let difference = recovery.difference { response["restorationDifference"] = difference }
        reply(response)
    }

    func handle(_ request: Request) {
        do {
            let now = ProcessInfo.processInfo.systemUptime
            if var currentLease = lease {
                try currentLease.heartbeat(at: now)
                lease = currentLease
            }
            switch request.command {
            case "begin":
                guard journal == nil else { throw DisplayError.invalid("An experiment is already active.") }
                guard try store.journalURLs().isEmpty else { throw DisplayError.invalid("Unresolved recovery journal exists; begin is blocked.") }
                guard let display = request.displayID, let factor = request.factor, let duration = request.duration,
                      duration.isFinite, duration >= 1, duration <= 45 else { throw DisplayError.invalid("Begin requires displayID, factor, and duration between 1 and 45 seconds.") }
                let identity = try DisplayIdentity.capture(display: display)
                if let expectedUUID = request.displayUUID {
                    guard UUID(uuidString: expectedUUID)?.uuidString == identity.uuid else {
                        throw DisplayError.invalid("The selected display changed before brightness could be enabled.")
                    }
                }
                let ownership = try store.acquireDisplayLock(uuid: identity.uuid)
                defer { withExtendedLifetime(ownership) {} }
                let peerRecoveries = try store.recoverOtherClientJournals(uuid: identity.uuid, heldLock: ownership)
                for recovery in peerRecoveries {
                    reply(["ok": recovery.succeeded, "event": "recovery", "status": recovery.status, "message": recovery.message, "displayUUID": recovery.uuid])
                }
                if let unresolved = peerRecoveries.first(where: { !$0.succeeded }) {
                    throw DisplayError.invalid("A previous Headroom session could not be restored. \(unresolved.message)")
                }
                guard try DisplayIdentity.capture(display: display) == identity else { throw DisplayError.invalid("Display identity or configuration changed while acquiring ownership.") }
                let baseline = try GammaTable.read(display: display)
                guard baseline.maximum <= 1.0005 else { throw DisplayError.invalid("Display already has transfer values above 1; an external transform may be active.") }
                let proposed = try baseline.scaled(factor: factor)
                var entry = RecoveryJournal(identity: identity, baseline: baseline, proposed: proposed)
                try store.save(entry)
                journal = entry
                displayLock = ownership
                lease = try SessionLease(now: ProcessInfo.processInfo.systemUptime, duration: duration, renewable: request.renewable ?? false)
                // Recheck after persistence so a concurrent ColorSync change is
                // not silently captured as this experiment's own write.
                guard try DisplayIdentity.capture(display: display) == identity,
                      try GammaTable.read(display: display).maxDifference(from: baseline) <= 0.0005 else { throw DisplayError.invalid("Display configuration or transform changed while arming the experiment.") }
                try proposed.apply(display: display)
                let readback = try GammaTable.read(display: display)
                try entry.recordReadback(readback)
                journal = entry
                try store.save(entry)
                reply(["ok": true, "event": "began", "message": "Experimental transfer scaling is active under the guardian lease; luminance gain is not established by readback.", "displayID": display, "displayUUID": identity.uuid, "factor": factor, "duration": duration, "renewable": request.renewable ?? false, "baselineMaximum": baseline.maximum, "readbackMaximum": readback.maximum, "readbackDifference": readback.maxDifference(from: proposed), "baselineDifference": readback.maxDifference(from: baseline), "sampleCount": baseline.count, "journalPath": store.path(for: entry).path])
            case "set":
                guard !recoveryPending, displayLock != nil, var entry = journal, let factor = request.factor,
                      let display = DisplayIdentity.resolve(uuid: entry.identity.uuid) else { throw DisplayError.invalid("No connected display experiment is active.") }
                let identity = try DisplayIdentity.capture(display: display)
                guard identity.configuration == entry.identity.configuration else { throw DisplayError.invalid("Display mode or color profile changed.") }
                let current = try GammaTable.read(display: display)
                guard entry.owns(current) else { throw DisplayError.invalid("Another application changed the display transfer table.") }
                entry.proposed = try entry.baseline.scaled(factor: factor)
                try store.save(entry)
                journal = entry
                // Persistence can take time. Do not overwrite a profile or
                // gamma change that occurred after the first ownership check.
                guard try DisplayIdentity.capture(display: display) == identity,
                      try GammaTable.read(display: display).maxDifference(from: current) <= 0.0005 else {
                    throw DisplayError.invalid("Display configuration or transform changed while updating brightness.")
                }
                try entry.proposed.apply(display: display)
                let readback = try GammaTable.read(display: display)
                try entry.recordReadback(readback)
                journal = entry
                try store.save(entry)
                reply(["ok": true, "event": "set", "message": "Gain derived from the original baseline.", "factor": factor, "readbackMaximum": readback.maximum, "readbackDifference": readback.maxDifference(from: entry.proposed)])
            case "ping": reply(["ok": true, "event": "pong", "message": "Guardian heartbeat received."])
            case "renew":
                guard !recoveryPending, journal != nil, var currentLease = lease else { throw DisplayError.invalid("No active session can be renewed.") }
                try currentLease.renew(at: now)
                lease = currentLease
                reply(["ok": true, "event": "renewed", "message": "User-controlled session deadline extended; heartbeat protection remains active.", "duration": SessionLease.renewalDuration])
            case "stop":
                if journal != nil { ended(reason: "stop") }
                else { reply(["ok": true, "event": "ended", "status": "inactive", "message": "No active experiment."]) }
            case "quit": ended(reason: "quit"); shouldQuit = true
            default: throw DisplayError.invalid("Unknown guardian command.")
            }
        } catch {
            ended(reason: "error")
            reply(["ok": false, "event": "error", "message": error.localizedDescription])
        }
    }

    func check() {
        guard !recoveryPending, let entry = journal else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let currentLease = lease else { ended(reason: "missingLease"); return }
        if let reason = currentLease.expiryReason(at: now) { ended(reason: reason); return }
        // A small readback once per second detects external gamma ownership
        // changes even while the parent is alive and not moving its slider.
        if now - lastOwnershipCheck >= 1 {
            lastOwnershipCheck = now
            guard let display = DisplayIdentity.resolve(uuid: entry.identity.uuid) else { ended(reason: "disconnected"); return }
            do {
                let identity = try DisplayIdentity.capture(display: display)
                let table = try GammaTable.read(display: display)
                if identity.configuration != entry.identity.configuration || !entry.owns(table) { ended(reason: "externalChange") }
            } catch { ended(reason: "readbackFailure") }
        }
    }
    var lastOwnershipCheck: TimeInterval = 0
}

let args = CommandLine.arguments
let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HeadroomLab/Recovery", isDirectory: true)
let directory: URL = {
    if let i = args.firstIndex(of: "--journal-dir"), args.indices.contains(i + 1) { return URL(fileURLWithPath: args[i + 1], isDirectory: true) }
    return defaultDirectory
}()

do {
    if args.contains("--inspect") {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw DisplayError.invalid("Cannot enumerate displays.") }
        var displays = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { throw DisplayError.invalid("Cannot enumerate displays.") }
        var output: [[String: Any]] = []
        for display in displays.prefix(Int(count)) {
            let identity = try DisplayIdentity.capture(display: display)
            let table = try GammaTable.read(display: display)
            output.append(["displayID": display, "uuid": identity.uuid, "sampleCount": table.count, "maximum": table.maximum, "configuration": identity.configuration])
        }
        reply(["ok": true, "event": "inspection", "message": "Read-only transfer table inspection.", "displays": output])
        exit(0)
    }
    let store = try RecoveryStore(directory: directory)
    let results = store.recoverAll()
    for result in results {
        reply(["ok": result.succeeded, "event": "recovery", "status": result.status, "message": result.message, "displayUUID": result.uuid])
    }
    if args.contains("--recover") { exit(results.allSatisfy(\.succeeded) ? 0 : 2) }
    let guardian = Guardian(store: store)
    // Avoid SIGPIPE terminating the helper before it can restore when its
    // parent's output reader disappears. EOF on input triggers restoration.
    signal(SIGPIPE, SIG_IGN)
    let stop = StopSignal()
    var signals: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { stop.request() }; source.resume(); signals.append(source)
    }
    reply(["ok": results.allSatisfy(\.succeeded), "event": "ready", "message": results.allSatisfy(\.succeeded) ? "Guardian ready; original tables will be journaled before mutation." : "Unresolved recovery requires attention; new experiments are blocked.", "maximumDuration": 45, "leaseSeconds": 5])
    var buffer = Data()
    while !guardian.shouldQuit {
        if stop.read() { guardian.ended(reason: "signal"); break }
        guardian.check()
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let status = poll(&descriptor, 1, 100)
        if status < 0 { if errno == EINTR { continue }; guardian.ended(reason: "inputFailure"); break }
        if status == 0 { continue }
        if descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let length = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if length <= 0 { if length < 0 && errno == EINTR { continue }; guardian.ended(reason: "parentDisconnected"); break }
            buffer.append(contentsOf: bytes.prefix(length))
            if buffer.count > 65536 { guardian.ended(reason: "oversizedInput"); break }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                do { guardian.handle(try JSONDecoder().decode(Request.self, from: line)) }
                catch { guardian.ended(reason: "invalidInput"); reply(["ok": false, "event": "error", "message": "Invalid JSON command."]) }
                if guardian.shouldQuit { break }
            }
        } else if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 { guardian.ended(reason: "inputFailure"); break }
    }
    withExtendedLifetime(signals) {}
} catch {
    reply(["ok": false, "event": "error", "message": error.localizedDescription])
    exit(1)
}
