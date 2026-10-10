import AppKit

/// Uses macOS's own brightness indicator. The menu holds status and error text.
final class BrightnessHUD {
    private let indicator = NativeBrightnessOSD()

    func show(screen: NSScreen, factor: Double, maximum: Double,
              preparing: Bool = false, message: String? = nil) {
        guard factor.isFinite, maximum.isFinite,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return
        }
        // Boost uses a fresh range above normal maximum. Leaving boost shows
        // normal maximum before the system resumes ordinary brightness keys.
        let level = factor > 1 && maximum > 1 ? (factor - 1) / (maximum - 1) : 1
        indicator.show(displayID: number.uint32Value, level: level)
    }

    func hide() {
        // macOS fades its own indicator. A global hide could dismiss the
        // indicator belonging to a subsequent, ordinary brightness-key event.
    }
}
