import AppKit
import DisplayCore
import DisplayActivation
import Darwin

func screenID(_ screen: NSScreen) -> UInt32 {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

/// One explicit user-controlled session per physical display. Helpers use
/// separate UUID directories, so independent displays cannot share baselines.
final class BoostSession {
    enum State { case off, preparing, on, stopping, unavailable }
    let uuid: String
    let directory: URL
    var screen: NSScreen
    var state: State = .off
    var message = "Off"
    var desiredFactor: Double
    var maximumFactor: Double
    var changed: (() -> Void)?
    private var carrier: HDRCarrier?
    private var child: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var inputClosed = true
    private var buffer = Data()
    private var token = UUID()
    private var fingerprint = ""
    private var deadline: TimeInterval = 0
    private var stopStage = 0
    private var nextRenew: TimeInterval = 0
    private var nextReadback: TimeInterval = 0
    private var appliedFactor = 1.0
    private var confirmedFactor: Double?
    private let luminanceReader: any DisplayLuminanceReading
    private var luminanceReading: DisplayLuminanceReadingSnapshot?
    private var nextLuminanceRead = -Double.infinity
    private var pendingSet = false
    private var levelTimer: Timer?
    private var beginSent = false
    private var errorMessage: String?
    private var stopMessage: String?
    private var lastRequestedFactor = 1.0
    private var lastReply: TimeInterval = 0
    private var activeFrame = NSRect.zero
    private var activeDisplayID: UInt32 = 0
    private var activeDimming: Bool?
    private var restartAfterRestoration = false
    var minimumFactor: Double { DisplayAdjustmentRange.minimumFactor }
    /// Retain the active direction through restoration so key ownership never
    /// changes direction merely because the user selected the normal midpoint.
    var isDimming: Bool { activeDimming ?? (desiredFactor < 1) }
    var supportsDimming: Bool {
        let id = screenID(screen)
        guard CGDisplayIsOnline(id) != 0, CGDisplayIsInMirrorSet(id) == 0 else { return false }
        let capacity = CGDisplayGammaTableCapacity(id)
        return capacity > 0 && capacity <= 65536
    }
    var supportsBoost: Bool {
        supportsDimming && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.01
    }
    var busy: Bool { child != nil || state == .preparing || state == .on || state == .stopping }
    var enabled: Bool { state == .on || state == .preparing }

    init(screen: NSScreen, identity: DisplayIdentity, directory: URL,
         luminanceReader: any DisplayLuminanceReading = CachedDisplayLuminanceReader()) {
        self.luminanceReader = luminanceReader
        self.screen = screen; uuid = identity.uuid; self.directory = directory
        // The ceiling is a tested input range, not a measured nit ratio.
        maximumFactor = Self.ceiling(for: screen)
        desiredFactor = Self.selectedLevel(for: screen, uuid: uuid)
        recover()
        refreshAvailability()
    }

    private static func ceiling(for screen: NSScreen) -> Double {
        let potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        return potential.isFinite ? max(1, min(DisplayAdjustmentRange.maximumFactor, potential)) : 1
    }
    private static func selectedLevel(for screen: NSScreen, uuid: String) -> Double {
        let initial = CGDisplayIsBuiltin(screenID(screen)) != 0 ? 1.45 : (screen.localizedName.contains("XDR") ? 1.75 : 1.2)
        let stored = UserDefaults.standard.object(forKey:"boost.\(uuid)") as? Double ?? initial
        return min(ceiling(for: screen), max(DisplayAdjustmentRange.minimumFactor, stored.isFinite ? stored : initial))
    }

    private func note(_ event: String, _ extra: [String:Any] = [:]) {
        var value = extra; value["event"] = event; value["displayUUID"] = uuid
        value["time"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys), let text = String(data:data,encoding:.utf8) {print(text);fflush(stdout)}
    }
    func recover() {
        guard child == nil else { return }
        do {
            let store = try RecoveryStore(directory:directory)
            let result = store.recoverAll()
            if result.allSatisfy(\.succeeded) {state = .off; message = "Off"; errorMessage = nil; activeDimming = nil}
            else {state = .unavailable; message = "Recovery needs attention"; errorMessage = result.filter{!$0.succeeded}.map(\.message).joined(separator:" ")}
        } catch {state = .unavailable; message = "Another session or recovery is active"; errorMessage = error.localizedDescription}
    }
    func refreshAvailability() {
        if !busy && !supportsDimming {state = .unavailable;message = "Brightness adjustment unavailable"}
        else if state == .off && !supportsBoost {message = "Dimming available; extra brightness unavailable"}
    }
    func updateScreen(_ incoming: NSScreen, reconnected: Bool) {
        if busy && (screenID(incoming) != activeDisplayID || incoming.frame != activeFrame) {
            stop(reason: "Paused after display arrangement changed")
        }
        screen = incoming
        maximumFactor = Self.ceiling(for: incoming)
        desiredFactor = Self.selectedLevel(for: incoming, uuid: uuid)
        if reconnected && !busy {recover()}
        refreshAvailability()
        update()
    }
    var detail: String { errorMessage ?? message }
    /// Use live native nits and only a helper-acknowledged gain for the model.
    /// HDR capacity caps the prediction; neither value is an optical measurement.
    var luminance: DisplayLuminance {
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextLuminanceRead {
            luminanceReading = luminanceReader.reading(displayID: screenID(screen))
            nextLuminanceRead = now + 0.1
        }
        switch state {
        case .off:
            return DisplayLuminance(referenceNits: luminanceReading?.referenceNits, appliedFactor: 1)
        case .on:
            // CoreBrightness's raw Headroom can reflect a request (16 on
            // the test Mac), not the public current capability. Use a fresh
            // matched NSScreen and bound it by the available system range.
            let currentScreen = NSScreen.screens.first { screenID($0) == screenID(screen) }
            let boostContext = luminanceReading?.maximumHDRNits.flatMap { maximum in
                currentScreen.map {
                    DisplayLuminance.BoostContext(
                        currentHeadroom: Double($0.maximumExtendedDynamicRangeColorComponentValue),
                        maximumHDRNits: maximum,
                        availablePeakNits: luminanceReading?.systemTelemetry.map { $0.sdrNits * $0.availableHeadroom })
                }
            }
            return DisplayLuminance(referenceNits: luminanceReading?.referenceNits,
                appliedFactor: confirmedFactor ?? .nan, boostActive: !isDimming,
                boostContext: boostContext)
        case .preparing, .stopping, .unavailable:
            return DisplayLuminance(referenceNits: nil, appliedFactor: 1)
        }
    }
    private func update() { changed?() }
    func toggle() {
        if enabled {stop(reason:"Off")}
        else if state != .stopping {start()}
    }
    func setLevel(_ value: Double) {
        guard value.isFinite else { return }
        desiredFactor = min(maximumFactor,max(minimumFactor,value))
        UserDefaults.standard.set(desiredFactor,forKey:"boost.\(uuid)")
        if desiredFactor == 1 {
            // At the midpoint the original table is sufficient. A normal stop
            // also cancels a pending cross-mode restart.
            if busy { stop(reason:"Off") }
            update()
            return
        }
        if enabled && (desiredFactor < 1) != isDimming {
            // A fresh session is required when introducing/removing the HDR
            // carrier. Do not capture a scaled table as the next baseline.
            stop(reason:"Changing brightness range…")
            if child != nil { restartAfterRestoration = true }
            else { start() }
            return
        }
        pendingSet = true
        scheduleLevelUpdate()
        update()
    }
    private func scheduleLevelUpdate() {
        guard state == .on, levelTimer == nil else { return }
        let timer = Timer(timeInterval:0.04,repeats:false) { [weak self] _ in
            guard let self else { return }
            self.levelTimer = nil
            guard self.state == .on, self.pendingSet else { return }
            self.applyPendingLevel()
        }
        levelTimer = timer
        RunLoop.main.add(timer,forMode:.common)
    }
    private func applyPendingLevel() {
        guard state == .on else { return }
        let factor = allowedFactor()
        pendingSet = false;lastRequestedFactor = factor;appliedFactor = factor
        send(["command":"set","factor":factor])
    }
    func start() {
        guard !busy else {return}
        restartAfterRestoration = false
        recover()
        guard state != .unavailable else {update();return}
        guard desiredFactor != 1 else { update(); return }
        let id = screenID(screen)
        let dimming = desiredFactor < 1
        guard supportsDimming, dimming || supportsBoost else {
            state = .unavailable; message = dimming ? "Dimming unavailable" : "Extra brightness unavailable"; update();return
        }
        activeFrame = screen.frame; activeDisplayID = id
        activeDimming = dimming
        token = UUID(); let attempt = token
        errorMessage = nil; stopMessage = nil; beginSent = false; pendingSet = false
        confirmedFactor = nil
        state = .preparing; message = dimming ? "Preparing dimming…" : "Preparing brightness…"
        deadline = ProcessInfo.processInfo.systemUptime + 12
        do {
            fingerprint = try DisplayIdentity.capture(display:id).configuration
            if dimming {
                // Software dimming needs no HDR content or EDR-capable panel.
                try launchGuard(attempt:attempt)
                update()
                return
            }
            let activation = try HDRCarrier(screen:screen, currentHeadroom: { [weak self] in
                Double(self?.screen.maximumExtendedDynamicRangeColorComponentValue ?? 0)
            })
            carrier = activation
            activation.prepare { [weak self] result in
                guard let self, self.token == attempt, self.state == .preparing else {return}
                switch result {
                case .failure(let error):self.fail(error.localizedDescription)
                case .success:
                    let headroom = self.screen.maximumExtendedDynamicRangeColorComponentValue
                    guard headroom > 1.01 else {self.fail("Extra brightness is unavailable under the current display settings.");return}
                    do {try self.launchGuard(attempt:attempt)} catch {self.fail(error.localizedDescription)}
                }
            }
        } catch {fail(error.localizedDescription)}
        update()
    }
    private func allowedFactor() -> Double {
        if isDimming { return min(1, max(minimumFactor, desiredFactor)) }
        return min(desiredFactor, maximumFactor, max(1,Double(screen.maximumExtendedDynamicRangeColorComponentValue)))
    }
    private func launchGuard(attempt:UUID) throws {
        let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("DisplayGuardian") ?? URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("DisplayGuardian")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else {throw DisplayError.invalid("The recovery helper is missing.")}
        let p = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        p.executableURL = executable; p.arguments = ["--journal-dir",directory.path]
        p.standardInput = stdinPipe; p.standardOutput = stdoutPipe; p.standardError = stderrPipe
        input = stdinPipe; output = stdoutPipe; errors = stderrPipe; inputClosed = false; child = p; buffer = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {handle.readabilityHandler = nil;return}
            RunLoop.main.perform(inModes: [.common]) {guard let self, self.token == attempt, self.child === p else{return};self.consume(data)}
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {handle.readabilityHandler = nil;return}
            RunLoop.main.perform(inModes: [.common]) {self?.note("helper-error",["message":String(decoding:data,as:UTF8.self)])}
        }
        p.terminationHandler = { [weak self] process in
            RunLoop.main.perform(inModes: [.common]) {
                guard let self, self.token == attempt, self.child === process else {return}
                self.note("helper-exit",["status":process.terminationStatus])
                self.clearGuard();self.carrier?.close();self.carrier = nil
                let priorFailure = self.errorMessage, requestedStop = self.stopMessage
                let restart = self.restartAfterRestoration
                self.restartAfterRestoration = false
                self.recover()
                if self.state == .off {
                    if let failure = priorFailure {self.state = .unavailable;self.message = "Brightness paused";self.errorMessage = failure}
                    else if restart { self.start(); return }
                    else {self.message = requestedStop ?? "Off"}
                }
                self.update()
            }
        }
        do {try p.run()} catch {p.terminationHandler = nil;clearGuard();throw error}
        lastReply = ProcessInfo.processInfo.systemUptime
        deadline = lastReply + 8
    }
    private func clearGuard() {
        output?.fileHandleForReading.readabilityHandler = nil;errors?.fileHandleForReading.readabilityHandler = nil
        for pipe in [input,output,errors].compactMap({$0}) {try? pipe.fileHandleForReading.close();try? pipe.fileHandleForWriting.close()}
        child = nil;input = nil;output = nil;errors = nil;inputClosed = true;buffer = Data()
    }
    private func send(_ value:[String:Any]) {
        guard let input, !inputClosed else{return}
        do {
            var data = try JSONSerialization.data(withJSONObject:value);data.append(10)
            try input.fileHandleForWriting.write(contentsOf:data)
        } catch {closeInput();fail("The recovery guard connection was lost.")}
    }
    private func closeInput() {guard !inputClosed else{return};inputClosed = true;try? input?.fileHandleForWriting.close()}
    private func consume(_ data:Data) {
        buffer.append(data)
        guard buffer.count < 262144 else {fail("Recovery output exceeded its limit.");return}
        while let end = buffer.firstIndex(of:10) {
            let line = Data(buffer[..<end]);buffer.removeSubrange(...end)
            guard let record = try? JSONSerialization.jsonObject(with:line) as? [String:Any] else {continue}
            lastReply = ProcessInfo.processInfo.systemUptime
            let event = record["event"] as? String ?? "unknown", ok = record["ok"] as? Bool == true
            if event != "pong" && event != "renewed" {note("guardian",record)}
            if event == "ready" && ok && state == .preparing && !beginSent {
                guard supportsDimming, isDimming || supportsBoost,
                      let identity = try? DisplayIdentity.capture(display: screenID(screen)),
                      identity.uuid == uuid, identity.configuration == fingerprint else {
                    fail("The selected display or its settings changed while preparing brightness.")
                    continue
                }
                beginSent = true;appliedFactor = allowedFactor();lastRequestedFactor = appliedFactor
                send(["command":"begin","displayID":screenID(screen),"displayUUID":uuid,"factor":appliedFactor,"duration":30,"renewable":true])
            } else if event == "began" && ok && state == .preparing {
                confirmedFactor = (record["factor"] as? NSNumber)?.doubleValue
                state = .on;message = isDimming ? "Dimming" : "Boosting";nextRenew = ProcessInfo.processInfo.systemUptime + 10;nextReadback = 0;update()
                if pendingSet { scheduleLevelUpdate() }
            } else if event == "set" && ok {
                appliedFactor = (record["factor"] as? NSNumber)?.doubleValue ?? lastRequestedFactor
                confirmedFactor = (record["factor"] as? NSNumber)?.doubleValue
                update()
            } else if event == "ended" {
                if !ok {
                    errorMessage = record["message"] as? String ?? "Restoration needs attention."
                    restartAfterRestoration = false
                }
                // A successful acknowledgement of our own stop must not
                // cancel the explicit cross-mode request waiting for exit.
                // External stops still take the ordinary cancellation path.
                if state != .stopping { stop(reason:ok ? "Off" : "Recovery needs attention") }
            } else if !ok {fail(record["message"] as? String ?? "The recovery guard rejected the change.")}
        }
    }
    func tick(now:TimeInterval) {
        if state == .stopping {
            guard now >= deadline, let child else {return}
            if stopStage == 0 {if child.isRunning {Darwin.kill(child.processIdentifier,SIGTERM)};stopStage = 1;deadline = now+2}
            else if stopStage == 1 {if child.isRunning {Darwin.kill(child.processIdentifier,SIGKILL)};stopStage = 2;deadline = now+2}
            return
        }
        if state == .preparing && now >= deadline {fail("Brightness preparation timed out.");return}
        if child != nil {
            guard now - lastReply < 4 else {fail("The recovery guard stopped responding.");return}
            send(["command":"ping"])
        }
        guard state == .on else{return}
        let id = screenID(screen)
        guard CGDisplayIsOnline(id) != 0, CGDisplayIsInMirrorSet(id) == 0 else{stop(reason:"Display disconnected or mirrored");return}
        // A profile/mode change invalidates the immutable baseline. End this
        // session and require a fresh explicit enable after recovery.
        if now >= nextReadback {
            nextReadback = now + 2
            guard let identity = try? DisplayIdentity.capture(display:id), identity.uuid == uuid, identity.configuration == fingerprint else {stop(reason:"Paused after display settings changed");return}
        }
        if !isDimming {
            let headroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            guard headroom.isFinite, headroom > 1.01 else {stop(reason:"Extra brightness unavailable");return}
        }
        let factor = allowedFactor()
        if pendingSet || abs(factor-appliedFactor)>0.02 {
            applyPendingLevel()
        }
        if now >= nextRenew {nextRenew = now+10;send(["command":"renew"])}
    }
    func stop(reason:String) {
        restartAfterRestoration = false
        levelTimer?.invalidate();levelTimer = nil;pendingSet = false
        carrier?.close();carrier = nil
        if state == .stopping {return}
        stopMessage = reason
        if child != nil {
            state = .stopping;message = "Restoring…";deadline = ProcessInfo.processInfo.systemUptime+2;stopStage = 0
            send(["command":"stop"]);closeInput()
        } else {token = UUID();state = .off;message = reason;activeDimming = nil}
        update()
    }
    private func fail(_ reason:String) {
        restartAfterRestoration = false
        errorMessage = reason;note("error",["message":reason])
        if child != nil {stop(reason:"Brightness paused")}
        else {carrier?.close();carrier = nil;token = UUID();state = .unavailable;message = "Brightness adjustment unavailable";update()}
    }
}
