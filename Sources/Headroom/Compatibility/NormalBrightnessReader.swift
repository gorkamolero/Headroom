import Foundation
import Darwin

protocol NormalBrightnessControlling {
    var canSetBrightness: Bool { get }
    func brightness(displayID: UInt32) -> Double?
    @discardableResult func setBrightness(_ value: Double, displayID: UInt32) -> Bool
}

/// Compatibility boundary for the normal hardware-brightness range. The C ABI
/// is independently declared from Lunar's published DisplayServices header:
/// https://github.com/alin23/Lunar/blob/v6.9.5/Lunar/DDC/Lunar-Bridging-Header.h
/// No automatic-brightness or other display preference is changed here.
final class NormalBrightnessReader: NormalBrightnessControlling {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let framework: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightnessFunction: SetBrightness?

    /// Framework capability only. A particular display may still reject a
    /// write; callers must check setBrightness's result and settled readback.
    var canSetBrightness: Bool { getBrightness != nil && setBrightnessFunction != nil }

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
        if let handle, let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightnessFunction = unsafeBitCast(symbol, to: SetBrightness.self)
        } else {
            setBrightnessFunction = nil
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

    /// Requests one absolute hardware level. Success means the private API
    /// accepted the request, not that the display has completed its transition.
    /// Deliberately reject invalid values instead of converting them to black.
    @discardableResult
    func setBrightness(_ value: Double, displayID: UInt32) -> Bool {
        guard displayID != 0, value.isFinite, value >= 0, value <= 1,
              canSetBrightness, let setBrightnessFunction else { return false }
        return setBrightnessFunction(displayID, Float(value)) == 0
    }

    deinit {
        if let framework { dlclose(framework) }
    }
}
