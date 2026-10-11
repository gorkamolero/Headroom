import AppKit
import DisplayCore
import Darwin

struct TrialBaseline: Codable {
    let identity: DisplayIdentity
    let nativeBrightness: Double
    let gamma: GammaTable
}

@main
struct UnifiedKeysHarness {
    static func main() {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let baselineURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        do {
            let baseline = try JSONDecoder().decode(TrialBaseline.self, from: Data(contentsOf: baselineURL))
            let runner = try Trial(baseline: baseline, directory: directory)
            try runner.run()
            exit(0)
        } catch {
            fputs("HARNESS FAILED: \(error.localizedDescription)\n", stderr)
            fflush(stderr)
            exit(1)
        }
    }
}

private final class RejectNextNativeWrite: NormalBrightnessControlling {
    let wrapped: NormalBrightnessReader
    private(set) var rejected = false
    init(_ wrapped: NormalBrightnessReader) { self.wrapped = wrapped }
    var canSetBrightness: Bool { wrapped.canSetBrightness }
    func brightness(displayID: UInt32) -> Double? { wrapped.brightness(displayID: displayID) }
    func setBrightness(_ value: Double, displayID: UInt32) -> Bool {
        if !rejected { rejected = true; return false }
        return wrapped.setBrightness(value, displayID: displayID)
    }
}

private final class UnavailableNativeWriter: NormalBrightnessControlling {
    let wrapped: NormalBrightnessReader
    init(_ wrapped: NormalBrightnessReader) { self.wrapped = wrapped }
    var canSetBrightness: Bool { false }
    func brightness(displayID: UInt32) -> Double? { wrapped.brightness(displayID: displayID) }
    func setBrightness(_ value: Double, displayID: UInt32) -> Bool { false }
}

private final class Trial {
    let baseline: TrialBaseline
    let directory: URL
    let reader = NormalBrightnessReader()
    let session: BoostSession
    var controller: BrightnessKeyController!
    var heartbeat: Timer?
    var events = [[String: Any]]()
    var checks = [[String: Any]]()
    var sawHUD = false
    var screenObserver: NSObjectProtocol?
    var screenNotificationCount = 0
    var genuineConfigurationChanges = 0
    private struct DisplayConfiguration: Equatable {
        let identity: DisplayIdentity
        let frame: NSRect
        let scale: CGFloat
        let mirroredDisplay: UInt32
        let inMirrorSet: Bool
        let isMain: Bool
    }
    private var displayConfigurations = [String: DisplayConfiguration]()

    private func captureConfigurations() -> [String: DisplayConfiguration] {
        NSScreen.screens.reduce(into: [:]) { result, screen in
            guard let identity = try? DisplayIdentity.capture(display: screenID(screen)) else { return }
            result[identity.uuid] = DisplayConfiguration(identity: identity, frame: screen.frame,
                scale: screen.backingScaleFactor, mirroredDisplay: CGDisplayMirrorsDisplay(identity.displayID),
                inMirrorSet: CGDisplayIsInMirrorSet(identity.displayID) != 0,
                isMain: identity.displayID == CGMainDisplayID())
        }
    }

