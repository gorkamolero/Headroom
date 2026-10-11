import AppKit
import DisplayCore
import DisplayActivation
import ObjectiveC
import Darwin

/// Written and retained by the independent, existing Watchdog process.
private struct AuditBaseline: Codable {
    let identity: DisplayIdentity
    let nativeBrightness: Double
    let gamma: GammaTable
}

/// Read-only diagnostic access. Selector encodings were independently checked
/// against the installed runtime; every call still validates those encodings.
/// No keys, identifiers, strings, or nested objects escape the numeric allowlist.
private enum CoreBrightnessAuditReader {
    static func read(displayID: UInt32) -> [String: Any] {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL) else {
            return ["available": false, "reason": "framework unavailable"]
        }
        defer { dlclose(handle) }
        guard let type = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else {
            return ["available": false, "reason": "client unavailable"]
        }
        let selector = NSSelectorFromString("copyPropertyForKey:andDisplay:")
        guard let method = class_getInstanceMethod(type, selector),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding) == "@32@0:8@16Q24" else {
            return ["available": false, "reason": "unsupported method signature"]
        }
        typealias Read = @convention(c) (AnyObject, Selector, NSString, UInt64) -> Unmanaged<AnyObject>?
        let read = unsafeBitCast(method_getImplementation(method), to: Read.self)
        // A new client for each snapshot avoids reusing a prior client cache.
        // The argument is the CG display ID, never CBDisplayInfoDeviceID.
        let client = type.init()
        let physical = read(client, selector, "NitsPhysical", UInt64(displayID))?.takeRetainedValue()
        let state = read(client, selector, "EDRState", UInt64(displayID))?.takeRetainedValue() as? [String: Any]
        func numeric(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            return number.doubleValue
        }
        var result: [String: Any] = [:]
        if let value = numeric(physical) { result["NitsPhysical"] = value }
        var sanitized = [String: Double]()
        for key in ["SDR", "Headroom", "RequestedHeadroom", "AvailableHeadroom", "HDRMax", "PanelMax", "BrightnessCap"] {
            if let value = numeric(state?[key]) { sanitized[key] = value }
        }
        result["EDRState"] = sanitized
        result["available"] = result["NitsPhysical"] != nil && !sanitized.isEmpty
        return result
    }
}

