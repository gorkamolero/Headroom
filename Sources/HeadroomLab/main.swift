import AppKit
import CoreGraphics
import DisplayCore
import Darwin

private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}
private func inventory() -> [[String: Any]] {
    NSScreen.screens.map { s in
        let id = displayID(s)
        let table = try? GammaTable.read(display: id)
        return ["displayID": id, "name": s.localizedName,
                "currentEDR": s.maximumExtendedDynamicRangeColorComponentValue,
                "potentialEDR": s.maximumPotentialExtendedDynamicRangeColorComponentValue,
                "referenceEDR": s.maximumReferenceExtendedDynamicRangeColorComponentValue,
                "gammaSamples": table?.count ?? 0, "gammaMaximum": table?.maximum ?? 0,
                "mirrored": CGDisplayIsInMirrorSet(id) != 0]
    }
}
private func json(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string
}

final class Lab: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    let displays = NSPopUpButton()
    let modes = NSPopUpButton()
    let slider = NSSlider(value: 1.2, minValue: 1, maxValue: 2, target: nil, action: nil)
    let amount = NSTextField(labelWithString: "1.20× table multiplier")
    let capability = NSTextField(wrappingLabelWithString: "")
    let state = NSTextField(wrappingLabelWithString: "Off. No display settings have been changed.")
    let start = NSButton(title: "Start 20-second trial", target: nil, action: nil)
    let stop = NSButton(title: "Stop and restore", target: nil, action: nil)
    let feedback = NSTextField(wrappingLabelWithString: "Compare the unchanged desktop and the SDR chart below. Watch the 80%, 90% and 100% steps for clipping. A tiny EDR dot appears at the bottom-left during EDR trials.")
    var patch: EDRPatch?
    var guardian: Process?
    var input: Pipe?
    var output: Pipe?
    var outputBuffer = Data()
    var errorPipe: Pipe?
    var timer: Timer?
    var active = false
    var stopping = false
    var starting = false
    var finishing = false
    var trialID = UUID()
    var guardianSession: UUID?
    var beginSent = false
    var stopDeadline: TimeInterval?
    var terminationSent = false
    var killSent = false
    var guardianEndMessage: String?
    var guardianReportedRecovery = false
    var recoveryBlocked = false
    var inputClosed = true
    var readbackWarning: String?
    var selectedID: UInt32 = 0
    var initialFingerprint = ""
    var trialFactor: Double = 1
    var trialMode = "combined"
    var deadline: TimeInterval = 0
    var records = [[String: Any]]()
    var automatic = false
    var autoMode: String?
    var autoDuration: Double = 20
    var reportPath: String?
    var terminateAfterStop = false
    var observers = [NSObjectProtocol]()
    let journalDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HeadroomLab/Recovery", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildUI()
        configureObservers()
        recoverPending()
        refreshDisplays()
        log("launch", ["displays": inventory(), "build": "0.1.0-prototype"])
        if let index = CommandLine.arguments.firstIndex(of: "--trial"), CommandLine.arguments.count > index + 1 {
            automatic = true
            autoMode = CommandLine.arguments[index+1]
            if let p = CommandLine.arguments.firstIndex(of: "--duration"), CommandLine.arguments.count > p+1 { autoDuration = min(45,max(1,Double(CommandLine.arguments[p+1]) ?? 20)) }
            if let p = CommandLine.arguments.firstIndex(of: "--factor"), CommandLine.arguments.count > p+1 { slider.doubleValue = min(2,max(1,Double(CommandLine.arguments[p+1]) ?? 1.2)) }
            if let p = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > p+1 { reportPath = CommandLine.arguments[p+1] }
            if let p = CommandLine.arguments.firstIndex(of: "--display"), CommandLine.arguments.count > p+1, let id = UInt32(CommandLine.arguments[p+1]), let i = NSScreen.screens.firstIndex(where: {displayID($0) == id}) { displays.selectItem(at: i) }
            modes.selectItem(at: ["layer", "table", "combined"].firstIndex(of: autoMode!) ?? 2)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.5) { self.beginTrial() }
        } else {
            showPanel()
        }
    }

    func recoverPending() {
        do {
            let store = try RecoveryStore(directory: journalDirectory)
            let results = store.recoverAll()
            recoveryBlocked = !results.allSatisfy(\.succeeded)
            if !results.isEmpty {
                log("startup-recovery",["results":String(describing:results)])
                state.stringValue = results.allSatisfy(\.succeeded) ? "Off. An interrupted trial was recovered." : "Recovery requires attention. New table experiments will be blocked."
            }
        } catch {
            recoveryBlocked = true
            log("startup-recovery-unavailable",["message":error.localizedDescription])
            state.stringValue = "Recovery is unavailable: \(error.localizedDescription)"
        }
    }

    func log(_ event: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["event"] = event
        row["timestamp"] = ISO8601DateFormatter().string(from: Date())
        records.append(row)
        print(json(row)); fflush(stdout)
    }

    func buildUI() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Headroom Lab")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Headroom Lab…", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Stop and restore", action: #selector(stopTrial), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        panel = NSPanel(contentRect: NSRect(x:0,y:0,width:660,height:590), styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.title = "Headroom Lab · Experimental prototype"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let content = NSView()
        panel.contentView = content
        let title = NSTextField(labelWithString: "Desktop brightness experiment")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "A bounded test of Metal EDR and display transfer tables. Brightness gain and colour accuracy are not yet measured. Every trial ends automatically.")
        subtitle.textColor = .secondaryLabelColor
        displays.target = self; displays.action = #selector(selectionChanged)
        modes.addItems(withTitles:["1 · EDR layer only", "2 · Transfer table only", "3 · EDR + transfer table"])
        modes.selectItem(at:2)
        modes.target = self; modes.action = #selector(selectionChanged)
        slider.target = self; slider.action = #selector(sliderChanged)
        slider.isContinuous = false
        start.target = self; start.action = #selector(beginTrial)
        stop.target = self; stop.action = #selector(stopTrial); stop.isEnabled = false
        stop.keyEquivalent = "\u{1b}"
        capability.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize:13,weight:.medium)
        feedback.textColor = .secondaryLabelColor
        let chart = SDRChart()
        let buttons = NSStackView(views:[start,stop]); buttons.orientation = .horizontal; buttons.spacing = 12
        let stack = NSStackView(views:[title,subtitle,displays,capability,modes,slider,amount,buttons,state,feedback,chart])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:24),
            stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-24),
            stack.topAnchor.constraint(equalTo:content.topAnchor,constant:24),
            slider.widthAnchor.constraint(equalTo:stack.widthAnchor),
            chart.widthAnchor.constraint(equalTo:stack.widthAnchor), chart.heightAnchor.constraint(equalToConstant:100),
            subtitle.widthAnchor.constraint(equalTo:stack.widthAnchor), capability.widthAnchor.constraint(equalTo:stack.widthAnchor),
            state.widthAnchor.constraint(equalTo:stack.widthAnchor), feedback.widthAnchor.constraint(equalTo:stack.widthAnchor)
        ])
        panel.center()
    }

    @objc func showPanel() { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    @objc func selectionChanged() { refreshCapability() }
    @objc func sliderChanged() { amount.stringValue = String(format:"%.2f× table multiplier · experimental, not measured brightness",slider.doubleValue) }
    func selectedScreen() -> NSScreen? {
        let i = displays.indexOfSelectedItem
        return NSScreen.screens.indices.contains(i) ? NSScreen.screens[i] : nil
    }
    func fingerprint() -> String {
        NSScreen.screens.map { s in
            let id = displayID(s)
            return "\(id)|\(NSStringFromRect(s.frame))|\(s.backingScaleFactor)|\(s.colorSpace?.iccProfileData?.base64EncodedString() ?? "")|\(CGDisplayCopyDisplayMode(id)?.ioDisplayModeID ?? 0)"
        }.joined(separator:";")
    }
    func refreshDisplays() {
        let previous = selectedScreen().map(displayID)
        displays.removeAllItems()
        displays.addItems(withTitles:NSScreen.screens.map { "\($0.localizedName) · display \(displayID($0))" })
        if let previous, let i = NSScreen.screens.firstIndex(where:{displayID($0) == previous}) { displays.selectItem(at:i) }
        refreshCapability()
    }
    func refreshCapability() {
        guard let s = selectedScreen() else { capability.stringValue = "No display connected."; start.isEnabled = false; return }
        let potential = s.maximumPotentialExtendedDynamicRangeColorComponentValue
        let current = s.maximumExtendedDynamicRangeColorComponentValue
        let mirrored = CGDisplayIsInMirrorSet(displayID(s)) != 0
        capability.stringValue = String(format:"EDR available now: %.2f× · potential: %.2f×%@",current,potential,mirrored ? " · mirrored displays unavailable" : "")
        if potential <= 1.01 { capability.stringValue += " · extra brightness unavailable" }
        start.isEnabled = !active && !starting && !stopping && guardian == nil && !recoveryBlocked && potential > 1.01 && !mirrored
        slider.maxValue = min(2, max(1.01,potential))
        sliderChanged()
    }

    func configureObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self else {return}
            if (self.active || self.starting) && self.initialFingerprint != self.fingerprint() { self.endTrial(reason:"Display configuration or profile changed") }
            self.refreshDisplays()
        })
        let wn = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(wn.addObserver(forName:name,object:nil,queue:.main) { [weak self] note in
                guard let self else {return}
                self.log("workspace",["notification":note.name.rawValue])
                if self.active || self.starting { self.endTrial(reason:"Sleep, wake or session change") }
                self.refreshDisplays()
            })
        }
    }

    @objc func beginTrial() {
        guard !active && !starting && !stopping && guardian == nil else {return}
        finishing = false
        guard !recoveryBlocked else { fail("Unresolved recovery must be addressed before another trial."); return }
        guard let screen = selectedScreen() else { fail("No display is connected."); return }
        let potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        guard potential > 1.01, CGDisplayIsInMirrorSet(displayID(screen)) == 0 else { fail("Extra brightness is unavailable on this display."); return }
        starting = true; finishing = false
        trialID = UUID(); beginSent = false; guardianEndMessage = nil; guardianReportedRecovery = false; readbackWarning = nil
        stopDeadline = nil; terminationSent = false; killSent = false
        let id = trialID
        deadline = ProcessInfo.processInfo.systemUptime + 12
        ensureTimer()
        selectedID = displayID(screen)
        trialFactor = slider.doubleValue
        trialMode = ["layer","table","combined"][max(0,modes.indexOfSelectedItem)]
        initialFingerprint = fingerprint()
        start.isEnabled = false; stop.isEnabled = true; displays.isEnabled = false; modes.isEnabled = false; slider.isEnabled = false
        state.stringValue = "Preparing the recovery guard and EDR layer…"
        state.textColor = .labelColor
        log("trial-preparing",["mode":trialMode,"requestedFactor":trialFactor,"displayID":selectedID,"displays":inventory()])
        do {
            if trialMode != "table" {
                patch = try EDRPatch(screen:screen)
                patch?.render(value:min(2,Double(potential))) { [weak self] result in
                    guard let self, self.trialID == id, self.starting, !self.stopping, !self.finishing else { return }
                    switch result {
                    case .success:
                        self.log("metal-frame",["frames":self.patch?.frameCount ?? 0,"gpuSeconds":self.patch?.gpuSeconds ?? 0])
                        self.prepareGuardian(afterSettlingFor: 2, trial: id)
                    case .failure(let error): self.fail(error.localizedDescription)
                    }
                }
            } else {
                prepareGuardian(afterSettlingFor: 0, trial: id)
            }
        } catch { fail(error.localizedDescription) }
    }

    func ensureTimer() {
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    func prepareGuardian(afterSettlingFor delay: Double, trial id: UUID) {
            // Allow EDR headroom to settle; no animation/render loop is running.
            DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in
                guard let self, self.trialID == id, self.starting, !self.stopping, !self.finishing, self.guardian == nil else {return}
                if self.trialMode == "layer" { self.activateTrial(); return }
                guard let live = NSScreen.screens.first(where:{displayID($0) == self.selectedID}) else { self.fail("Display disconnected."); return }
                let available = Double(live.maximumExtendedDynamicRangeColorComponentValue)
                guard available > 1.01 else { self.fail("No EDR headroom is currently available. Trial cancelled."); return }
                self.trialFactor = min(self.trialFactor, available, 2)
                do { try self.launchGuardian() } catch { self.fail(error.localizedDescription) }
            }
    }

    func launchGuardian() throws {
        let exe = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("DisplayGuardian")
        guard FileManager.default.isExecutableFile(atPath:exe.path) else {throw NSError(domain:"HeadroomLab",code:5,userInfo:[NSLocalizedDescriptionKey:"Recovery helper missing. Rebuild the app before testing."])}
        let process = Process(); let stdinPipe = Pipe(); let stdoutPipe = Pipe(); let stderrPipe = Pipe()
        let session = UUID()
        process.executableURL = exe; process.arguments = ["--journal-dir",journalDirectory.path]
        process.standardInput = stdinPipe; process.standardOutput = stdoutPipe; process.standardError = stderrPipe
        input = stdinPipe; output = stdoutPipe; errorPipe = stderrPipe; guardian = process; guardianSession = session; outputBuffer = Data(); inputClosed = false
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data, session: session) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, self.guardianSession == session else { return }
                self.log("guardian-stderr",["message":String(decoding:data,as:UTF8.self)])
            }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.guardian === p, self.guardianSession == session else {return}
                self.log("guardian-exit",["status":p.terminationStatus])
                self.clearGuardian()
                // The process is confirmed dead before taking its lock or
                // writing a baseline. Every exit checks the persisted journal,
                // even if an ended response was already received.
                var recoveryMessage = self.guardianEndMessage ?? "Off. Recovery guard exited with no pending transfer-table changes."
                do {
                    let store = try RecoveryStore(directory:self.journalDirectory)
                    let results = store.recoverAll()
                    self.recoveryBlocked = !results.allSatisfy(\.succeeded)
                    self.log("parent-recovery",["results":String(describing:results), "ok":!self.recoveryBlocked])
                    if self.recoveryBlocked {
                        recoveryMessage = "Recovery requires attention. Original appearance could not be verified: " + results.filter { !$0.succeeded }.map(\.message).joined(separator: " ")
                    } else if !results.isEmpty {
                        recoveryMessage = "Off. Original transfer tables restored and read back by the parent recovery check."
                    } else if !self.guardianReportedRecovery {
                        recoveryMessage = "Off. Recovery guard exited; no pending transfer-table changes remain."
                    }
                } catch {
                    self.recoveryBlocked = true
                    self.log("parent-recovery-failed",["message":error.localizedDescription])
                    recoveryMessage = "Recovery could not be checked: \(error.localizedDescription). New trials are blocked."
                }
                self.finishTrial(message:recoveryMessage)
            }
        }
        do { try process.run() }
        catch {
            process.terminationHandler = nil
            clearGuardian()
            throw error
        }
        ensureTimer()
        deadline = ProcessInfo.processInfo.systemUptime + 8
    }

    func clearGuardian() {
        output?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        for pipe in [input, output, errorPipe].compactMap({ $0 }) {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        guardian = nil; guardianSession = nil; input = nil; output = nil; errorPipe = nil; inputClosed = true
        outputBuffer = Data()
    }

    func send(_ object: [String:Any]) {
        guard let pipe = input, !inputClosed else {return}
        do { try pipe.fileHandleForWriting.write(contentsOf:Data((json(object)+"\n").utf8)) }
        catch {
            log("pipe-error",["message":error.localizedDescription])
            closeGuardianInput()
            if active || starting { endTrial(reason: "Recovery guard connection failed") }
        }
    }
    func closeGuardianInput() {
        guard !inputClosed else { return }
        inputClosed = true
        try? input?.fileHandleForWriting.close()
    }
    func consume(_ data: Data, session: UUID) {
        guard guardianSession == session, guardian != nil, !finishing else { return }
        outputBuffer.append(data)
        guard outputBuffer.count <= 262_144 else { endTrial(reason: "Recovery guard output exceeded its limit"); return }
        while let range = outputBuffer.range(of:Data([10])) {
            let line = outputBuffer.subdata(in:outputBuffer.startIndex..<range.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex..<range.upperBound)
            guard let object = try? JSONSerialization.jsonObject(with:line) as? [String:Any] else {continue}
            let event = object["event"] as? String ?? "unknown"
            if event != "pong" { var details = object; details["guardianEvent"] = event; log("guardian",details) }
            if event == "ready" && object["ok"] as? Bool == true && starting && !stopping && !beginSent {
                beginSent = true
                send(["command":"begin","displayID":selectedID,"factor":trialFactor,"duration":automatic ? autoDuration : 20])
            } else if event == "began" || event == "begin" {
                if object["ok"] as? Bool == true && starting && beginSent && !stopping {
                    if let maximum = (object["readbackMaximum"] as? NSNumber)?.doubleValue, maximum <= 1.0005, trialFactor > 1.0005 {
                        readbackWarning = "macOS clamps the table to SDR range; extra white brightness is not measured and highlights may clip."
                        log("table-clamped-warning",["readbackMaximum":maximum,"requestedFactor":trialFactor])
                    }
                    activateTrial()
                }
            } else if event == "restored" || event == "stopped" || event == "ended" {
                let ok = object["ok"] as? Bool == true
                let status = object["status"] as? String ?? ""
                guardianReportedRecovery = ok && ["restored", "alreadyOriginal"].contains(status)
                guardianEndMessage = guardianReportedRecovery ? "Off. Original transfer tables restored and read back." : (ok ? "Off. No transfer-table experiment was active." : "Recovery requires attention: \(object["message"] as? String ?? "Original appearance could not be verified.")")
                beginShutdown()
                send(["command":"quit"])
                closeGuardianInput()
            } else if object["ok"] as? Bool == false {
                fail(object["message"] as? String ?? "The recovery guard rejected this trial.")
            }
        }
    }
    func activateTrial() {
        guard starting && !stopping && !finishing else {return}
        starting = false; active = true
        deadline = ProcessInfo.processInfo.systemUptime + (automatic ? autoDuration : 20)
        ensureTimer()
        statusItem.button?.image = NSImage(systemSymbolName:"sun.max.fill",accessibilityDescription:"Headroom trial active")
        log("trial-active",["mode":trialMode,"factor":trialFactor,"displays":inventory()])
        tick()
    }
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if stopping {
            guard let process = guardian, let until = stopDeadline, now >= until else { return }
            if !terminationSent {
                terminationSent = true; stopDeadline = now + 2
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGTERM) }
                log("guardian-stop-timeout",["action":"SIGTERM"])
            } else if !killSent {
                killSent = true; stopDeadline = now + 2
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                log("guardian-stop-timeout",["action":"SIGKILL; parent recovery runs after confirmed exit"])
            } else if process.isRunning {
                state.stringValue = "Waiting for macOS to confirm the recovery guard exited. New trials are blocked."
            }
            return
        }
        if now >= deadline {endTrial(reason:starting ? "Guard startup timeout" : "Trial timer finished"); return}
        if guardian != nil { send(["command":"ping"]) }
        if active {
            guard let screen = NSScreen.screens.first(where:{displayID($0) == selectedID}), fingerprint() == initialFingerprint else {endTrial(reason:"Display changed");return}
            if trialMode != "layer" && Double(screen.maximumExtendedDynamicRangeColorComponentValue) + 0.01 < trialFactor {endTrial(reason:"EDR headroom decreased");return}
            let seconds = Int(ceil(deadline - now))
            let countdown = "Trial active · \(seconds)s remaining · \(String(format:"%.2f",trialFactor))× table multiplier."
            state.stringValue = readbackWarning.map { "\($0)\n\(countdown)" } ?? "\(countdown)\nObserve white brightness, contrast and highlight steps in ordinary apps."
            state.textColor = readbackWarning == nil ? .labelColor : .systemOrange
        }
    }
    @objc func stopTrial() {endTrial(reason:"Stopped by user")}
    func endTrial(reason: String) {
        guard (active || starting) && !stopping else {return}
        log("trial-ending",["reason":reason,"displays":inventory()])
        if guardian != nil {
            beginShutdown()
            send(["command":"stop"])
            // EOF asks a responsive helper to restore; a bounded escalation
            // handles a stopped helper before the parent recovers its journal.
            closeGuardianInput()
        } else {finishTrial(message:"Off. EDR layer removed; no transfer tables were changed.")}
    }
    func beginShutdown() {
        patch?.close(); patch = nil
        active = false; starting = false
        if !stopping {
            stopping = true; stopDeadline = ProcessInfo.processInfo.systemUptime + 2
            terminationSent = false; killSent = false
        }
        state.stringValue = "Finishing recovery and waiting for the guard to exit…"
        stop.isEnabled = false
        ensureTimer()
    }
    func finishTrial(message: String) {
        guard guardian == nil else { beginShutdown(); return }
        guard !finishing else {return}; finishing = true
        timer?.invalidate(); timer = nil
        patch?.close(); patch = nil
        active = false; starting = false; stopping = false
        displays.isEnabled = true; modes.isEnabled = true; slider.isEnabled = true; stop.isEnabled = false
        state.stringValue = message
        state.textColor = recoveryBlocked ? .systemRed : .labelColor
        statusItem.button?.image = NSImage(systemSymbolName:"sun.max",accessibilityDescription:"Headroom Lab")
        log("trial-finished",["message":message,"displays":inventory()])
        refreshCapability()
        if let reportPath {
            do {try JSONSerialization.data(withJSONObject:["records":records,"photometry":"not measured","desktopGain":"requires user observation","mode":trialMode],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:reportPath),options:.atomic)}
            catch {log("report-error",["message":error.localizedDescription])}
        }
        if automatic || terminateAfterStop {DispatchQueue.main.asyncAfter(deadline:.now()+0.5){NSApp.terminate(nil)}}
    }
    func fail(_ message:String) {
        log("error",["message":message])
        if guardian != nil {endTrial(reason:message)} else {finishTrial(message:"Unavailable: \(message)")}
    }
    @objc func quit() {
        terminateAfterStop = true
        if active || starting {endTrial(reason:"App quitting")}
        else if stopping { return }
        else if guardian != nil { beginShutdown(); send(["command":"quit"]); closeGuardianInput() }
        else {NSApp.terminate(nil)}
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if active || starting || stopping || guardian != nil {
            terminateAfterStop = true
            if active || starting { endTrial(reason:"App terminating") }
            else if !stopping { beginShutdown(); send(["command":"quit"]); closeGuardianInput() }
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification:Notification) {closeGuardianInput(); patch?.close()}
}

signal(SIGPIPE,SIG_IGN)
let app = NSApplication.shared
if CommandLine.arguments.contains("--inspect") {
    print(json(["displays":inventory(),"privateAPIs":false,"screenCapture":false])); exit(0)
}
let delegate = Lab()
app.delegate = delegate
app.run()