    init(baseline: TrialBaseline, directory: URL) throws {
        self.baseline = baseline
        self.directory = directory
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        guard let screen = NSScreen.screens.first(where: { screenID($0) == baseline.identity.displayID }) else {
            throw DisplayError.invalid("Recorded display is unavailable.")
        }
        session = BoostSession(screen: screen, identity: baseline.identity,
                               directory: directory.appendingPathComponent("Recovery", isDirectory: true))
        controller = BrightnessKeyController(reader: reader, accessibility: { true }, installEventTap: false,
                                             sessions: { [weak self] in self.map { [$0.session] } ?? [] })
        session.changed = { [weak self] in self?.controller.refresh() }
        heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.session.tick(now: ProcessInfo.processInfo.systemUptime)
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        controller.startMonitoring(requestPermission: false)
        displayConfigurations = captureConfigurations()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.screenNotificationCount += 1
            // Mirror the application delegate: harmless EDR/brightness
            // notifications preserve a gesture; actual configuration changes
            // cancel pending work and restore an affected table session.
            let incoming = self.captureConfigurations()
            if incoming != self.displayConfigurations {
                self.genuineConfigurationChanges += 1
                self.controller.cancelPending()
                if self.session.busy, incoming[self.session.uuid] != self.displayConfigurations[self.session.uuid] {
                    self.session.stop(reason: "Display settings changed")
                }
            }
            self.displayConfigurations = incoming
            if let screen = NSScreen.screens.first(where: {
                (try? DisplayIdentity.capture(display: screenID($0)).uuid) == self.session.uuid
            }) {
                self.session.updateScreen(screen, reconnected: false)
            } else if self.session.busy {
                self.session.stop(reason: "Display disconnected")
            }
            self.controller.refresh()
            self.checks.append(["name": "screen-parameters-notification", "count": self.screenNotificationCount,
                                "genuineConfigurationChanges": self.genuineConfigurationChanges,
                                "native": self.nativeValue, "session": String(describing: self.session.state),
                                "factor": self.session.desiredFactor])
        }
    }

    func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw DisplayError.invalid(message) }
    }

    func wait(_ description: String, timeout: TimeInterval = 8, until condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { pump(0.02) }
        try require(condition(), "Timed out waiting for \(description). State=\(session.state), factor=\(session.desiredFactor), native=\(String(describing: native)), message=\(controller.message)")
    }

    var native: Double? { reader.brightness(displayID: baseline.identity.displayID) }
    var nativeValue: Double { native ?? .nan }

    func emit(_ direction: BrightnessDirection, phase: BrightnessKeyPhase = .down,
              repeat isRepeat: Bool = false, fine: Bool = false, pumpAfter: Bool = true) throws {
        let consumed = controller.handle(BrightnessKeyEvent(direction: direction, phase: phase, isRepeat: isRepeat, fine: fine))
        events.append(["time": ProcessInfo.processInfo.systemUptime, "direction": direction == .up ? "up" : "down",
                       "phase": phase == .down ? "down" : "up", "repeat": isRepeat, "fine": fine,
                       "consumed": consumed, "native": nativeValue, "factor": session.desiredFactor,
                       "session": String(describing: session.state)])
        try require(consumed, "Managed brightness \(direction) \(phase) event passed through.")
        // The actual production panel must exist and be visible after managed input.
        if pumpAfter { pump(0.01) }
        sawHUD = sawHUD || NSApp.windows.contains { $0.title == "Headroom Brightness" && $0.isVisible }
    }

    func release(_ direction: BrightnessDirection) throws {
        try emit(direction, phase: .up)
        try wait("key queue to drain") { controller.isIdle }
    }

    func hold(_ direction: BrightnessDirection, maxEvents: Int = 40, until condition: () -> Bool) throws {
        for index in 0..<maxEvents {
            try emit(direction, repeat: index > 0)
            try wait("native write/action queue", timeout: 3) { controller.isIdle }
            if condition() { try release(direction); return }
            pump(0.025)
        }
        throw DisplayError.invalid("Held \(direction) did not reach expected state after \(maxEvents) events.")
    }

    func record(_ name: String) throws {
        let gamma = try GammaTable.read(display: baseline.identity.displayID)
        let entry: [String: Any] = ["name": name, "native": nativeValue, "factor": session.desiredFactor,
                                   "session": String(describing: session.state),
                                   "gammaDifferenceFromOriginal": gamma.maxDifference(from: baseline.gamma),
                                   "gammaMaximum": gamma.maximum,
                                   "hudVisible": NSApp.windows.contains { $0.title == "Headroom Brightness" && $0.isVisible }]
        checks.append(entry)
        print("CHECK \(name): \(entry)")
        fflush(stdout)
    }

    func setStartingNative(_ value: Double) throws {
        try require(!session.busy, "Cannot set trial start while a table session is active.")
        try require(reader.setBrightness(value, displayID: baseline.identity.displayID), "Failed to set trial starting brightness.")
        try wait("trial starting native brightness", timeout: 2) { abs(nativeValue - value) <= 0.002 }
        controller.refresh()
    }

    func run() throws {
        var failure: Error?
        do {
            try require(!session.busy, "A session was already active.")
            try require(session.supportsDimming, "Display does not support dimming.")
            try setStartingNative(0.15)
            try record("start-native-0.15")
            try hold(.down) { session.busy && session.desiredFactor <= 0.5 + 0.0001 }
            try wait("gamma dimming") { session.state == .on }
            pump(0.15)
            try require(nativeValue > 0 && nativeValue <= 0.012, "Dimming did not keep a lit native floor near0.01.")
            let dimReadback = try GammaTable.read(display: baseline.identity.displayID)
            let expectedDim = try baseline.gamma.scaled(factor: Float(session.desiredFactor))
            try require(dimReadback.maxDifference(from: expectedDim) <= 0.0005, "Dimming readback did not match immutable baseline scaling.")
            try record("held-down-to-gamma-half")

            try hold(.up) { !session.busy && nativeValue >= 0.15 }
            let afterDim = try GammaTable.read(display: baseline.identity.displayID)
            try require(afterDim.maxDifference(from: baseline.gamma) <= 0.0005, "Dimming did not restore gamma before native Up continued.")
            try record("held-up-restored-native-range")

            if session.supportsBoost {
                try hold(.up) { session.busy && !session.isDimming && session.desiredFactor >= 1.125 - 0.0001 }
                try wait("HDR boost activation", timeout: 12) { session.state == .on }
                pump(0.15)
                try require(nativeValue >= 0.998, "Boost changed hardware away from normal maximum.")
                try require(session.desiredFactor >= 1.125 - 0.0001, "Held Up did not enter boost.")
                try record("held-up-to-boost")
                try hold(.down) { !session.busy && nativeValue <= 0.85 }
                let afterBoost = try GammaTable.read(display: baseline.identity.displayID)
                try require(afterBoost.maxDifference(from: baseline.gamma) <= 0.0005,
                            "Boost did not restore gamma before native Down continued.")
                try record("held-down-restored-native-range")
            } else {
                checks.append(["name": "boost-unavailable", "skipped": true])
            }

            try setStartingNative(0.5)
            // Queue repeat events quickly, then release. Real queued writes must
            // complete once; release must not create a continuing repeat loop.
            for index in 0..<4 { try emit(.down, repeat: index > 0) }
            try release(.down)
            let afterBurst = nativeValue
            try require(afterBurst < 0.5 - 0.05 && afterBurst > 0.01, "Rapid Down burst was dropped or overran its range.")
            pump(0.3)
            try require(abs(nativeValue - afterBurst) <= 0.002, "Brightness kept changing after release.")
            try record("rapid-repeat-burst-stops-on-release")
            try require(sawHUD, "No production HUD window was observed visible after managed input.")

            try setStartingNative(0.5)
            for index in 0..<100 {
                let direction: BrightnessDirection = index.isMultiple(of: 2) ? .down : .up
                try emit(direction, pumpAfter: false)
                try emit(direction, phase: .up, pumpAfter: false)
            }
            try wait("100 alternating direction adjustments") { controller.isIdle }
            pump(0.1)
            try require(abs(nativeValue - 0.5) <= 0.002, "Rapid direction reversal did not finish at its initial native level.")
            let afterReversals = try GammaTable.read(display: baseline.identity.displayID)
            try require(afterReversals.maxDifference(from: baseline.gamma) <= 0.0005, "Rapid direction reversal changed gamma.")
            try record("100-alternating-directions-return-to-half")

            try emit(.down, pumpAfter: false)
            controller.cancelPending()
            pump(0.1)
            try require(abs(nativeValue - 0.5) <= 0.002, "Canceled queued native write was applied.")
            controller.refresh()
            try emit(.down, repeat: true)
            pump(0.25)
            try require(controller.isIdle && abs(nativeValue - 0.5) <= 0.002,
                        "Late repeat restarted a canceled brightness gesture.")
            try release(.down)
            let afterCancel = try GammaTable.read(display: baseline.identity.displayID)
            try require(afterCancel.maxDifference(from: baseline.gamma) <= 0.0005, "Canceled gesture changed gamma.")
            try record("canceled-queued-write-ignores-late-repeat")

            // Keep all real display components and inject exactly one failed
            // setter response to exercise controller fail-open behavior.
            controller.shutdown()
            let faultReader = RejectNextNativeWrite(reader)
            controller = BrightnessKeyController(reader: faultReader, accessibility: { true }, installEventTap: false,
                                                 sessions: { [weak self] in self.map { [$0.session] } ?? [] })
            controller.startMonitoring(requestPermission: false)
            let beforeRejectedWrite = nativeValue
            let rejectedPressConsumed = controller.handle(BrightnessKeyEvent(direction: .down, phase: .down))
            try require(rejectedPressConsumed, "Write-failure trigger was not consumed.")
            try wait("rejected native-write handling", timeout: 3) { faultReader.rejected && controller.isIdle }
            let rejectedReleaseConsumed = controller.handle(BrightnessKeyEvent(direction: .down, phase: .up))
            try require(!controller.message.isEmpty, "Rejected native write did not report unavailable control.")
            try require(abs(nativeValue - beforeRejectedWrite) <= 0.002, "Rejected native write changed brightness.")
            let afterFailure = try GammaTable.read(display: baseline.identity.displayID)
            try require(afterFailure.maxDifference(from: baseline.gamma) <= 0.0005, "Rejected native write changed gamma.")
            checks.append(["name": "native-setter-failure", "triggerConsumed": rejectedPressConsumed,
                           "releaseConsumed": rejectedReleaseConsumed, "queueIdle": controller.isIdle,
                           "message": controller.message, "nativeUnchanged": true, "gammaUnchanged": true])

            controller.shutdown()
            controller = BrightnessKeyController(reader: reader, accessibility: { true }, installEventTap: false,
                                                 sessions: { [weak self] in self.map { [$0.session] } ?? [] })
            controller.startMonitoring(requestPermission: false)
            session.setLevel(0.9)
            session.start()
            try wait("manual dimming before cleared-snapshot restoration") { session.state == .on }
            let beforeClearedSnapshot = nativeValue
            controller.cancelPending()
            session.stop(reason: "Trial cleared-snapshot restoration")
            let stoppingPressConsumed = controller.handle(BrightnessKeyEvent(direction: .down, phase: .down))
            try require(stoppingPressConsumed, "Cleared snapshot passed a key through while the real session was restoring.")
            try require(abs(nativeValue - beforeClearedSnapshot) <= 0.002, "Stopping fallback changed native brightness.")
            try wait("cleared-snapshot manual restoration") { !session.busy }
            let stoppingReleaseConsumed = controller.handle(BrightnessKeyEvent(direction: .down, phase: .up))
            try require(stoppingReleaseConsumed, "Stopping fallback lost ownership of its key release.")
            let afterStoppingFallback = try GammaTable.read(display: baseline.identity.displayID)
            try require(afterStoppingFallback.maxDifference(from: baseline.gamma) <= 0.0005, "Stopping fallback did not restore gamma.")
            checks.append(["name": "cleared-snapshot-during-restoration", "triggerConsumed": stoppingPressConsumed,
                           "releaseConsumed": stoppingReleaseConsumed, "nativeUnchanged": true, "gammaRestored": true])

            controller.shutdown()
            let unavailableReader = UnavailableNativeWriter(reader)
            controller = BrightnessKeyController(reader: unavailableReader, accessibility: { true }, installEventTap: false,
                                                 sessions: { [weak self] in self.map { [$0.session] } ?? [] })
            controller.startMonitoring(requestPermission: false)
            session.setLevel(0.9)
            session.start()
            try wait("manual dimming without a native setter") { session.state == .on }
            pump(0.35)
            try require(session.state == .on, "Unavailable native setter interrupted independent menu dimming before any key input.")
            let beforeUnavailableKey = nativeValue
            let unavailablePressConsumed = controller.handle(BrightnessKeyEvent(direction: .down, phase: .down))
            try require(unavailablePressConsumed, "Native fallback key passed through while menu dimming was active.")
            try wait("menu dimming restored before native fallback") { !session.busy }
            let unavailableReleaseConsumed = controller.handle(BrightnessKeyEvent(direction: .down, phase: .up))
            try require(unavailableReleaseConsumed, "Menu-dimming fallback lost its key release.")
            let freshFallbackConsumed = controller.handle(BrightnessKeyEvent(direction: .down, phase: .down))
            try require(!freshFallbackConsumed, "Fresh key did not fall back after menu dimming restored and setter stayed unavailable.")
            let freshFallbackReleaseConsumed = controller.handle(BrightnessKeyEvent(direction: .down, phase: .up))
            try require(!freshFallbackReleaseConsumed, "Fallback release was swallowed after its press passed through.")
            try require(abs(nativeValue - beforeUnavailableKey) <= 0.002, "Unavailable native setter changed hardware brightness.")
            let afterUnavailable = try GammaTable.read(display: baseline.identity.displayID)
            try require(afterUnavailable.maxDifference(from: baseline.gamma) <= 0.0005, "Unavailable-setter key did not restore original gamma.")
            checks.append(["name": "menu-dimming-before-native-fallback", "menuStayedOnUntilKey": true,
                           "triggerConsumed": unavailablePressConsumed, "releaseConsumed": unavailableReleaseConsumed,
                           "freshKeyPassedThrough": !freshFallbackConsumed,
                           "freshReleasePassedThrough": !freshFallbackReleaseConsumed,
                           "nativeUnchanged": true, "gammaRestored": true])
        } catch { failure = error }

        // In-process finally; the separate watchdog repeats restoration if this
        // process crashes, hangs, or exits before completing these operations.
        controller.shutdown()
        session.stop(reason: "Integration trial finished")
        do {
            try wait("session restoration", timeout: 8) { !session.busy }
            try require(reader.setBrightness(baseline.nativeBrightness, displayID: baseline.identity.displayID), "Native baseline restore failed.")
            try wait("native baseline restoration", timeout: 2) { abs(nativeValue - baseline.nativeBrightness) <= 0.002 }
            try record("restored-original-display")
        } catch { if failure == nil { failure = error } }
        heartbeat?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        let output: [String: Any] = ["passed": failure == nil, "error": failure?.localizedDescription as Any? ?? NSNull(),
                                     "allManagedEventsConsumed": events.allSatisfy { $0["consumed"] as? Bool == true },
                                     "productionHUDObservedVisible": sawHUD, "screenParameterNotificationCount": screenNotificationCount,
                                     "genuineConfigurationChangeCount": genuineConfigurationChanges,
                                     "events": events, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("harness-result.json"), options: .atomic)
        if let failure { throw failure }
    }
}
