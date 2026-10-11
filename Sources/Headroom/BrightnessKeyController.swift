import AppKit
import ApplicationServices
import DisplayCore

/// Owns the ranges beyond both hardware endpoints. Within the normal range
/// macOS receives the original media-key events and controls the backlight.
final class BrightnessKeyController {
    private struct Snapshot {
        let session: BoostSession
        var state: BrightnessBoostState
        var factor: Double
        let ceiling: Double
        let normal: Double?
        let available: Bool
        let dimmingAvailable: Bool
        var mode: BrightnessAdjustmentMode
        let time: TimeInterval
    }

    private struct KeyOwnership {
        let normal: Double
        let mode: BrightnessAdjustmentMode

        func mustRestore(after current: Double?) -> Bool {
            guard let current, current.isFinite, current >= 0, current <= 1.0001 else { return true }
            return mode == .dim ? current > normal + 0.002 : current < normal - 0.002
        }
    }

    private let sessions: () -> [BoostSession]
    private let tap = BrightnessKeyTap()
    private let reader = NormalBrightnessReader()
    private let hud = BrightnessHUD()
    private var timer: Timer?
    private var nativeDownRead: (uuid: String, before: Double, after: TimeInterval, expires: TimeInterval)?
    private var nativeDownReadTimer: Timer?
    private var snapshot: Snapshot?
    private var sequence = BrightnessKeySequence()
    private var pending: [(BoostSession, BrightnessKeyAction)] = []
    private var generation = 0
    private var flushing = false
    private var tapRunning = false
    private var suspended = false
    private var keyOwned: [String: KeyOwnership] = [:]
    private var lastPermissionCheck = -Double.infinity
    private var trusted = false
    private var conflict = false
    private var nextTapAttempt = 0.0
    var changed: (() -> Void)?
    private(set) var message = ""
    var isEnabled: Bool { true }
    var permissionRequired: Bool { isEnabled && !trusted }

