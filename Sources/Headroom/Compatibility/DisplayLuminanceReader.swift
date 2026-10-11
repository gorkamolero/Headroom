import Foundation
import CoreFoundation
import ObjectiveC
import Darwin

protocol DisplayLuminanceReading {
    /// System-derived native luminance, before Headroom's transfer-table scale.
    /// This is a calculated reference, not a physical light measurement.
    func referenceNits(displayID: UInt32) -> Double?
}

/// Read-only compatibility boundary for Apple's native luminance reporting.
/// The DisplayServices C ABI is published in Lunar's bridging header; the
/// MonitorPanel getter signatures and preset dictionary were independently
/// inspected on the host. No brightness or display preference is changed here.
final class DisplayLuminanceReader: DisplayLuminanceReading {
    private typealias GetLinearBrightness = @convention(c)
        (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias ObjectGetter = @convention(c)
        (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias TryLock = @convention(c) (AnyObject, Selector) -> Bool
    private typealias Unlock = @convention(c) (AnyObject, Selector) -> Void
    private typealias DisplayGetter = @convention(c)
        (AnyObject, Selector, Int32) -> Unmanaged<AnyObject>?

    private let displayServices: UnsafeMutableRawPointer?
    private let monitorPanel: UnsafeMutableRawPointer?
    private let getLinearBrightness: GetLinearBrightness?

    init() {
        let displayServices = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY | RTLD_LOCAL
        )
        self.displayServices = displayServices
        if let displayServices,
           let symbol = dlsym(displayServices, "DisplayServicesGetLinearBrightness") {
            getLinearBrightness = unsafeBitCast(symbol, to: GetLinearBrightness.self)
        } else {
            getLinearBrightness = nil
        }
        monitorPanel = dlopen(
            "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel",
            RTLD_LAZY | RTLD_LOCAL
        )
    }

    func referenceNits(displayID: UInt32) -> Double? {
        guard displayID != 0, let getLinearBrightness else { return nil }
        var linearBrightness = Float.nan
        guard getLinearBrightness(displayID, &linearBrightness) == 0,
              linearBrightness.isFinite, linearBrightness >= 0,
              let maximumSDRNits = maximumSDRNits(displayID: displayID) else {
            return nil
        }
        let nits = Double(linearBrightness) * maximumSDRNits
        return nits.isFinite && nits >= 0 ? nits : nil
    }

    private func maximumSDRNits(displayID: UInt32) -> Double? {
        guard monitorPanel != nil,
              let managerClass = NSClassFromString("MPDisplayMgr"),
              let manager = object(managerClass as AnyObject, selector: "sharedMgr"),
              let tryLockMethod = checkedMethod(manager, selector: "tryLockAccess",
                                                encoding: "B16@0:8"),
              let unlockMethod = checkedMethod(manager, selector: "unlockAccess",
                                               encoding: "v16@0:8"),
              let displayMethod = checkedMethod(manager, selector: "displayWithID:",
                                                encoding: "@20@0:8i16") else {
            return nil
        }

        // Verify the matching unlock before attempting the nonblocking lock.
        // A busy panel manager yields no reading instead of delaying key input.
        let tryLock = unsafeBitCast(method_getImplementation(tryLockMethod), to: TryLock.self)
        guard tryLock(manager, NSSelectorFromString("tryLockAccess")) else { return nil }
        defer {
            let unlock = unsafeBitCast(method_getImplementation(unlockMethod), to: Unlock.self)
            unlock(manager, NSSelectorFromString("unlockAccess"))
        }

        let getDisplay = unsafeBitCast(method_getImplementation(displayMethod), to: DisplayGetter.self)
        guard let display = getDisplay(manager, NSSelectorFromString("displayWithID:"),
                                       Int32(bitPattern: displayID))?.takeUnretainedValue(),
              let preset = object(display, selector: "activePreset"),
              let dictionary = object(preset, selector: "presetDictionary") as? [String: Any],
              let maximum = dictionary["PresetMaxSDRLuminance"] as? NSNumber,
              CFGetTypeID(maximum) != CFBooleanGetTypeID() else { return nil }
        let nits = maximum.doubleValue
        return nits.isFinite && nits > 0 ? nits : nil
    }

    private func object(_ receiver: AnyObject, selector name: String) -> AnyObject? {
        guard let method = checkedMethod(receiver, selector: name, encoding: "@16@0:8") else {
            return nil
        }
        let getter = unsafeBitCast(method_getImplementation(method), to: ObjectGetter.self)
        return getter(receiver, NSSelectorFromString(name))?.takeUnretainedValue()
    }

    /// Fail closed if a future system changes any private method's ABI.
    private func checkedMethod(_ receiver: AnyObject, selector name: String,
                               encoding expected: String) -> Method? {
        guard let receiverClass = object_getClass(receiver),
              let method = class_getInstanceMethod(receiverClass, NSSelectorFromString(name)),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding) == expected else { return nil }
        return method
    }

    deinit {
        if let displayServices { dlclose(displayServices) }
        if let monitorPanel { dlclose(monitorPanel) }
    }
}
