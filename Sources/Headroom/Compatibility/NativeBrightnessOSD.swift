import Foundation
import ObjectiveC
import Darwin

/// Compatibility boundary for macOS's private, system-rendered brightness OSD.
/// Unsupported runtime signatures disable the indicator without a replacement.
final class NativeBrightnessOSD {
    private typealias SharedManager = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias ShowImage = @convention(c) (
        AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool
    ) -> Void

    private struct Bindings {
        let managerClass: AnyClass
        let sharedSelector: Selector
        let sharedManager: SharedManager
        let showSelector: Selector
        let showImage: ShowImage
    }

    // Objective-C classes and their implementation pointers remain in use for
    // the process lifetime. Never unload this framework beneath those objects.
    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/OSD.framework/OSD",
        RTLD_LAZY | RTLD_LOCAL
    )

    private static let bindings: Bindings? = {
        guard framework != nil, let managerClass = NSClassFromString("OSDManager") else { return nil }
        let sharedSelector = NSSelectorFromString("sharedManager")
        let showSelector = NSSelectorFromString(
            "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
        )
        guard let sharedMethod = class_getClassMethod(managerClass, sharedSelector),
              let showMethod = class_getInstanceMethod(managerClass, showSelector),
              let sharedEncoding = method_getTypeEncoding(sharedMethod),
              let showEncoding = method_getTypeEncoding(showMethod),
              String(cString: sharedEncoding) == "@16@0:8",
              String(cString: showEncoding) == "v48@0:8q16I24I28I32I36I40B44" else {
            return nil
        }
        // The validated B encoding is C _Bool; Swift Bool matches that ABI.
        return Bindings(
            managerClass: managerClass,
            sharedSelector: sharedSelector,
            sharedManager: unsafeBitCast(method_getImplementation(sharedMethod), to: SharedManager.self),
            showSelector: showSelector,
            showImage: unsafeBitCast(method_getImplementation(showMethod), to: ShowImage.self)
        )
    }()

    /// Checks signatures only; it does not create the manager or show anything.
    static var isAvailable: Bool { bindings != nil }

    private var manager: NSObject?

    @discardableResult
    func show(displayID: UInt32, level: Double, durationMilliseconds: UInt32 = 1500) -> Bool {
        guard Thread.isMainThread, displayID != 0, level.isFinite,
              let bindings = Self.bindings else { return false }
        if manager == nil {
            guard let object = bindings.sharedManager(bindings.managerClass, bindings.sharedSelector)?
                .takeUnretainedValue() as? NSObject,
                  object.isKind(of: bindings.managerClass) else { return false }
            manager = object
        }
        guard let manager else { return false }
        let total: UInt32 = 240
        let filled = UInt32((min(1, max(0, level)) * Double(total)).rounded())
        let duration = min(5000, max(100, durationMilliseconds))
        bindings.showImage(manager, bindings.showSelector, 1, displayID, 500, duration, filled, total, false)
        return true
    }
}
