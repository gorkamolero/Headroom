import Foundation

// Only linked into the second adapter validation executable. It forces the
// actual production DisplayLuminanceReader through its existing fallback,
// without test switches or runtime swizzling of private Apple classes.
#if HEADROOM_LUMINANCE_FORCE_FALLBACK
struct DisplayLuminanceSystemTelemetry {
    let sdrNits: Double
    let reportedPhysicalNits: Double?
    let reportedHeadroom: Double
    let availableHeadroom: Double
    let maximumHDRNits: Double
}
final class CoreBrightnessLuminanceReader {
    static var attemptCount = 0
    func reading(displayID: UInt32) -> DisplayLuminanceSystemTelemetry? {
        Self.attemptCount += 1
        return nil
    }
}
#endif
