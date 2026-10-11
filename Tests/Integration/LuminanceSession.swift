import AppKit
import DisplayCore
import DisplayActivation
import Darwin

/// This private baseline is created by the existing external Watchdog.
struct TrialBaseline: Codable {
    let identity: DisplayIdentity
    let nativeBrightness: Double
    let gamma: GammaTable
}

@main
enum LuminanceSessionHarness {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: LuminanceSession baseline-path output-directory\n", stderr)
            exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        do {
            let baseline = try JSONDecoder().decode(TrialBaseline.self, from:
                Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let trial = try LuminanceTrial(baseline: baseline, directory: directory)
            exit(trial.run() ? 0 : 1)
        } catch {
            // Do not print the saved display identity or original tables.
            fputs("Luminance trial could not start: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private final class LuminanceTrial {
    private let baseline: TrialBaseline
    private let directory: URL
    private let session: BoostSession
    private let nativeReader = NormalBrightnessReader()
    private let luminanceReader = DisplayLuminanceReader()
    private var checks = [String: Bool]()
    private var samples = [[String: Any]]()
    private var heartbeat: Timer?
    private var maximumTimer: Timer?
    private var deadline = Double.infinity
    private var deadlineReached = false
    private var resultError: String?

    init(baseline: TrialBaseline, directory: URL) throws {
        self.baseline = baseline
        self.directory = directory
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        guard let screen = NSScreen.screens.first(where: {
            screenID($0) == baseline.identity.displayID
        }), try DisplayIdentity.capture(display: baseline.identity.displayID) == baseline.identity else {
            throw DisplayError.invalid("Recorded display configuration is unavailable.")
        }
        session = BoostSession(screen: screen, identity: baseline.identity,
            directory: directory.appendingPathComponent("Recovery", isDirectory: true))
        // Production diagnostics include identifiers. Keep the watchdog log
        // private; the summary below deliberately contains no identifiers.
        let log = directory.appendingPathComponent("harness.log")
        if FileManager.default.fileExists(atPath: log.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        }
    }

    func run() -> Bool {
        deadline = ProcessInfo.processInfo.systemUptime + 20
        let heartbeat = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.session.tick(now: ProcessInfo.processInfo.systemUptime)
        }
        self.heartbeat = heartbeat
        RunLoop.main.add(heartbeat, forMode: .common)
        let maximumTimer = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            self?.deadlineReached = true
            self?.session.stop(reason: "Bounded luminance trial finished")
        }
        self.maximumTimer = maximumTimer
        RunLoop.main.add(maximumTimer, forMode: .common)
        defer {
            heartbeat.invalidate()
            maximumTimer.invalidate()
            UserDefaults.standard.removeObject(forKey: "boost.\(baseline.identity.uuid)")
        }

        do {
            try require(session.state == .off && session.supportsBoost && session.maximumFactor >= 1.2,
                        "This trial requires an available boost range through 1.2.")
            try require(nativeUnchanged, "Native brightness changed before the trial began.")
            try wait("asynchronous native reference", timeout: 2) { self.session.luminance.nits != nil }
            let initial = session.luminance
            try require(initial.nits != nil, "No usable system-derived native nits reference.")
            checks["nativeNitsAvailable"] = true

            session.setLevel(1.1)
            session.start()
            try require(session.state == .preparing && session.luminance.nits == nil,
                        "Preparing must show unavailable nits before acknowledgement.")
            checks["preparingNitsUnavailable"] = true
            try wait("first acknowledged boost", timeout: 10) { self.matchesAcknowledgedFactor(1.1) }
            try sample("acknowledged-1.1", factor: 1.1)
            let firstCapacity = session.luminance.availableHDRNits

            session.setLevel(1.2)
            // No run-loop work has occurred yet: this must still describe the
            // prior acknowledgement rather than the newly queued target.
            try require(session.luminance.nits == nil && session.luminance.availableHDRNits == firstCapacity,
                        "A queued target was misrepresented as current luminance.")
            checks["pendingTargetCannotInventCurrentNits"] = true
            try wait("second acknowledged boost", timeout: 3) { self.matchesAcknowledgedFactor(1.2) }
            try sample("acknowledged-1.2", factor: 1.2)
            try require(session.luminance.nits == nil && session.luminance.availableHDRNits != nil,
                        "An acknowledged boost must distinguish HDR capacity from current luminance.")
            checks["boostOnlyReportsCapacity"] = true
            checks["nativeBrightnessUnchangedDuringTrial"] = nativeUnchanged
            try require(nativeUnchanged, "The trial changed native brightness.")

            session.stop(reason: "Luminance trial complete")
            try require(session.state == .stopping && session.luminance.nits == nil,
                        "Stopping must show unavailable nits until restoration completes.")
            checks["stoppingNitsUnavailable"] = true
        } catch {
            resultError = error.localizedDescription
        }

        // Always restore, including failed preconditions and timeouts. The
        // independent Watchdog remains responsible if this process stalls.
        session.stop(reason: "Luminance trial restoration")
        let restorationDeadline = ProcessInfo.processInfo.systemUptime + 8
        while session.busy && ProcessInfo.processInfo.systemUptime < restorationDeadline {
            pump(0.02)
        }
        var restorationDifference: Float?
        var journals: Int?
        do {
            try require(!session.busy, "The session did not finish restoring before the deadline.")
            restorationDifference = try GammaTable.read(display: baseline.identity.displayID)
                .maxDifference(from: baseline.gamma)
            journals = try RecoveryStore(directory: session.directory).journalURLs().count
            checks["originalGammaRestoredExactly"] = restorationDifference == 0
            checks["noRecoveryJournals"] = journals == 0
            checks["nativeBrightnessRestored"] = nativeUnchanged
            checks["offNitsAvailableAfterRestoration"] = session.state == .off && session.luminance.nits != nil
            checks["completedWithinActiveDeadline"] = !deadlineReached
        } catch {
            resultError = [resultError, error.localizedDescription].compactMap { $0 }.joined(separator: " ")
        }
        let passed = resultError == nil && checks.count == 13 && checks.values.allSatisfy { $0 }
        var result: [String: Any] = [
            "passed": passed, "checks": checks, "samples": samples,
            "activeDeadlineSeconds": 20, "nativeBrightnessWritesByHarness": 0,
            "physicalLuminanceMeasured": false,
            "boostCurrentLuminanceClaimed": false,
            "gammaRestorationMaximumDifference": restorationDifference as Any? ?? NSNull(),
            "remainingJournals": journals as Any? ?? NSNull()
        ]
        if let resultError { result["error"] = resultError }
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("luminance-session-result.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Writing luminance trial result failed: \(error.localizedDescription)\n", stderr)
            return false
        }
        return passed
    }

