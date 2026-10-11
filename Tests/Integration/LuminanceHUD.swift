import AppKit
import DisplayCore

/// Read-only test of the production reader and HUD. This never changes a
/// display setting, posts keyboard input, or requests Accessibility access.
@main
enum LuminanceHUDCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let reader = DisplayLuminanceReader()
        let hud = BrightnessHUD()
        var timers: [Timer] = []
        var checks: [String: Bool] = [:]
        var reads = 0
        var reference = 400.2
        var appliedFactor = 1.0
        var boostActive = false
        var headroom = 3.0
        var readsAtHide = 0
        func after(_ delay: Double, _ body: @escaping () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in body() }
            timers.append(timer)
            RunLoop.main.add(timer, forMode: .common)
        }
        func panel() -> NSWindow? { app.windows.first { $0.title == "Headroom Brightness" } }
        DispatchQueue.main.async {
            guard let screen = NSScreen.main else { exit(2) }
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            let liveNits = reader.referenceNits(displayID: displayID)
            let baseline = try? GammaTable.read(display: displayID)
            func show() {
                hud.show(screen: screen, presentation: BrightnessHUDPresentation(
                    title: boostActive ? "Display +" : "Display", level: boostActive ? 0.9375 : 0.5,
                    lowerBoundary: 0.125, upperBoundary: 0.875,
                    luminance: DisplayLuminance(referenceNits: reference, appliedFactor: appliedFactor,
                        boostActive: boostActive, boostContext: .init(currentHeadroom: headroom,
                            maximumHDRNits: 1600))),
                    readLuminance: {
                        reads += 1
                        return DisplayLuminance(referenceNits: reference, appliedFactor: appliedFactor,
                            boostActive: boostActive, boostContext: .init(currentHeadroom: headroom,
                                maximumHDRNits: 1600))
                    })
            }
            show()
            after(0.2) {
                checks["visible"] = panel()?.isVisible == true
                checks["doesNotTakeFocus"] = panel()?.isKeyWindow == false
                checks["clickThrough"] = panel()?.ignoresMouseEvents == true
                checks["nativeReadout"] = hud.presentation?.luminance.text == "≈400 nits"
                reference = 200
            }
            after(0.45) {
                checks["updatesWithoutAnotherKeyEvent"] = hud.presentation?.luminance.text == "≈200 nits"
                appliedFactor = 0.5
            }
            after(0.7) {
                checks["dimmingEstimateUpdates"] = hud.presentation?.luminance.text == "≈43 nits"
                hud.hide()
                readsAtHide = reads
            }
            after(0.95) {
                checks["hiddenStopsPolling"] = reads == readsAtHide
                appliedFactor = 1
                reference = 400.2
                show()
            }
            after(1.15) {
                boostActive = true
                appliedFactor = 1.5
                show()
            }
            after(1.4) {
                checks["boostCapacityNotCurrentNits"] = hud.presentation?.luminance.text == "HDR ≤1201 nits"
                    && hud.presentation?.luminance.nits == nil
                checks["capacityLabelFitsExistingHUD"] = ("HDR ≤1600 nits" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)]).width <= 124
                checks["boostLabel"] = hud.presentation?.title == "Display +"
                headroom = 2
            }
            after(1.65) {
                checks["fallingHeadroomUpdatesWithoutKeyEvent"] = hud.presentation?.luminance.text == "HDR ≤800 nits"
                headroom = 1
            }
            after(1.9) {
                checks["noHeadroomOnlyShowsSDRCapacity"] = hud.presentation?.luminance.text == "HDR ≤400 nits"
                boostActive = false
                appliedFactor = 1
                show()
            }
            after(3.7) {
                checks["autoDismissed"] = panel()?.isVisible == false
                readsAtHide = reads
            }
            after(3.95) {
                checks["dismissedStopsPolling"] = reads == readsAtHide
                checks["panelReused"] = app.windows.filter { $0.title == "Headroom Brightness" }.count == 1
                checks["invalidDisplayUnavailable"] = reader.referenceNits(displayID: 0) == nil
                if let baseline, let actual = try? GammaTable.read(display: displayID) {
                    checks["displayTablesUnchanged"] = actual.maxDifference(from: baseline) == 0
                }
                let result: [String: Any] = ["checks": checks,
                    "allPassed": checks.values.allSatisfy { $0 },
                    "liveReferenceNits": liveNits as Any? ?? NSNull(),
                    "physicalLuminanceMeasured": false]
                let output = ProcessInfo.processInfo.environment["HEADROOM_NITS_TEST_OUTPUT"]
                    .map { URL(fileURLWithPath: $0) }
                    ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("hud-check.json")
                try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
                hud.showPreview(screen: screen, level: 0.875, duration: 12,
                    luminance: DisplayLuminance(referenceNits: liveNits, appliedFactor: 1))
            }
            after(17) { hud.hide(); app.terminate(nil) }
        }
        app.run()
    }
}