@main
private enum BoostTelemetryAuditHarness {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: BoostTelemetryAudit baseline-path output-directory\n", stderr)
            exit(2)
        }
        do {
            let baseline = try JSONDecoder().decode(AuditBaseline.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let trial = try BoostTelemetryAudit(baseline: baseline, directory: directory)
            exit(trial.run() ? 0 : 1)
        } catch {
            fputs("Telemetry audit could not start: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private final class BoostTelemetryAudit {
    private let baseline: AuditBaseline
    private let directory: URL
    private let session: BoostSession
    private let nativeReader = NormalBrightnessReader()
    private let luminanceReader = DisplayLuminanceReader()
    private var patch: EDRPatch?
    private var samples = [[String: Any]]()
    private var checks = [String: Bool]()
    private var skipped = [String]()
    private var deadline = Double.infinity
    private var deadlineReached = false
    private var displayRefreshFailed = false
    private var screenChangeNotifications = 0
    private var began = 0.0
    private var resultError: String?

    init(baseline: AuditBaseline, directory: URL) throws {
        self.baseline = baseline
        self.directory = directory
        let log = directory.appendingPathComponent("harness.log")
        if FileManager.default.fileExists(atPath: log.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        guard let screen = NSScreen.screens.first(where: { screenID($0) == baseline.identity.displayID }),
              try DisplayIdentity.capture(display: baseline.identity.displayID) == baseline.identity else {
            throw DisplayError.invalid("Recorded display configuration is unavailable.")
        }
        session = BoostSession(screen: screen, identity: baseline.identity,
            directory: directory.appendingPathComponent("Recovery", isDirectory: true))
    }

    func run() -> Bool {
        began = ProcessInfo.processInfo.systemUptime
        deadline = began + 30
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.screenChangeNotifications += 1
                self.refreshScreenOrStop()
            }
        let heartbeat = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshScreenOrStop()
            self.session.tick(now: ProcessInfo.processInfo.systemUptime)
        }
        let maximumTimer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deadlineReached = true
            self.patch?.close(); self.patch = nil
            self.session.stop(reason: "Thirty-second telemetry audit deadline")
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        RunLoop.main.add(maximumTimer, forMode: .common)
        defer {
            patch?.close(); patch = nil
            heartbeat.invalidate(); maximumTimer.invalidate()
            NotificationCenter.default.removeObserver(observer)
            UserDefaults.standard.removeObject(forKey: "boost.\(baseline.identity.uuid)")
        }
        do {
            try require(session.state == .off && session.supportsBoost && session.maximumFactor >= 1.2,
                "The production carrier trial needs supported boost through 1.2.")
            try require(nativeUnchanged, "Native brightness changed before the audit.")
            try require(try gammaDifference() == 0, "Transfer tables changed before the audit.")
            try sample("baseline", requestedFactor: nil, metalValue: nil)

            session.setLevel(1.1)
            session.start()
            try wait("production carrier at factor 1.1", timeout: 10) { self.matchesGamma(factor: 1.1) }
            try settle(2)
            try require(matchesGamma(factor: 1.1), "Production factor 1.1 did not remain applied.")
            try sample("production-carrier-1.1-settled", requestedFactor: 1.1, metalValue: nil)

            session.setLevel(1.2)
            try wait("production carrier at factor 1.2", timeout: 3) { self.matchesGamma(factor: 1.2) }
            try settle(2)
            try require(matchesGamma(factor: 1.2), "Production factor 1.2 did not remain applied.")
            try sample("production-carrier-1.2-settled", requestedFactor: 1.2, metalValue: nil)

            session.stop(reason: "Production carrier telemetry collected")
            try wait("production session restoration", timeout: 6) { !self.session.busy }
            try require(session.state == .off && (try gammaDifference()) == 0,
                "Production session did not restore the exact original tables.")
            try settle(1)
            try sample("restored-after-production", requestedFactor: nil, metalValue: nil)

            // These are the existing lab's visible 4x4-point static corner
            // patches. There are no gamma writes or playback in this phase.
            for value in [1.2, 4.0] {
                guard deadline - ProcessInfo.processInfo.systemUptime >= 6 else {
                    skipped.append("metal-\(value): insufficient time before active deadline")
                    continue
                }
                try require(try gammaDifference() == 0, "Metal phase requires original tables.")
                let activePatch = try EDRPatch(screen: session.screen)
                patch = activePatch
                var rendered: Result<Void, Error>?
                activePatch.render(value: value) { rendered = $0 }
                try wait("static Metal frame", timeout: 4) { rendered != nil }
                try rendered!.get()
                try settle(2)
                try sample("metal-\(value)-settled", requestedFactor: nil, metalValue: value)
                checks["metal-\(value)-gammaUnchanged"] = try gammaDifference() == 0
                checks["metal-\(value)-renderedOneFrame"] = activePatch.frameCount == 1
                activePatch.close(); patch = nil
                try settle(0.5)
                try sample("restored-after-metal-\(value)", requestedFactor: nil, metalValue: nil)
            }
        } catch {
            resultError = error.localizedDescription
        }

        // Stop every surface and session on success, any failed precondition,
        // and timeout. Watchdog remains outside this process for crash recovery.
        patch?.close(); patch = nil
        session.stop(reason: "Telemetry audit final restoration")
        let restorationDeadline = ProcessInfo.processInfo.systemUptime + 8
        while session.busy && ProcessInfo.processInfo.systemUptime < restorationDeadline { pump(0.02) }
        var restorationDifference: Float?
        var journalCount: Int?
        do {
            restorationDifference = try gammaDifference()
            journalCount = try RecoveryStore(directory: session.directory).journalURLs().count
            checks["sessionStopped"] = !session.busy
            checks["exactOriginalGammaRestored"] = restorationDifference == 0
            checks["nativeBrightnessUnchanged"] = nativeUnchanged
            checks["noRecoveryJournals"] = journalCount == 0
            checks["activeDeadlineNotExceeded"] = !deadlineReached
            checks["displayRefreshNeverFailed"] = !displayRefreshFailed
            try sample("final-restored", requestedFactor: nil, metalValue: nil)
        } catch {
            resultError = [resultError, error.localizedDescription].compactMap { $0 }.joined(separator: " ")
        }
        let passed = resultError == nil && checks.count >= 5 && checks.values.allSatisfy { $0 }
        var report: [String: Any] = [
            "passed": passed, "checks": checks, "samples": samples, "skipped": skipped,
            "activeDeadlineSeconds": 30, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began,
            "nativeBrightnessWritesByHarness": 0, "physicalLuminanceMeasured": false,
            "appKitEventDispatchEnabled": true,
            "screenChangeNotifications": screenChangeNotifications,
            "nitsAccuracyAsserted": false, "telemetryIsDiagnosticOnly": true,
            "gammaRestorationMaximumDifference": restorationDifference as Any? ?? NSNull(),
            "remainingJournals": journalCount as Any? ?? NSNull()
        ]
        if let resultError { report["error"] = resultError }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let url = directory.appendingPathComponent("boost-telemetry-audit-result.json")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            print(String(decoding: data, as: UTF8.self))
        } catch { return false }
        return passed
    }

    private var nativeUnchanged: Bool {
        guard let value = nativeReader.brightness(displayID: baseline.identity.displayID) else { return false }
        return abs(value - baseline.nativeBrightness) <= 0.0001
    }
    private func gammaDifference() throws -> Float {
        try GammaTable.read(display: baseline.identity.displayID).maxDifference(from: baseline.gamma)
    }
    private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw DisplayError.invalid(message) }
    }
    private func pump(_ seconds: TimeInterval) {
        let stop = Date().addingTimeInterval(seconds)
        while Date() < stop {
            // RunLoop alone services timers but does not dispatch AppKit's
            // queued screen-change events. Process actual application events
            // just as an NSApplication event loop does; none are synthesized.
            if let event = NSApp.nextEvent(matching: .any,
                until: min(stop, Date().addingTimeInterval(0.01)),
                inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
        }
    }
    private func refreshScreen() throws {
        guard let screen = NSScreen.screens.first(where: {
            screenID($0) == baseline.identity.displayID
        }) else {
            throw DisplayError.invalid("The recorded display disappeared during the audit.")
        }
        // Updating the object is sufficient here. Production updateScreen
        // also reloads stored control targets, which this isolated trial owns.
        session.screen = screen
    }
    private func refreshScreenOrStop() {
        guard !displayRefreshFailed else { return }
        do { try refreshScreen() }
        catch {
            displayRefreshFailed = true
            resultError = error.localizedDescription
            patch?.close(); patch = nil
            session.stop(reason: "Audit display refresh failed")
        }
    }
    private func settle(_ seconds: Double) throws {
        try require(deadline - ProcessInfo.processInfo.systemUptime >= seconds, "Insufficient time to settle before active deadline.")
        pump(seconds)
        try require(!deadlineReached && !displayRefreshFailed && nativeUnchanged,
            "Deadline reached, display disappeared, or native brightness changed while settling.")
    }
    private func wait(_ description: String, timeout: Double, until condition: () -> Bool) throws {
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + timeout)
        while !condition() && ProcessInfo.processInfo.systemUptime < until && !deadlineReached && !displayRefreshFailed { pump(0.02) }
        try require(!deadlineReached && !displayRefreshFailed && condition(), "Timed out waiting for \(description).")
    }
    private func matchesGamma(factor: Double) -> Bool {
        guard session.state == .on,
              let actual = try? GammaTable.read(display: baseline.identity.displayID),
              let expected = try? baseline.gamma.scaled(factor: Float(factor)),
              let clamped = try? GammaTable(red: expected.red.map { min(1, $0) },
                  green: expected.green.map { min(1, $0) }, blue: expected.blue.map { min(1, $0) }) else { return false }
        return min(actual.maxDifference(from: expected), actual.maxDifference(from: clamped)) <= 0.0005
    }
    private func sample(_ name: String, requestedFactor: Double?, metalValue: Double?) throws {
        try refreshScreen()
        let table = try GammaTable.read(display: baseline.identity.displayID)
        let native = luminanceReader.reading(displayID: baseline.identity.displayID)
        var row: [String: Any] = [
            "name": name, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began,
            "coreBrightness": CoreBrightnessAuditReader.read(displayID: baseline.identity.displayID),
            "nativeBrightness": nativeReader.brightness(displayID: baseline.identity.displayID) as Any? ?? NSNull(),
            "systemSDRReferenceNits": native?.referenceNits as Any? ?? NSNull(),
            "presetHDRMaximumNits": native?.maximumHDRNits as Any? ?? NSNull(),
            "currentEDRHeadroom": Double(session.screen.maximumExtendedDynamicRangeColorComponentValue),
            "potentialEDRHeadroom": Double(session.screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
            "gammaMaximum": table.maximum,
            "gammaDifferenceFromBaseline": table.maxDifference(from: baseline.gamma)
        ]
        // This is the production adapter's raw diagnostic field, separately
        // named so it cannot be mistaken for NSScreen's current EDR capability.
        if let telemetry = native?.systemTelemetry,
           telemetry.reportedHeadroom.isFinite, telemetry.reportedHeadroom >= 0 {
            row["productionAdapterReportedHeadroom"] = telemetry.reportedHeadroom
        }
        if let requestedFactor { row["verifiedGammaFactor"] = requestedFactor }
        if let metalValue { row["metalLinearPixelValue"] = metalValue }
        var graySamples = [[String: Any]]()
        for fraction in [0.5, 0.9, 1.0] {
            let index = Int((Double(table.count - 1) * fraction).rounded())
            graySamples.append(["inputFraction": fraction,
                "red": table.red[index], "green": table.green[index], "blue": table.blue[index]])
        }
        row["gammaSamples"] = graySamples
        samples.append(row)
    }
}
