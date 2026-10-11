import AppKit
import ApplicationServices
import DisplayCore

/// An active filter for display-brightness buttons only. Keyboard events are
/// checked only for the two brightness keycodes; every other key passes through
/// immediately without reading its text. No ordinary key data is retained.
/// Ownership and callbacks stay on the main run loop. Permission is requested
/// by the UI, not here.
final class BrightnessKeyTap {
    var handler: ((BrightnessKeyEvent) -> Bool)?
    var interrupted: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var generation = UUID()
    private static let systemDefinedType: UInt32 = 14
    static let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        | (CGEventMask(1) << systemDefinedType)

    @discardableResult
    func start() -> Bool {
        precondition(Thread.isMainThread, "BrightnessKeyTap must be started on the main thread")
        // Checking trust does not prompt. An active filter requires Accessibility
        // approval, unlike a passive Input Monitoring listener.
        guard AXIsProcessTrusted() else { stop(); return false }
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return true }
        stop()

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<BrightnessKeyTap>.fromOpaque(context)
                    .takeUnretainedValue().receive(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            return false
        }

        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        guard CGEvent.tapIsEnabled(tap: newTap) else { stop(); return false }
        return true
    }

    func stop() {
        generation = UUID()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
        tap = nil
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let unchanged = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Do not run recovery or display work inside the synchronous event
            // callback. Until interruption handling finishes, leave keys alone.
            let attempt = generation
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                guard let self, self.generation == attempt else { return }
                self.interrupted?()
                guard self.generation == attempt else { return }
                if type == .tapDisabledByTimeout, AXIsProcessTrusted(), let tap = self.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                } else {
                    self.stop()
                }
            }
            return unchanged
        }
        if type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // Reject ordinary keys before creating NSEvent or reading anything
            // except the virtual keycode. This never reads typed characters.
            guard keyCode == 144 || keyCode == 145,
                  let key = BrightnessKeyEvent.parseKeyboard(
                    keyCode: keyCode,
                    phase: type == .keyDown ? .down : .up,
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    modifierBits: event.flags.rawValue
                  ) else { return unchanged }
            return handler?(key) == true ? nil : unchanged
        }
        guard type.rawValue == Self.systemDefinedType,
              let native = NSEvent(cgEvent: event),
              native.type == .systemDefined,
              let key = BrightnessKeyEvent.parse(
                subtype: Int(native.subtype.rawValue),
                data1: native.data1,
                modifierBits: UInt64(native.modifierFlags.rawValue)
              ) else { return unchanged }
        return handler?(key) == true ? nil : unchanged
    }

    deinit { stop() }
}
