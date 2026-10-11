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

    func hold(_ direction: BrightnessDirection, timeout: TimeInterval = 8, until condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var count = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try emit(direction, repeat: count > 0)
            count += 1
            try wait("native write/action queue", timeout: 3) { controller.isIdle }
            if condition() { try release(direction); return }
            pump(0.025)
        }
        throw DisplayError.invalid("Held \(direction) did not reach expected state within \(timeout) seconds (\(count) events).")
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

    /// Real-time hold: input arrival and display sampling run on independent
    /// timers. Never wait for isIdle between repeats; progress is measured before
    /// key-up so a change that appears only after release cannot pass.
    func timedHold(_ name: String, duration: TimeInterval, fine: Bool,
                   requiresNativeProgress: Bool, requiresGammaProgress: Bool,
                   direction: BrightnessDirection = .up, sampleInterval: TimeInterval = 0.05) throws -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        let initialNative = nativeValue
        let initialGamma = try GammaTable.read(display: baseline.identity.displayID)
        var samples = [[String: Any]]()
        var inputCount = 0
        var firstNativeChange: TimeInterval?
        var firstGammaChange: TimeInterval?
        var firstOn: TimeInterval?
        var timerFailure: Error?

        func sendHeldDown() {
            let now = ProcessInfo.processInfo.systemUptime
            let consumed = controller.handle(BrightnessKeyEvent(direction: direction, phase: .down,
                                                                isRepeat: inputCount > 0, fine: fine))
            let handlerDuration = ProcessInfo.processInfo.systemUptime - now
            events.append(["time": now, "trial": name, "direction": direction == .up ? "up" : "down", "phase": "down",
                           "handlerDuration": handlerDuration,
                           "repeat": inputCount > 0, "fine": fine, "consumed": consumed,
                           "native": nativeValue, "factor": session.desiredFactor,
                           "session": String(describing: session.state)])
            inputCount += 1
            if !consumed { timerFailure = DisplayError.invalid("Timed held-key event passed through in \(name).") }
        }
        func sample() {
            do {
                let now = ProcessInfo.processInfo.systemUptime
                let gamma = try GammaTable.read(display: baseline.identity.displayID)
                let currentNative = nativeValue
                let gammaDifference = gamma.maxDifference(from: initialGamma)
                if firstNativeChange == nil, abs(currentNative - initialNative) > 0.002 { firstNativeChange = now }
                if firstGammaChange == nil, gammaDifference > 0.0005 { firstGammaChange = now }
                if firstOn == nil, session.state == .on { firstOn = now }
                let presentation = controller.hudPresentation
                samples.append(["time": now, "sinceStart": now - start, "keyStillHeld": true,
                                "hudTitle": presentation?.title as Any? ?? NSNull(),
                                "hudLevel": presentation?.level as Any? ?? NSNull(),
                                "lowerBoundary": presentation?.lowerBoundary as Any? ?? NSNull(),
                                "upperBoundary": presentation?.upperBoundary as Any? ?? NSNull(),
                                "native": currentNative, "gammaDifferenceFromHoldStart": gammaDifference,
                                "gammaMaximum": gamma.maximum, "factor": session.desiredFactor,
                                "session": String(describing: session.state), "queueIdle": controller.isIdle,
                                "inputCount": inputCount])
                sawHUD = sawHUD || NSApp.windows.contains { $0.title == "Headroom Brightness" && $0.isVisible }
            } catch { timerFailure = error }
        }

        sample()
        sendHeldDown()
        let inputTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in sendHeldDown() }
        let sampleTimer = Timer(timeInterval: sampleInterval, repeats: true) { _ in sample() }
        RunLoop.main.add(inputTimer, forMode: .common)
        RunLoop.main.add(sampleTimer, forMode: .common)
        while ProcessInfo.processInfo.systemUptime < start + duration && timerFailure == nil { pump(0.01) }
        inputTimer.invalidate()
        sampleTimer.invalidate()
        sample() // Last actual read occurs while the key is still logically held.
        let nativeBeforeKeyUp = nativeValue
        let gammaBeforeKeyUp = try? GammaTable.read(display: baseline.identity.displayID)
        let stateBeforeKeyUp = String(describing: session.state)
        let factorBeforeKeyUp = session.desiredFactor
        let keyUpAt = ProcessInfo.processInfo.systemUptime
        let releaseConsumed = controller.handle(BrightnessKeyEvent(direction: direction, phase: .up, fine: fine))
        events.append(["time": keyUpAt, "trial": name, "direction": direction == .up ? "up" : "down", "phase": "up",
                       "repeat": false, "fine": fine, "consumed": releaseConsumed,
                       "native": nativeBeforeKeyUp, "factor": factorBeforeKeyUp,
                       "session": stateBeforeKeyUp])
        pump(0.3)
        let nativeAfterRelease = nativeValue
        let gammaAfterRelease = try? GammaTable.read(display: baseline.identity.displayID)
        let nativePassed = !requiresNativeProgress || firstNativeChange.map { $0 < keyUpAt } == true
        let gammaPassed = !requiresGammaProgress || (firstGammaChange.map { $0 < keyUpAt } == true && stateBeforeKeyUp == "on")
        let passed = timerFailure == nil && releaseConsumed && nativePassed && gammaPassed && inputCount >= Int(duration * 20)
        let result: [String: Any] = [
            "name": name, "passed": passed, "requestedFrequencyHz": 30,
            "holdStartedAt": start, "keyUpAt": keyUpAt, "actualHoldDuration": keyUpAt - start,
            "inputCount": inputCount, "releaseConsumed": releaseConsumed,
            "firstNativeChangeAt": firstNativeChange as Any? ?? NSNull(),
            "firstGammaChangeAt": firstGammaChange as Any? ?? NSNull(),
            "firstOnAt": firstOn as Any? ?? NSNull(),
            "nativeBeforeHold": initialNative, "nativeBeforeKeyUp": nativeBeforeKeyUp,
            "nativeAfterRelease": nativeAfterRelease,
            "gammaDifferenceBeforeKeyUp": gammaBeforeKeyUp.map { $0.maxDifference(from: initialGamma) } as Any? ?? NSNull(),
            "gammaDifferenceAfterRelease": gammaAfterRelease.map { $0.maxDifference(from: initialGamma) } as Any? ?? NSNull(),
            "factorBeforeKeyUp": factorBeforeKeyUp, "stateBeforeKeyUp": stateBeforeKeyUp,
            "requiresNativeProgress": requiresNativeProgress, "requiresGammaProgress": requiresGammaProgress,
            "error": timerFailure?.localizedDescription as Any? ?? NSNull(), "samplesBeforeRelease": samples
        ]
        checks.append(result)
        print("TIMED HOLD \(name): passed=\(passed), inputCount=\(inputCount), nativeBeforeKeyUp=\(nativeBeforeKeyUp), stateBeforeKeyUp=\(stateBeforeKeyUp)")
        fflush(stdout)
        return passed
    }

    func boundaryHold(_ name: String, direction: BrightnessDirection, enteringSoftware: Bool,
                      nativeEndpoint: Double, finalTitle: String) throws {
        let passed = try timedHold(name, duration: 1.05, fine: true,
                                   requiresNativeProgress: !enteringSoftware,
                                   requiresGammaProgress: enteringSoftware,
                                   direction: direction, sampleInterval: 0.02)
        guard let result = checks.last,
              let samples = result["samplesBeforeRelease"] as? [[String: Any]] else {
            throw DisplayError.invalid("Boundary hold did not return samples.")
        }
        let firstBoundaryTime: Double?
        let nextRangeTime: Double?
        if enteringSoftware {
            firstBoundaryTime = samples.first(where: {
                guard let value = $0["native"] as? Double else { return false }
                return abs(value - nativeEndpoint) <= 0.0001
            })?["time"] as? Double
            nextRangeTime = result["firstGammaChangeAt"] as? Double
        } else {
            firstBoundaryTime = result["firstGammaChangeAt"] as? Double
            nextRangeTime = result["firstNativeChangeAt"] as? Double
        }
        let trialEvents = events.filter { $0["trial"] as? String == name && $0["phase"] as? String == "down" }
        let repeatCount = trialEvents.filter {
            guard let time = $0["time"] as? Double, let from = firstBoundaryTime, let to = nextRangeTime else { return false }
            return $0["repeat"] as? Bool == true && time >= from && time < to
        }.count
        let longestHandler = trialEvents.compactMap { $0["handlerDuration"] as? Double }.max() ?? .infinity
        let measuredPause = firstBoundaryTime.flatMap { from in nextRangeTime.map { $0 - from } }
        let finalPresentation = controller.hudPresentation
        // The 350ms pure gate has exact clock tests. Actual display sampling
        // resolves the plateau to 20 ms, with scheduling/readback tolerance.
        let pausePassed = measuredPause.map { $0 >= 0.30 } == true
        let labels = Set(samples.compactMap { $0["hudTitle"] as? String })
        let expectedUpper: Double? = session.supportsBoost ? 0.875 : nil
        let markersPassed = finalPresentation?.lowerBoundary == 0.125
            && finalPresentation?.upperBoundary == expectedUpper
        let labelPassed = labels.contains("Display") && finalPresentation?.title == finalTitle
        checks.append(["name": name + "-boundary-assertions", "pausePassed": pausePassed,
                       "measuredPauseSeconds": measuredPause as Any? ?? NSNull(),
                       "repeatEventsDuringPause": repeatCount, "longestHandlerSeconds": longestHandler,
                       "labelsSeen": labels.sorted(), "finalTitle": finalPresentation?.title as Any? ?? NSNull(),
                       "markersPassed": markersPassed, "labelPassed": labelPassed])
        try require(passed && pausePassed, "Held boundary did not preserve the expected pause before continuing: \(name).")
        try require(repeatCount >= 5 && longestHandler < 0.1, "Boundary pause blocked or starved repeated input: \(name).")
        try require(labelPassed && markersPassed, "Boundary HUD title or markers were incorrect: \(name).")
    }

    func restoreTablesForNextCase() throws {
        controller.cancelPending()
        session.stop(reason: "Timed hold trial boundary")
        try wait("table restoration between timed holds") { !session.busy }
        let gamma = try GammaTable.read(display: baseline.identity.displayID)
        try require(gamma.maxDifference(from: baseline.gamma) <= 0.0005, "Timed hold did not restore original tables.")
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

            var timedHoldFailures = [String]()
            try setStartingNative(0.5)
            if try !timedHold("30hz-native-up-progress-before-keyup", duration: 3, fine: false,
                              requiresNativeProgress: true, requiresGammaProgress: false) {
                timedHoldFailures.append("native range")
            }
            try restoreTablesForNextCase()
            if session.supportsBoost {
                try setStartingNative(1)
                if try !timedHold("30hz-short-cold-boost-progress-before-keyup", duration: 0.75, fine: true,
                                  requiresNativeProgress: false, requiresGammaProgress: true) {
                    timedHoldFailures.append("750ms cold boost")
                }
                try restoreTablesForNextCase()
                try setStartingNative(1)
                if try !timedHold("30hz-cold-boost-progress-before-keyup", duration: 4, fine: true,
                                  requiresNativeProgress: false, requiresGammaProgress: true) {
                    timedHoldFailures.append("cold boost")
                }
                try restoreTablesForNextCase()
                try setStartingNative(1)
                session.setLevel(1.1)
                session.start()
                try wait("active boost for timed fine-repeat trial", timeout: 12) { session.state == .on }
                pump(0.15)
                if try !timedHold("30hz-active-boost-progress-before-keyup", duration: 3, fine: true,
                                  requiresNativeProgress: false, requiresGammaProgress: true) {
                    timedHoldFailures.append("active boost")
                }
                try restoreTablesForNextCase()
            }
            try require(timedHoldFailures.isEmpty,
                        "Held Up had no required real display progress before key-up: \(timedHoldFailures.joined(separator: ", ")).")

            if session.supportsBoost {
                try setStartingNative(1 - 1.0 / 64)
                try boundaryHold("boundary-native-to-boost", direction: .up, enteringSoftware: true,
                                 nativeEndpoint: 1, finalTitle: "Display +")
                try restoreTablesForNextCase()
            }
            try setStartingNative(0.01 + 1.0 / 64)
            try boundaryHold("boundary-native-to-dim", direction: .down, enteringSoftware: true,
                             nativeEndpoint: 0.01, finalTitle: "Display −")
            try restoreTablesForNextCase()

            try setStartingNative(0.01)
            session.setLevel(1 - 1.0 / 64)
            session.start()
            try wait("manual dim for boundary return") { session.state == .on }
            pump(0.1)
            try boundaryHold("boundary-dim-to-native", direction: .up, enteringSoftware: false,
                             nativeEndpoint: 0.01, finalTitle: "Display")
            try restoreTablesForNextCase()
            if session.supportsBoost {
                try setStartingNative(1)
                session.setLevel(1 + 1.0 / 64)
                session.start()
                try wait("manual boost for boundary return", timeout: 12) { session.state == .on }
                pump(0.1)
                try boundaryHold("boundary-boost-to-native", direction: .down, enteringSoftware: false,
                                 nativeEndpoint: 1, finalTitle: "Display")
                try restoreTablesForNextCase()

                // A release followed by a new press crosses immediately; only
                // a continuous same-direction hold gets the deliberate pause.
                try setStartingNative(1 - 1.0 / 64)
                try emit(.up, fine: true)
                try wait("native ceiling for fresh-press bypass") { controller.isIdle && nativeValue >= 0.9999 }
                try release(.up)
                let freshPressAt = ProcessInfo.processInfo.systemUptime
                try emit(.up, fine: true)
                try wait("fresh press bypassing boundary pause", timeout: 0.25) { session.busy }
                checks.append(["name": "boundary-fresh-press-bypass", "startDelay": ProcessInfo.processInfo.systemUptime - freshPressAt])
                try release(.up)
                try restoreTablesForNextCase()

                try setStartingNative(1 - 1.0 / 64)
                try emit(.up, fine: true)
                try wait("native ceiling for reversal bypass") { controller.isIdle && nativeValue >= 0.9999 }
                let reverseAt = ProcessInfo.processInfo.systemUptime
                try emit(.down, fine: true)
                try wait("reverse direction bypassing boundary pause", timeout: 0.25) { nativeValue < 0.99 }
                checks.append(["name": "boundary-direction-reversal-bypass", "nativeDelay": ProcessInfo.processInfo.systemUptime - reverseAt])
                try release(.down)
                try release(.up)
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
