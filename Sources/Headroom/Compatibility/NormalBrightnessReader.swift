import Foundation
import Darwin

/// The only private display API used for keyboard integration. It reads the
/// normal brightness slider so macOS can continue handling the 0...100% range.
/// No brightness setter or automatic-brightness preference is accessed.
final class NormalBrightnessReader {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private let framework: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?

    init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY | RTLD_LOCAL
        )
        framework = handle
        if let handle, let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
        } else {
            getBrightness = nil
        }
    }

    /// Nil means unsupported or unreadable, never an inferred brightness value.
    func brightness(displayID: UInt32) -> Double? {
        guard displayID != 0, let getBrightness else { return nil }
        var value = Float.nan
        guard getBrightness(displayID, &value) == 0,
              value.isFinite,
              value >= -0.0001, value <= 1.0001 else { return nil }
        return min(1, max(0, Double(value)))
    }

    deinit {
        if let framework { dlclose(framework) }
    }
}
