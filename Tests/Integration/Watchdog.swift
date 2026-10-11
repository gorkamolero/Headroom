import AppKit
import DisplayCore
import Darwin

struct TrialBaseline: Codable {
    let identity: DisplayIdentity
    let nativeBrightness: Double
    let gamma: GammaTable
}

private var watchdogSignal: Int32 = 0

@main
struct Watchdog {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: Watchdog harness-executable output-directory\n", stderr)
            exit(2)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let recovery = directory.appendingPathComponent("Recovery", isDirectory: true)
        let reader = NormalBrightnessReader()
        var result: [String: Any] = ["harness": executable.path, "startedAt": ISO8601DateFormatter().string(from: Date())]
        var baseline: TrialBaseline?
        let process = Process()
        var completed = false
        var restored = false
        signal(SIGINT) { watchdogSignal = $0 }
        signal(SIGTERM) { watchdogSignal = $0 }
        do {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.gorka.Headroom").isEmpty,
                  NSRunningApplication.runningApplications(withBundleIdentifier: "fyi.lunar.Lunar").isEmpty else {
                throw DisplayError.invalid("Quit Headroom and Lunar before the isolated live trial.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let display = CGMainDisplayID()
            let identity = try DisplayIdentity.capture(display: display)
            guard reader.canSetBrightness, let normal = reader.brightness(displayID: display) else {
                throw DisplayError.invalid("Native brightness read/write is unavailable.")
            }
            baseline = TrialBaseline(identity: identity, nativeBrightness: normal, gamma: try GammaTable.read(display: display))
            let baselineURL = directory.appendingPathComponent("baseline.json")
            try JSONEncoder().encode(baseline!).write(to: baselineURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: baselineURL.path)
            let log = directory.appendingPathComponent("harness.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: log)
            defer { try? logHandle.close() }
            process.executableURL = executable
            process.arguments = [baselineURL.path, directory.path]
            process.standardOutput = logHandle
            process.standardError = logHandle
            try process.run()
            result["harnessPID"] = process.processIdentifier
            let deadline = ProcessInfo.processInfo.systemUptime + 100
            while process.isRunning && watchdogSignal == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                result["watchdogStoppedHarness"] = true
                process.terminate()
                let killDeadline = ProcessInfo.processInfo.systemUptime + 3
                while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            result["harnessExitStatus"] = process.terminationStatus
            completed = process.terminationStatus == 0
        } catch {
            result["error"] = error.localizedDescription
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        // This process remains outside the harness. EOF wakes DisplayGuardian
        // even when the controller or AppKit run loop has stopped responding.
        if let baseline {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            var lastError = ""
            repeat {
                do {
                    let store = try RecoveryStore(directory: recovery)
                    let outcomes = store.recoverAll()
                    if outcomes.contains(where: { !$0.succeeded }) {
                        lastError = outcomes.map(\.message).joined(separator: " ")
                        Thread.sleep(forTimeInterval: 0.2)
                        continue
                    }
                    let lock = try store.acquireDisplayLock(uuid: baseline.identity.uuid)
                    defer { withExtendedLifetime(lock) {} }
                    let currentIdentity = try DisplayIdentity.capture(display: baseline.identity.displayID)
                    guard currentIdentity == baseline.identity else {
                        throw DisplayError.invalid("Display identity/configuration changed; saved values retained, not applied.")
                    }
                    var table = try GammaTable.read(display: baseline.identity.displayID)
                    if table.maxDifference(from: baseline.gamma) > 0.0005 {
                        try baseline.gamma.apply(display: baseline.identity.displayID)
                        result["watchdogAppliedGammaBaseline"] = true
                    }
                    guard reader.setBrightness(baseline.nativeBrightness, displayID: baseline.identity.displayID) else {
                        throw DisplayError.invalid("Restoring original native brightness failed.")
                    }
                    Thread.sleep(forTimeInterval: 0.35)
                    table = try GammaTable.read(display: baseline.identity.displayID)
                    let difference = table.maxDifference(from: baseline.gamma)
                    guard let currentNative = reader.brightness(displayID: baseline.identity.displayID) else {
                        throw DisplayError.invalid("Cannot verify native brightness restoration.")
                    }
                    result["gammaRestorationMaximumDifference"] = difference
                    result["nativeBefore"] = baseline.nativeBrightness
                    result["nativeAfter"] = currentNative
                    result["nativeRestorationDifference"] = abs(currentNative - baseline.nativeBrightness)
                    result["remainingJournals"] = try store.journalURLs().count
                    restored = difference <= 0.0005 && abs(currentNative - baseline.nativeBrightness) <= 0.002
                    if !restored { throw DisplayError.invalid("Restoration readback did not match the saved baseline.") }
                    break
                } catch {
                    lastError = error.localizedDescription
                    Thread.sleep(forTimeInterval: 0.2)
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
            if !restored { result["restorationError"] = lastError }
        }
        result["harnessPassed"] = completed
        result["restored"] = restored
        result["passed"] = completed && restored
        result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("watchdog-result.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        }
        exit(completed && restored ? 0 : 1)
    }
}
