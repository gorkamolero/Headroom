import AppKit
import ApplicationServices
import DisplayCore

/// One owner for the complete brightness gesture. Supported key events never
/// reach macOS's native brightness handler, so only Headroom presents an OSD.
final class BrightnessKeyController {
    private struct Snapshot {
        let session: BoostSession
        var state: BrightnessBoostState
        var factor: Double
        let ceiling: Double
        var normal: Double?
        let available: Bool
        let dimmingAvailable: Bool
        let nativeAvailable: Bool
        var mode: BrightnessAdjustmentMode
        let time: TimeInterval
    }
    private struct NativeWrite {
        let session: BoostSession
        let value: Double
        let deadline: TimeInterval
    }
    private struct KeyOwnership {
        let normal: Double
        let mode: BrightnessAdjustmentMode
    }
    private enum BoundaryArrival {
        case native(BoostSession, Double)
        case restoration(BoostSession)
    }

    private let sessions: () -> [BoostSession]
    private let reader: any NormalBrightnessControlling
    private let accessibility: () -> Bool
    private let installEventTap: Bool
    private let tap = BrightnessKeyTap()
    private let hud = BrightnessHUD()
    private var timer: Timer?
    private var drainTimer: Timer?
    private var awaitingNative: NativeWrite?
    private var snapshot: Snapshot?
    private var sequence = BrightnessKeySequence()
    private var boundaryPause = BrightnessBoundaryPause()
    private var boundaryArrival: BoundaryArrival?
    private var pending: [(BoostSession, BrightnessKeyAction)] = []
    private var generation = 0
    private var flushing = false
    private var monitoring = false
    private var tapRunning = false
    private var suspended = false
    private var keyOwned: [String: KeyOwnership] = [:]
    private var nativeFailures: [String: String] = [:]
    private var lastPermissionCheck = -Double.infinity
    private var trusted = false
    private var conflict = false
    private var nextTapAttempt = 0.0
    var changed: (() -> Void)?
    private(set) var message = ""
    var permissionRequired: Bool { !trusted }
    var isIdle: Bool { pending.isEmpty && awaitingNative == nil && !flushing }
    var hudPresentation: BrightnessHUDPresentation? { hud.presentation }

    // Dependency injection lets integration tests run this exact controller and
    // real display driver without posting synthetic events to other apps.
    init(reader: any NormalBrightnessControlling = NormalBrightnessReader(),
         accessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
         installEventTap: Bool = true,
         sessions: @escaping () -> [BoostSession]) {
        self.reader = reader
        self.accessibility = accessibility
        self.installEventTap = installEventTap
        self.sessions = sessions
        tap.handler = { [weak self] event in self?.handle(event) ?? false }
        tap.interrupted = { [weak self] in
            guard let self else { return }
            self.tap.stop(); self.tapRunning = false
            self.cancelPending()
            self.restoreKeySessions(reason: "Brightness keys paused")
            self.nextTapAttempt = ProcessInfo.processInfo.systemUptime + 1
        }
    }

