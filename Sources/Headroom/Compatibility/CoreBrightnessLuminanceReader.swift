import Foundation
import CoreFoundation
import ObjectiveC
import Darwin

/// A single per-display CoreBrightness status response. The system's field
/// named NitsPhysical is telemetry, not an optical measurement of the desktop.
struct DisplayLuminanceSystemTelemetry {
    /// EDR state's SDR basis, which can stay fixed as native brightness changes.
    /// This must not be substituted for the current native luminance reading.
    let sdrNits: Double
    let reportedPhysicalNits: Double?
    let reportedHeadroom: Double
    let availableHeadroom: Double
    let maximumHDRNits: Double
}

/// Read-only private API boundary. Method signatures were inspected at runtime
/// and the returned fields cross-checked against Apple's corebrightnessdiag
/// status-info output. No property setters, observers, or display writes exist
/// here. The ordinary DisplayServices/MonitorPanel path remains the fallback.
final class CoreBrightnessLuminanceReader {
    private typealias CopyDisplayProperty = @convention(c)
        (AnyObject, Selector, NSString, UInt64) -> Unmanaged<AnyObject>?

    private let framework: UnsafeMutableRawPointer?
    private var client: NSObject?
    private let copyDisplayProperty: CopyDisplayProperty?
    private let selector = NSSelectorFromString("copyPropertyForKey:andDisplay:")

    init() {
        framework = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_LAZY | RTLD_LOCAL)
        guard framework != nil,
              let clientClass = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
              Self.checkedMethod(clientClass, "init", encoding: "@16@0:8") != nil,
              let method = Self.checkedMethod(clientClass,
                  "copyPropertyForKey:andDisplay:", encoding: "@32@0:8@16Q24") else {
            client = nil
            copyDisplayProperty = nil
            return
        }
        copyDisplayProperty = unsafeBitCast(method_getImplementation(method),
                                           to: CopyDisplayProperty.self)
        client = clientClass.init()
    }

    func reading(displayID: UInt32) -> DisplayLuminanceSystemTelemetry? {
        guard displayID != 0, let client, let copyDisplayProperty,
              let status = copyDisplayProperty(client, selector, "StatusInfo", UInt64(displayID))?
                .takeRetainedValue() as? [String: Any] else { return nil }
        return Self.telemetry(from: status, displayID: displayID)
    }

    static func telemetry(from status: [String: Any],
                          displayID: UInt32) -> DisplayLuminanceSystemTelemetry? {
        guard displayID != 0,
              let display = status["Display"] as? [String: Any],
              let identity = display["CBDisplayInfo"] as? [String: Any],
              let returnedID = Self.number(identity["CBDisplayInfoDisplayID"]),
              returnedID == Double(displayID),
              let edr = display["EDRState"] as? [String: Any],
              let sdr = Self.number(edr["SDR"], in: 0...10_000),
              let current = Self.number(edr["Headroom"], in: 1...1_024),
              let available = Self.number(edr["AvailableHeadroom"], in: 1...1_024),
              let maximum = Self.number(edr["HDRMax"], in: Double.leastNonzeroMagnitude...10_000),
              sdr <= maximum else { return nil }

        return DisplayLuminanceSystemTelemetry(
            sdrNits: sdr,
            reportedPhysicalNits: Self.number(display["NitsPhysical"], in: 0...maximum),
            reportedHeadroom: current,
            availableHeadroom: available,
            maximumHDRNits: maximum)
    }

    private static func number(_ value: Any?, in range: ClosedRange<Double>? = nil) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, range?.contains(value) ?? true else { return nil }
        return value
    }

    private static func checkedMethod(_ cls: AnyClass, _ name: String,
                                      encoding expected: String) -> Method? {
        guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding) == expected else { return nil }
        return method
    }

    deinit {
        // Release the private client while its framework is still loaded.
        client = nil
        if let framework { dlclose(framework) }
    }
}