    init(sessions: @escaping () -> [BoostSession]) {
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

    func startMonitoring() {
        guard timer == nil else { return }
        // Prompt once on first use. A rebuilt ad-hoc app can lose its old
        // approval; report that in the menu without nagging on every launch.
        if !UserDefaults.standard.bool(forKey: "accessibilityPromptShown") {
            requestPermissionIfNeeded()
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func requestPermissionIfNeeded() {
        UserDefaults.standard.set(true, forKey: "accessibilityPromptShown")
        trusted = AXIsProcessTrusted()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
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
        snapshot = nil
    }

    func resume() {
        suspended = false
        cancelPending()
        refresh()
    }

    func shutdown() {
        timer?.invalidate(); timer = nil
        tap.stop(); tapRunning = false
        cancelPending()
        snapshot = nil
    }

    func cancelPending() {
        generation += 1
        pending.removeAll()
        nativeDownRead = nil
        nativeDownReadTimer?.invalidate(); nativeDownReadTimer = nil
        sequence.reset()
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
        // Media keys have no display identifier. Preserve macOS's usual built-in
        // target; on desktop Macs use the primary display only.
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
        guard isEnabled, !suspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPermissionCheck >= 1 {
            lastPermissionCheck = now
            trusted = AXIsProcessTrusted()
            conflict = !NSRunningApplication.runningApplications(withBundleIdentifier: "fyi.lunar.Lunar").isEmpty
        }
        guard trusted, !conflict else {
            if tapRunning || !pending.isEmpty {
                tap.stop(); tapRunning = false; cancelPending()
            }
            restoreKeySessions(reason: "Brightness keys paused")
            snapshot = nil
            setMessage(conflict ? "Paused while Lunar is running" : "Allow Headroom in Accessibility…")
            return
        }
        if !tapRunning && now >= nextTapAttempt {
            tapRunning = tap.start()
            nextTapAttempt = now + 2
        }
        guard tapRunning else { setMessage("Brightness keys unavailable — retrying…"); return }
        // Preserve the projected state of queued key events until their actions
        // have drained outside the event tap callback.
        guard pending.isEmpty, !flushing else { return }
        guard let session = target() else { snapshot = nil; setMessage("No display for brightness keys"); return }
        let normal = reader.brightness(displayID: screenID(session.screen))
        if let awaiting = nativeDownRead {
            if awaiting.uuid != session.uuid || now >= awaiting.expires {
                // A missing/unchanged getter must not leave Down blocked if
                // macOS ignored the original key event.
                nativeDownRead = nil
            } else if now < awaiting.after || normal == nil || abs(normal! - awaiting.before) < 0.000_001 {
                // Do not forward another Down using the value from before the
                // previous native event. Up still passes through immediately.
                snapshot = nil
                return
            } else {
                nativeDownRead = nil
            }
        }
        let mode: BrightnessAdjustmentMode = session.isDimming ? .dim : .boost
        if let ownership = keyOwned[session.uuid], session.enabled {
            if ownership.mode != mode {
                // A menu adjustment started a different mode; it no longer
                // belongs to the old keyboard session.
                keyOwned.removeValue(forKey: session.uuid)
            } else if ownership.mustRestore(after: normal) {
                keyOwned.removeValue(forKey: session.uuid)
                hud.hide()
                session.stop(reason: "Paused after system brightness changed")
            }
        }
        if !session.busy { keyOwned.removeValue(forKey: session.uuid) }
        let state: BrightnessBoostState
        switch session.state {
        case .off: state = .off
        case .preparing: state = .preparing
        case .on: state = .on
        case .stopping: state = .stopping
        case .unavailable: state = .unavailable
        }
        if let previous = snapshot, previous.state == .on || previous.state == .preparing,
           !session.enabled {
            hud.hide()
        }
        let ceiling = session.state == .on && mode == .boost
            ? min(session.maximumFactor, Double(session.screen.maximumExtendedDynamicRangeColorComponentValue))
            : session.maximumFactor
        snapshot = Snapshot(session: session, state: state, factor: session.desiredFactor,
                            ceiling: ceiling, normal: normal, available: session.supportsBoost,
                            dimmingAvailable: session.supportsDimming, mode: mode, time: now)
        setMessage(normal == nil ? "Normal brightness unavailable on this display" : "")
    }

    private func handle(_ event: BrightnessKeyEvent) -> Bool {
        if event.phase == .up {
            return sequence.route(event: event, state: .off, factor: 1, ceiling: 1,
                                  normalBrightness: nil, available: false) != .passthrough
        }
        if !suspended, trusted, !conflict,
           sequence.holdsNativeDownRepeat(event) || (event.direction == .down && nativeDownRead != nil) {
            return sequence.route(event: event, state: .off, factor: 1, ceiling: 1,
                normalBrightness: nil, available: false,
                nativeDownReadPending: nativeDownRead != nil) != .passthrough
        }
        if event.direction == .up, nativeDownRead != nil {
            nativeDownRead = nil
            nativeDownReadTimer?.invalidate(); nativeDownReadTimer = nil
        }
        guard isEnabled, !suspended, trusted, !conflict,
              var current = snapshot,
              ProcessInfo.processInfo.systemUptime - current.time < 0.75 else {
            sequence.reset()
            RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.hud.hide() }
            return false
        }
        let action = sequence.route(event: event, state: current.state,
            factor: current.factor, ceiling: current.ceiling,
            normalBrightness: current.normal, available: current.available,
            dimmingAvailable: current.dimmingAvailable, mode: current.mode)
        if action == .passthrough {
            // A native key can change the backlight immediately. Never use its
            // old cached endpoint for a fast subsequent opposite press.
            snapshot = nil
            if event.direction == .down, !event.hasUnsupportedModifiers,
               current.state == .off, current.dimmingAvailable,
               let normal = current.normal, normal > 0 {
                let now = ProcessInfo.processInfo.systemUptime
                nativeDownRead = (current.session.uuid, normal, now + 0.03, now + 0.35)
                nativeDownReadTimer?.invalidate()
                let timer = Timer(timeInterval: 0.035, repeats: false) { [weak self] _ in
                    self?.nativeDownReadTimer = nil
                    self?.refresh()
                }
                nativeDownReadTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            } else if event.direction == .up {
                nativeDownRead = nil
                nativeDownReadTimer?.invalidate(); nativeDownReadTimer = nil
            }
            RunLoop.main.perform(inModes:[.common]) { [weak self] in
                self?.hud.hide()
                self?.refresh()
            }
            return false
        }
        switch action {
        case .start(let factor):
            current.state = .preparing
            current.factor = factor
            current.mode = factor < 1 ? .dim : .boost
        case .set(let factor): current.factor = factor
        case .stop: current.state = .stopping; current.factor = 1
        default: break
        }
        snapshot = current
        if action == .consume {
            // A key at the ceiling should still show feedback, even after the
            // previous overlay faded. Keep UI work outside the tap callback.
            if current.state == .on || current.state == .preparing {
                let epoch = generation
                let session = current.session
                RunLoop.main.perform(inModes: [.common]) { [weak self, weak session] in
                    guard let self, let session, epoch == self.generation,
                          session.enabled else { return }
                    self.hud.show(screen: session.screen, factor: session.desiredFactor,
                                  maximum: session.maximumFactor,
                                  preparing: session.state == .preparing)
                }
            }
            return true
        }
        // Coalesce repeated set requests without ever reordering start or stop.
        if case .set = action, let last = pending.last, case .set = last.1,
           last.0 === current.session { pending[pending.count - 1] = (current.session, action) }
        else { pending.append((current.session, action)) }
        if pending.count == 1 {
            let epoch = generation
            RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.flush(epoch: epoch) }
        }
        return true
    }

    private func flush(epoch: Int) {
        guard epoch == generation, isEnabled, !suspended, trusted, !conflict else { return }
        let actions = pending
        pending.removeAll()
        flushing = true
        for (session, action) in actions {
            guard epoch == generation else { break }
            switch action {
            case .start(let factor):
                let mode: BrightnessAdjustmentMode = factor < 1 ? .dim : .boost
                let normal = reader.brightness(displayID: screenID(session.screen))
                guard !session.busy, target() === session,
                      BrightnessKeyPolicy.canStart(mode: mode, normalBrightness: normal,
                          available: mode == .dim ? session.supportsDimming : session.supportsBoost,
                          ceiling: session.maximumFactor), let normal else { continue }
                keyOwned[session.uuid] = KeyOwnership(normal: normal, mode: mode)
                session.setLevel(factor)
                session.start()
            case .set(let factor):
                guard session.enabled else { continue }
                if keyOwned[session.uuid] == nil {
                    guard let normal = reader.brightness(displayID: screenID(session.screen)) else {
                        session.stop(reason: "Paused because system brightness is unavailable")
                        hud.hide()
                        continue
                    }
                    keyOwned[session.uuid] = KeyOwnership(normal: normal,
                        mode: session.isDimming ? .dim : .boost)
                }
                session.setLevel(factor)
            case .stop:
                session.stop(reason: "Off")
            default: continue
            }
            hud.show(screen: session.screen, factor: session.state == .stopping || !session.enabled ? 1 : session.desiredFactor,
                     maximum: session.maximumFactor, preparing: session.state == .preparing,
                     message: session.state == .unavailable ? session.message : nil)
        }
        flushing = false
        refresh()
    }
}