    func startMonitoring(requestPermission: Bool = true) {
        guard timer == nil else { return }
        monitoring = true
        suspended = false
        if requestPermission, !UserDefaults.standard.bool(forKey: "accessibilityPromptShown") {
            requestPermissionIfNeeded()
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func requestPermissionIfNeeded() {
        UserDefaults.standard.set(true, forKey: "accessibilityPromptShown")
        trusted = accessibility()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        lastPermissionCheck = -Double.infinity
    }

    func openAccessibilitySettings() {
        requestPermissionIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func suspend() {
        suspended = true
        cancelPending()
        tap.stop(); tapRunning = false
    }

    func resume() {
        suspended = false
        cancelPending()
        refresh()
    }

    func shutdown() {
        monitoring = false
        suspended = true
        timer?.invalidate(); timer = nil
        tap.stop(); tapRunning = false
        cancelPending()
    }

    func cancelPending() {
        generation += 1
        pending.removeAll()
        awaitingNative = nil
        drainTimer?.invalidate(); drainTimer = nil
        sequence.reset()
        boundaryPause.reset()
        boundaryArrival = nil
        snapshot = nil
        hud.hide()
    }

    private func setMessage(_ value: String) {
        guard value != message else { return }
        message = value
        changed?()
    }

    private func target() -> BoostSession? {
        let online = sessions().filter { CGDisplayIsOnline(screenID($0.screen)) != 0 }
        return online.first { CGDisplayIsBuiltin(screenID($0.screen)) != 0 }
            ?? online.first { screenID($0.screen) == CGMainDisplayID() }
    }

    private func restoreKeySessions(reason: String) {
        let owned = Set(keyOwned.keys)
        keyOwned.removeAll()
        for session in sessions() where owned.contains(session.uuid) && session.busy {
            session.stop(reason: reason)
        }
    }

    func refresh() {
        guard monitoring, !suspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPermissionCheck >= 1 {
            lastPermissionCheck = now
            trusted = accessibility()
            conflict = !NSRunningApplication.runningApplications(withBundleIdentifier: "fyi.lunar.Lunar").isEmpty
        }
        guard trusted, !conflict else {
            if tapRunning || !isIdle {
                tap.stop(); tapRunning = false; cancelPending()
            }
            restoreKeySessions(reason: "Brightness keys paused")
            snapshot = nil
            setMessage(conflict ? "Paused while Lunar is running" : "Allow Headroom in Accessibility…")
            return
        }
        if !tapRunning && now >= nextTapAttempt {
            tapRunning = !installEventTap || tap.start()
            nextTapAttempt = now + 2
        }
        guard tapRunning else { setMessage("Brightness keys unavailable — retrying…"); return }
        // Queued actions have already projected the desired state. Do not
        // replace it with a display read from the middle of a hardware write.
        guard isIdle else { return }
        guard let session = target() else { snapshot = nil; setMessage("No display for brightness keys"); return }
        let normal = reader.brightness(displayID: screenID(session.screen))
        let mode: BrightnessAdjustmentMode = session.isDimming ? .dim : .boost
        if let ownership = keyOwned[session.uuid], session.enabled {
            if ownership.mode != mode {
                keyOwned.removeValue(forKey: session.uuid)
            } else if normal == nil || abs(normal! - ownership.normal) > 0.005 {
                keyOwned.removeValue(forKey: session.uuid)
                cancelPending()
                session.stop(reason: "Paused after system brightness changed")
            }
        }
        if !session.busy { keyOwned.removeValue(forKey: session.uuid) }
        let nativeAvailable = reader.canSetBrightness && normal != nil
            && nativeFailures[session.uuid] == nil && CGDisplayIsInMirrorSet(screenID(session.screen)) == 0
        let state: BrightnessBoostState
        switch session.state {
        case .off: state = .off
        case .preparing: state = .preparing
        case .on: state = .on
        case .stopping: state = .stopping
        case .unavailable: state = .unavailable
        }
        if case .restoration(let arrivingSession) = boundaryArrival,
           arrivingSession === session, !session.busy {
            if state == .off { boundaryPause.reachedBoundary(now: now) }
            else { boundaryPause.reset() }
            boundaryArrival = nil
        }
        if let previous = snapshot, previous.state == .on || previous.state == .preparing,
           !session.enabled, state != .stopping { hud.hide() }
        let ceiling = state == .on && mode == .boost
            ? min(session.maximumFactor, Double(session.screen.maximumExtendedDynamicRangeColorComponentValue))
            : session.maximumFactor
        snapshot = Snapshot(session: session, state: state, factor: session.enabled ? session.desiredFactor : 1,
                            ceiling: ceiling, normal: normal, available: session.supportsBoost,
                            dimmingAvailable: session.supportsDimming, nativeAvailable: nativeAvailable,
                            mode: mode, time: now)
        setMessage(nativeFailures[session.uuid] ?? (nativeAvailable ? "" : "Brightness keys unavailable on this display"))
    }

    // Internal for the production-controller integration harness. This does not
    // generate system events or install an event tap without macOS permission.
    func handle(_ event: BrightnessKeyEvent) -> Bool {
        let pausing = boundaryPause.shouldPause(event: event, now: ProcessInfo.processInfo.systemUptime)
        if boundaryPause.armedDirection == nil { boundaryArrival = nil }
        if event.phase == .up {
            return sequence.route(event: event, state: .off, factor: 1, ceiling: 1,
                                  normalBrightness: nil, available: false, nativeAvailable: false) != .passthrough
        }
        guard monitoring, !suspended, trusted, !conflict, var current = snapshot,
              !isIdle || ProcessInfo.processInfo.systemUptime - current.time < 0.75 else {
            RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.refresh() }
            // Cancellation deliberately clears the cached state. Consult the
            // real session before allowing native changes during restoration.
            let fallback: BrightnessBoostState = target()?.busy == true ? .stopping : .unavailable
            return sequence.route(event: event, state: fallback, factor: 1, ceiling: 1,
                                  normalBrightness: nil, available: false, nativeAvailable: false) != .passthrough
        }
        if !current.nativeAvailable, current.session.busy, !event.hasUnsupportedModifiers {
            // Native fallback must not run on top of a menu-owned gamma
            // session. Restore on key input, preserving independent menu use
            // on displays that never supported the native brightness adapter.
            current.state = .stopping
            snapshot = current
            let epoch = generation
            RunLoop.main.perform(inModes: [.common]) { [weak self, weak session = current.session] in
                guard let self, let session, self.generation == epoch else { return }
                if session.enabled { session.stop(reason: "Paused before native brightness control") }
                self.refresh()
            }
        }
        // Route through the gesture owner even while paused so the matching
        // release remains consumed and macOS cannot show a second indicator.
        let action = sequence.route(event: event, state: pausing ? .stopping : current.state,
            factor: current.factor, ceiling: current.ceiling, normalBrightness: current.normal,
            available: current.available, dimmingAvailable: current.dimmingAvailable,
            mode: current.mode, nativeAvailable: current.nativeAvailable)
        if action == .passthrough { return false }
        switch action {
        case .setNative(let value):
            if (value == 1 && current.available && current.ceiling > 1.01 && (current.normal ?? 1) < 1)
                || (value == BrightnessKeyPolicy.hardwareFloor && current.dimmingAvailable
                    && (current.normal ?? 0) > BrightnessKeyPolicy.hardwareFloor) {
                boundaryPause.begin(direction: event.direction)
                boundaryArrival = .native(current.session, value)
            }
            current.normal = value; current.factor = 1
        case .start(let factor):
            current.state = .preparing; current.factor = factor
            current.mode = factor < 1 ? .dim : .boost
        case .set(let factor): current.factor = factor
        case .stop:
            boundaryPause.begin(direction: event.direction)
            boundaryArrival = .restoration(current.session)
            current.state = .stopping; current.factor = 1
        default: break
        }
        snapshot = current
        let epoch = generation
        if action == .consume {
            RunLoop.main.perform(inModes: [.common]) { [weak self, weak session = current.session] in
                guard let self, let session, epoch == self.generation else { return }
                self.showFeedback(session)
            }
            return true
        }
        // Coalesce absolute adjustments only within the same range. A start or
        // restoration boundary can never be reordered behind a hardware write.
        if let last = pending.last, last.0 === current.session {
            switch (last.1, action) {
            case (.setNative, .setNative), (.set, .set): pending.removeLast()
            default: break
            }
        }
        pending.append((current.session, action))
        guard pending.count <= 128 else {
            cancelPending()
            restoreKeySessions(reason: "Brightness keys paused")
            return true
        }
        RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.drain(epoch: epoch) }
        return true
    }

    private func scheduleDrain() {
        guard drainTimer == nil else { return }
        let epoch = generation
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.drain(epoch: epoch) }
        drainTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func failNative(_ session: BoostSession, _ reason: String) {
        nativeFailures[session.uuid] = reason
        cancelPending()
        restoreKeySessions(reason: reason)
        setMessage(reason)
    }

    private func drain(epoch: Int) {
        guard epoch == generation, monitoring, !suspended, trusted, !conflict, !flushing else { return }
        flushing = true
        defer {
            flushing = false
            if pending.isEmpty && awaitingNative == nil {
                drainTimer?.invalidate(); drainTimer = nil
                refresh()
            }
        }
        if let write = awaitingNative {
            guard target() === write.session, CGDisplayIsOnline(screenID(write.session.screen)) != 0 else {
                cancelPending(); return
            }
            let actual = reader.brightness(displayID: screenID(write.session.screen))
            // Range boundaries must satisfy the same tolerance as canStart.
            // A looser readback could end the wait before dimming/boost can begin.
            let tolerance = write.value == BrightnessKeyPolicy.hardwareFloor || write.value == 1
                ? 0.0001 : 0.002
            if let actual, abs(actual - write.value) <= tolerance {
                awaitingNative = nil
                if case .native(let session, let value) = boundaryArrival,
                   session === write.session, value == write.value {
                    boundaryPause.reachedBoundary(now: ProcessInfo.processInfo.systemUptime)
                    boundaryArrival = nil
                }
            } else if ProcessInfo.processInfo.systemUptime >= write.deadline {
                failNative(write.session, "Hardware brightness did not confirm the requested level")
                return
            } else { scheduleDrain(); return }
        }
        while !pending.isEmpty, epoch == generation {
            let (session, action) = pending.removeFirst()
            guard target() === session else { cancelPending(); return }
            switch action {
            case .setNative(let value):
                guard !session.busy else { cancelPending(); return }
                guard value.isFinite, value >= BrightnessKeyPolicy.hardwareFloor, value <= 1,
                      reader.setBrightness(value, displayID: screenID(session.screen)) else {
                    failNative(session, "Hardware brightness control is unavailable")
                    return
                }
                awaitingNative = NativeWrite(session: session, value: value,
                    deadline: ProcessInfo.processInfo.systemUptime + 0.8)
                showFeedback(session)
                scheduleDrain()
                return
            case .start(let factor):
                let mode: BrightnessAdjustmentMode = factor < 1 ? .dim : .boost
                let normal = reader.brightness(displayID: screenID(session.screen))
                guard !session.busy, session.state != .unavailable,
                      BrightnessKeyPolicy.canStart(mode: mode, normalBrightness: normal,
                        available: mode == .dim ? session.supportsDimming : session.supportsBoost,
                        ceiling: session.maximumFactor), let normal else {
                    cancelPending(); return
                }
                keyOwned[session.uuid] = KeyOwnership(normal: normal, mode: mode)
                session.setLevel(factor)
                session.start()
            case .set(let factor):
                guard session.enabled else { cancelPending(); return }
                if keyOwned[session.uuid] == nil {
                    guard let normal = reader.brightness(displayID: screenID(session.screen)) else {
                        session.stop(reason: "System brightness is unavailable")
                        cancelPending(); return
                    }
                    keyOwned[session.uuid] = KeyOwnership(normal: normal,
                        mode: session.isDimming ? .dim : .boost)
                }
                session.setLevel(factor)
            case .stop: session.stop(reason: "Off")
            default: break
            }
            showFeedback(session)
        }
    }

    private func showFeedback(_ session: BoostSession) {
        guard let current = snapshot, current.session === session, current.nativeAvailable else { return }
        let normal = current.normal ?? 0
        let factor = current.state == .on || current.state == .preparing ? current.factor : 1
        let nativeBottom = current.dimmingAvailable ? BrightnessHUDPresentation.lowerRangeBoundary : 0
        let nativeTop = current.available && current.ceiling > 1.01
            ? BrightnessHUDPresentation.upperRangeBoundary : 1.0
        let level: Double
        if factor < 1 {
            level = nativeBottom * (factor - session.minimumFactor) / (1 - session.minimumFactor)
        } else if factor > 1 {
            level = nativeTop + (1 - nativeTop) * (factor - 1) / max(0.01, current.ceiling - 1)
        } else if normal <= 0 { level = 0 }
        else {
            level = nativeBottom + (nativeTop - nativeBottom) * (normal - BrightnessKeyPolicy.hardwareFloor)
                / (1 - BrightnessKeyPolicy.hardwareFloor)
        }
        hud.show(screen: session.screen, presentation: BrightnessHUDPresentation(
            title: factor < 1 ? "Display −" : factor > 1 ? "Display +" : "Display",
            level: min(1, max(0, level)), lowerBoundary: nativeBottom > 0 ? nativeBottom : nil,
            upperBoundary: nativeTop < 1 ? nativeTop : nil))
    }
}
