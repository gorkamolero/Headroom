import AppKit
import ApplicationServices
import DisplayCore
import Darwin

enum HeadroomIcon {
    static let off = load("StatusOff")
    static let on = load("StatusOn")
    private static func load(_ name: String) -> NSImage {
        let image = Bundle.main.url(forResource:name,withExtension:"pdf").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName:"circle.circle",accessibilityDescription:"Headroom")!
        image.size = NSSize(width:18,height:18)
        image.isTemplate = true
        image.accessibilityDescription = "Headroom"
        return image
    }
}

final class DisplayRow:NSView {
    static let rowWidth: CGFloat = 272
    static let rowHeight: CGFloat = 90
    let name = NSTextField(labelWithString:"")
    let detail = NSTextField(labelWithString:"")
    let toggle = NSSwitch()
    let slider = NSSlider(value:1,minValue:DisplayAdjustmentRange.minimumFactor,maxValue:2,target:nil,action:nil)
    weak var session: BoostSession?
    override var allowsVibrancy: Bool { true }

    init(session:BoostSession) {
        self.session = session
        super.init(frame:NSRect(x:0,y:0,width:Self.rowWidth,height:Self.rowHeight))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(session.screen.localizedName)
        name.font = .systemFont(ofSize:13,weight:.medium)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        detail.font = .systemFont(ofSize:11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        toggle.controlSize = .small
        toggle.target = self;toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel("Brightness adjustment for \(session.screen.localizedName)")
        slider.controlSize = .small
        slider.target = self;slider.action = #selector(slid);slider.isContinuous = true
        slider.setAccessibilityLabel("Brightness level for \(session.screen.localizedName)")
        let low = NSImageView(), high = NSImageView()
        low.image = NSImage(systemSymbolName:"sun.min",accessibilityDescription:"Dimmer")
        high.image = NSImage(systemSymbolName:"sun.max.fill",accessibilityDescription:"Brighter")
        for icon in [low,high] {icon.contentTintColor = .secondaryLabelColor;icon.imageScaling = .scaleProportionallyDown}
        for view in [name,detail,toggle,slider,low,high] {view.translatesAutoresizingMaskIntoConstraints = false;addSubview(view)}
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo:leadingAnchor,constant:14),name.topAnchor.constraint(equalTo:topAnchor,constant:10),name.trailingAnchor.constraint(lessThanOrEqualTo:toggle.leadingAnchor,constant:-8),
            toggle.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-12),toggle.centerYAnchor.constraint(equalTo:name.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo:name.leadingAnchor),detail.topAnchor.constraint(equalTo:name.bottomAnchor,constant:3),detail.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-14),
            low.leadingAnchor.constraint(equalTo:name.leadingAnchor),low.widthAnchor.constraint(equalToConstant:13),low.heightAnchor.constraint(equalToConstant:13),
            high.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-14),high.widthAnchor.constraint(equalToConstant:17),high.heightAnchor.constraint(equalToConstant:17),
            slider.leadingAnchor.constraint(equalTo:low.trailingAnchor,constant:8),slider.trailingAnchor.constraint(equalTo:high.leadingAnchor,constant:-8),slider.topAnchor.constraint(equalTo:detail.bottomAnchor,constant:8),slider.heightAnchor.constraint(equalToConstant:20),
            low.centerYAnchor.constraint(equalTo:slider.centerYAnchor),high.centerYAnchor.constraint(equalTo:slider.centerYAnchor)
        ])
        refresh()
    }
    required init?(coder:NSCoder){fatalError()}
    @objc func toggled(){session?.toggle();refresh()}
    @objc func slid(){session?.setLevel(slider.doubleValue)}
    func refresh(){
        guard let session else{return}
        name.stringValue = session.screen.localizedName
        detail.stringValue = session.message
        detail.toolTip = session.detail
        detail.setAccessibilityValue(session.detail)
        detail.textColor = session.state == .unavailable ? .systemOrange : .secondaryLabelColor
        toggle.state = session.enabled ? .on : .off
        toggle.isEnabled = session.state != .stopping && (session.enabled || session.supportsBoost || session.supportsDimming)
        slider.minValue = session.minimumFactor;slider.maxValue = session.maximumFactor
        slider.doubleValue = session.desiredFactor
        slider.isEnabled = session.state != .stopping && (session.supportsBoost || session.supportsDimming)
    }
}

