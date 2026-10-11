import AppKit
import ApplicationServices
import DisplayCore

/// Owns only the extra range. Below the normal maximum macOS receives the
/// original media-key events, retaining its HUD and backlight behavior.
final class BrightnessKeyController {
    private struct Snapshot {
        let session: BoostSession
        var state: BrightnessBoostState
        var factor: Double
        let ceiling: Double
        let normal: Double?
        let available: Bool
        let time: TimeInterval
    }

    private let sessions: () -> [BoostSession]
    private let tap = BrightnessKeyTap()
    private let reader = NormalBrightnessReader()
    private let hud = BrightnessHUD()
    private var timer: Timer?
    private var snapshot: Snapshot?
    private var sequence = BrightnessKeySequence()
    private var pending: [(BoostSession, BrightnessKeyAction)] = []
    private var generation = 0
    private var flushing = false
    private var tapRunning = false
    private var suspended = false
    private var keyOwned: [String: Double] = [:]
    private var lastPermissionCheck = -Double.infinity
    private var trusted = false
    private var conflict = false
    private var nextTapAttempt = 0.0
    var changed: (() -> Void)?
    private(set) var message = ""
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "brightnessKeysEnabled") }
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
        guard isEnabled, timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "brightnessKeysEnabled")
        if enabled {
            suspended = false
            requestPermissionIfNeeded()
            startMonitoring()
            refresh()
        } else {
            shutdown()
            restoreKeySessions(reason: "Off")
            setMessage("")
        }
        changed?()
    }

    func requestPermissionIfNeeded() {
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
        if let baseline = keyOwned[session.uuid], session.enabled,
           normal == nil || normal! < baseline - 0.002 {
            keyOwned.removeValue(forKey: session.uuid)
            session.stop(reason: "Paused after system brightness changed")
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
        let ceiling = session.state == .on
            ? min(session.maximumFactor, Double(session.screen.maximumExtendedDynamicRangeColorComponentValue))
            : session.maximumFactor
        snapshot = Snapshot(session: session, state: state, factor: session.desiredFactor,
                            ceiling: ceiling, normal: normal, available: session.supportsBoost, time: now)
        setMessage(normal == nil ? "Normal brightness unavailable on this display" : "")
    }

    private func handle(_ event: BrightnessKeyEvent) -> Bool {
        if event.phase == .up {
            return sequence.route(event: event, state: .off, factor: 1, ceiling: 1,
                                  normalBrightness: nil, available: false) != .passthrough
        }
        guard isEnabled, !suspended, trusted, !conflict,
              var current = snapshot,
              ProcessInfo.processInfo.systemUptime - current.time < 0.75 else {
            sequence.reset()
            return false
        }
        let action = sequence.route(event: event, state: current.state,
            factor: current.factor, ceiling: current.ceiling,
            normalBrightness: current.normal, available: current.available)
        if action == .passthrough {
            // A native key can change the backlight immediately. Never use its
            // old cached maximum for a fast subsequent Up press.
            snapshot = nil
            RunLoop.main.perform(inModes:[.common]) { [weak self] in self?.refresh() }
            return false
        }
        switch action {
        case .start(let factor): current.state = .preparing; current.factor = factor
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
                guard !session.busy, target() === session, session.supportsBoost,
                      let normal = reader.brightness(displayID: screenID(session.screen)),
                      normal >= 0.999 else { continue }
                keyOwned[session.uuid] = normal
                session.setLevel(factor)
                session.start()
            case .set(let factor):
                guard session.enabled else { continue }
                if keyOwned[session.uuid] == nil { keyOwned[session.uuid] = snapshot?.normal ?? 1 }
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