    private var nativeUnchanged: Bool {
        guard let value = nativeReader.brightness(displayID: baseline.identity.displayID) else { return false }
        return abs(value - baseline.nativeBrightness) <= 0.0001
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw DisplayError.invalid(message) }
    }

    private func pump(_ seconds: TimeInterval) {
        let stop = Date().addingTimeInterval(seconds)
        while Date() < stop {
            _ = RunLoop.main.run(mode: .default, before: min(stop, Date().addingTimeInterval(0.01)))
        }
    }

    private func wait(_ description: String, timeout: Double, until condition: () -> Bool) throws {
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + timeout)
        while !condition() && ProcessInfo.processInfo.systemUptime < until && !deadlineReached {
            pump(0.02)
        }
        try require(!deadlineReached && condition(),
                    "Timed out waiting for \(description); session is \(session.state): \(session.detail)")
    }

    private func matchesAcknowledgedFactor(_ factor: Double) -> Bool {
        guard session.state == .on,
              Double(session.screen.maximumExtendedDynamicRangeColorComponentValue) >= factor,
              let actual = try? GammaTable.read(display: baseline.identity.displayID),
              let expected = try? baseline.gamma.scaled(factor: Float(factor)),
              let clamped = try? GammaTable(red: expected.red.map { min(1, $0) },
                green: expected.green.map { min(1, $0) }, blue: expected.blue.map { min(1, $0) }) else { return false }
        return min(actual.maxDifference(from: expected), actual.maxDifference(from: clamped)) <= 0.0005
            && session.luminance.nits == nil && session.luminance.availableHDRNits != nil
    }

    private func sample(_ name: String, factor: Double) throws {
        let estimate = session.luminance
        guard estimate.nits == nil, let capacity = estimate.availableHDRNits, let reference = estimate.referenceNits,
              let reading = luminanceReader.reading(displayID: baseline.identity.displayID),
              let maximumHDR = reading.maximumHDRNits else {
            throw DisplayError.invalid("An acknowledged boost did not produce a separately identified HDR capacity.")
        }
        let headroom = Double(NSScreen.screens.first { screenID($0) == baseline.identity.displayID }?
            .maximumExtendedDynamicRangeColorComponentValue ?? 0)
        let systemPeak = reading.systemTelemetry.map { $0.sdrNits * $0.availableHeadroom } ?? .infinity
        let ceiling = min(maximumHDR, reference * headroom, systemPeak)
        try require(abs(capacity - ceiling) <= 0.5,
                    "The reported HDR capacity does not match the system reading.")
        samples.append([
            "name": name, "acknowledgedFactor": factor, "availableHDRNits": capacity, "currentBoostedNits": NSNull(),
            "referenceNits": reference, "currentHeadroom": headroom,
            "presetMaximumHDRNits": maximumHDR, "currentCeilingNits": ceiling,
            "maximumControlFactor": session.maximumFactor, "displayText": estimate.text,
            "nativeBrightness": nativeReader.brightness(displayID: baseline.identity.displayID) as Any? ?? NSNull()
        ])
        checks["\(name)-withinCurrentBounds"] = true
    }
}