final class HeadroomDelegate:NSObject,NSApplicationDelegate,NSMenuDelegate {
    var status:NSStatusItem!
    let menu = NSMenu()
    var sessions = [String:BoostSession]()
    var rows = [String:DisplayRow]()
    var timer:Timer?
    var observers = [NSObjectProtocol]()
    var terminating = false
    var recoveryRequested = false
    var connectedUUIDs = Set<String>()
    let recoveryRoot = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Headroom/Recovery",isDirectory:true)
    let recoveryNotice = NSTextField(wrappingLabelWithString:"")
    lazy var brightnessKeys = BrightnessKeyController { [weak self] in Array(self?.sessions.values ?? [:].values) }
    var keysStatusItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification:Notification){
        if let identifier = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier:identifier).first(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) {
            running.activate(options:[])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        status.button?.image = HeadroomIcon.off
        status.button?.setAccessibilityLabel("Headroom brightness")
        status.button?.toolTip = "Headroom · off"
        menu.autoenablesItems = false
        menu.minimumWidth = DisplayRow.rowWidth
        menu.delegate = self
        status.menu = menu
        recoverDisconnectedJournals()
        rebuild()
        brightnessKeys.changed = { [weak self] in self?.updateKeyMenu() }
        brightnessKeys.startMonitoring()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in self?.reconcile()})
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.screensDidSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in self?.brightnessKeys.suspend();self?.stopAll("Paused after sleep or lock")})
        }
        for name in [NSWorkspace.didWakeNotification,NSWorkspace.screensDidWakeNotification,NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in self?.stopAll("Paused after wake — turn on to resume");self?.reconcile();self?.brightnessKeys.resume()})
        }
        let t = Timer(timeInterval:1,repeats:true){[weak self] _ in
            guard let self else{return}
            let now = ProcessInfo.processInfo.systemUptime
            for session in self.sessions.values {session.tick(now:now)}
            if self.recoveryRequested && !self.sessions.values.contains(where:{$0.busy}) {
                self.recoveryRequested = false
                for session in self.sessions.values {session.recover();session.refreshAvailability()}
                self.recoverDisconnectedJournals()
                self.rebuild()
            }
            self.updateState()
            if self.terminating && !self.sessions.values.contains(where:{$0.busy}) {NSApp.reply(toApplicationShouldTerminate:true)}
        }
        timer = t;RunLoop.main.add(t,forMode:.common)
        // Explicit restart handoff only; ordinary launches always remain off.
        if let option = CommandLine.arguments.firstIndex(of:"--resume-display"), CommandLine.arguments.indices.contains(option+1),
           let session = sessions[CommandLine.arguments[option+1]] {session.start()}
        if CommandLine.arguments.contains("--show") {RunLoop.main.perform(inModes:[.default]) {self.show()}}
    }
    func applicationShouldHandleReopen(_ sender:NSApplication, hasVisibleWindows flag:Bool)->Bool {
        RunLoop.main.perform(inModes:[.default]) {self.show()}
        return false
    }
    func menuWillOpen(_ menu:NSMenu) {reconcile();print("{\"event\":\"menu-open\"}");fflush(stdout)}
    func menuDidClose(_ menu:NSMenu) {print("{\"event\":\"menu-close\"}");fflush(stdout)}
    func recoverDisconnectedJournals(){
        guard let dirs = try? FileManager.default.contentsOfDirectory(at:recoveryRoot,includingPropertiesForKeys:nil) else{return}
        var pending = 0
        for dir in dirs where UUID(uuidString:dir.lastPathComponent) != nil {
            do {let store = try RecoveryStore(directory:dir);pending += store.recoverAll().filter{!$0.succeeded}.count}
            catch {pending += 1}
        }
        recoveryNotice.stringValue = pending>0 ? "An earlier display session needs recovery. Reconnect its display and reopen Headroom." : ""
    }
    func reconcile(){
        brightnessKeys.cancelPending()
        let connected = Set(NSScreen.screens.compactMap{try? DisplayIdentity.capture(display:screenID($0)).uuid})
        for (uuid,session) in sessions where !connected.contains(uuid) {
            if session.busy {session.stop(reason:"Display disconnected")}
        }
        for screen in NSScreen.screens {
            guard let identity = try? DisplayIdentity.capture(display:screenID(screen)) else{continue}
            if let existing = sessions[identity.uuid] {existing.updateScreen(screen, reconnected: !connectedUUIDs.contains(identity.uuid))}
            else {
                let session = BoostSession(screen:screen,identity:identity,directory:recoveryRoot.appendingPathComponent(identity.uuid,isDirectory:true))
                session.changed = {[weak self] in self?.updateState()};sessions[identity.uuid] = session
            }
        }
        connectedUUIDs = connected
        let shown = Set(rows.keys)
        if connected != shown {rebuild()} else {updateState()}
    }
    func rebuild(){
        menu.removeAllItems()
        rows = [:]
        for screen in NSScreen.screens {
            guard let identity = try? DisplayIdentity.capture(display:screenID(screen)) else{continue}
            if sessions[identity.uuid] == nil {
                let session = BoostSession(screen:screen,identity:identity,directory:recoveryRoot.appendingPathComponent(identity.uuid,isDirectory:true))
                session.changed = {[weak self] in self?.updateState()};sessions[identity.uuid] = session
            }
            guard let session = sessions[identity.uuid] else{continue}
            session.screen = screen
            if !rows.isEmpty {menu.addItem(.separator())}
            let row = DisplayRow(session:session)
            rows[identity.uuid] = row
            let item = NSMenuItem();item.view = row
            menu.addItem(item)
        }
        if rows.isEmpty {
            let empty = NSMenuItem(title:"No displays available",action:nil,keyEquivalent:"")
            empty.isEnabled = false;menu.addItem(empty)
        }
        menu.addItem(.separator())
        if !recoveryNotice.stringValue.isEmpty {
            let recovery = NSMenuItem(title:"Display recovery needs attention…",action:#selector(showInfo),keyEquivalent:"")
            recovery.target = self
            recovery.image = NSImage(systemSymbolName:"exclamationmark.triangle",accessibilityDescription:nil)
            menu.addItem(recovery)
        }
        if rows.count > 1 {
            let off = NSMenuItem(title:"Turn All Off",action:#selector(turnAllOff),keyEquivalent:"")
            off.target = self;menu.addItem(off)
        }
        let keyStatus = NSMenuItem(title:"",action:#selector(openKeyPermissions),keyEquivalent:"")
        keyStatus.target = self;menu.addItem(keyStatus);keysStatusItem = keyStatus
        updateKeyMenu()
        let more = NSMenuItem(title:"More",action:nil,keyEquivalent:"")
        let details = NSMenu();details.autoenablesItems = false
        let about = NSMenuItem(title:"About Headroom…",action:#selector(showInfo),keyEquivalent:"")
        about.target = self;details.addItem(about)
        let recovery = NSMenuItem(title:"Turn Off and Retry Recovery",action:#selector(retryRecovery),keyEquivalent:"")
        recovery.target = self;details.addItem(recovery)
        more.submenu = details;menu.addItem(more)
        let quit = NSMenuItem(title:"Quit Headroom",action:#selector(quitApp),keyEquivalent:"q")
        quit.target = self;menu.addItem(quit)
        connectedUUIDs = Set(rows.keys)
        updateState()
    }
    func updateState(){
        for row in rows.values {row.refresh()}
        let on = sessions.values.filter{$0.enabled}.count
        status?.button?.image = on>0 ? HeadroomIcon.on : HeadroomIcon.off
        status?.button?.toolTip = on>0 ? "Headroom · \(on) display\(on == 1 ? "":"s") on" : "Headroom · off"
        status?.button?.setAccessibilityValue(on>0 ? "Brightness adjustment on" : "Brightness adjustment off")
    }
    func updateKeyMenu() {
        keysStatusItem?.title = brightnessKeys.message
        keysStatusItem?.isHidden = brightnessKeys.message.isEmpty
        keysStatusItem?.isEnabled = brightnessKeys.permissionRequired
    }
    @objc func openKeyPermissions() {
        RunLoop.main.perform(inModes:[.default]) {self.brightnessKeys.openAccessibilitySettings()}
    }
    @objc func show(){
        reconcile()
        NSApp.activate(ignoringOtherApps:true)
        status.button?.performClick(nil)
    }
    @objc func showInfo(){
        let alert = NSAlert()
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "Development"
        alert.messageText = "Headroom \(version)"
        alert.informativeText = "Extra dimming and more brightness from compatible displays.\nBy Gorka Molero · Community beta\n\nYour original display settings are saved before adjustment and checked when restored. Headroom runs locally, without screen recording, accounts or analytics.\n\nBrightness and compatibility depend on your Mac and its settings. Physical luminance, colour accuracy and battery impact have not been measured." + (recoveryNotice.stringValue.isEmpty ? "" : "\n\n" + recoveryNotice.stringValue)
        if let icon = Bundle.main.url(forResource:"AppIcon",withExtension:"icns").flatMap(NSImage.init(contentsOf:)) {alert.icon = icon}
        alert.addButton(withTitle:"Done")
        alert.addButton(withTitle:"Project & Help")
        NSApp.activate(ignoringOtherApps:true)
        if alert.runModal() == .alertSecondButtonReturn, let url = URL(string:"https://github.com/gorkamolero/Headroom") {NSWorkspace.shared.open(url)}
    }
    @objc func retryRecovery(){recoveryRequested = true;stopAll("Restoring display settings…")}
    func stopAll(_ reason:String){brightnessKeys.cancelPending();for session in sessions.values where session.busy {session.stop(reason:reason)};updateState()}
    @objc func turnAllOff(){stopAll("Off")}
    @objc func quitApp(){NSApp.terminate(nil)}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        brightnessKeys.shutdown()
        if sessions.values.contains(where:{$0.busy}) {terminating = true;stopAll("Off");return .terminateLater}
        return .terminateNow
    }
}

signal(SIGPIPE,SIG_IGN)
let application = NSApplication.shared
if CommandLine.arguments.contains("--diagnose-brightness-keys") {
    let reader = NormalBrightnessReader()
    let displays: [[String:Any]] = NSScreen.screens.map { screen in
        ["name": screen.localizedName, "builtIn": CGDisplayIsBuiltin(screenID(screen)) != 0,
         "normalBrightness": reader.brightness(displayID:screenID(screen)).map { $0 as Any } ?? NSNull()]
    }
    var tapCount: UInt32 = 0
    var activeTap = false
    let runningPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier:"local.gorka.Headroom").map(\.processIdentifier))
    if CGGetEventTapList(0,nil,&tapCount) == .success, tapCount > 0 {
        let taps = UnsafeMutablePointer<CGEventTapInformation>.allocate(capacity:Int(tapCount))
        defer { taps.deallocate() }
        var returned: UInt32 = 0
        if CGGetEventTapList(tapCount,taps,&returned) == .success {
            for index in 0..<Int(min(returned,tapCount)) {
                let tap = taps[index]
                if runningPIDs.contains(tap.tappingProcess), tap.enabled,
                   tap.options == .defaultTap, tap.eventsOfInterest == (1 << 14) { activeTap = true }
            }
        }
    }
    // A CLI invocation can be attributed to its terminal/agent by TCC. The
    // GUI's enabled event tap is stronger evidence than this process's AX bit.
    let report: [String:Any] = ["diagnosticProcessAccessibility": AXIsProcessTrusted(),
        "runningAppBrightnessTapEnabled": activeTap,
        "brightnessIndicator": "appKitGlassPanel", "displays": displays]
    if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
        print(String(decoding:data,as:UTF8.self))
    }
    exit(0)
}
let delegate = HeadroomDelegate()
application.delegate = delegate
application.run()
