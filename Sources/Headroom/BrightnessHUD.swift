import AppKit

/// macOS draws the indicator, including the current system's glass, symbols,
/// typography and animation. Status and errors remain in Headroom's menu.
final class BrightnessHUD {
    private let indicator = NativeBrightnessOSD()

    func show(screen: NSScreen, factor: Double, maximum: Double,
              preparing: Bool = false, message: String? = nil) {
        guard factor.isFinite, maximum.isFinite,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return
        }
        // Keep downward movement continuous through the end of boost. This is
        // a control position, not a luminance measurement. Native-range keys
        // subsequently let macOS update this same indicator on its own scale.
        indicator.show(displayID: number.uint32Value, level: factor / max(1, maximum))
    }

    func hide() {
        // macOS owns the lifetime. Globally hiding the system indicator could
        // dismiss feedback from a subsequent native brightness-key event.
    }
}
