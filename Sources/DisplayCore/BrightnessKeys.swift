public enum BrightnessDirection: Hashable, Sendable {
    case up, down
}

public enum BrightnessKeyPhase: Equatable, Sendable {
    case down, up
}

/// The brightness media-key fields needed by Headroom. No ordinary key content
/// is retained. Display selection and applying the chosen action belong to the UI.
public struct BrightnessKeyEvent: Equatable, Sendable {
    public let direction: BrightnessDirection
    public let phase: BrightnessKeyPhase
    public let isRepeat: Bool
    public let fine: Bool
    public let hasUnsupportedModifiers: Bool

    public init(
        direction: BrightnessDirection,
        phase: BrightnessKeyPhase,
        isRepeat: Bool = false,
        fine: Bool = false,
        hasUnsupportedModifiers: Bool = false
    ) {
        self.direction = direction
        self.phase = phase
        self.isRepeat = isRepeat
        self.fine = fine
        self.hasUnsupportedModifiers = hasUnsupportedModifiers
    }

    public static func parse(subtype: Int, data1: Int, modifierBits: UInt64) -> Self? {
        guard subtype == 8 else { return nil }
        let fields = UInt32(truncatingIfNeeded: data1)
        let direction: BrightnessDirection
        switch fields >> 16 {
        case 2: direction = .up
        case 3: direction = .down
        default: return nil
        }

        let phase: BrightnessKeyPhase
        switch (fields >> 8) & 0xff {
        case 10: phase = .down
        case 11: phase = .up
        default: return nil
        }

        let shift: UInt64 = 1 << 17
        let control: UInt64 = 1 << 18
        let option: UInt64 = 1 << 19
        let command: UInt64 = 1 << 20
        let modifiers = modifierBits & (shift | control | option | command)
        let fine = modifiers == (shift | option)
        return Self(
            direction: direction,
            phase: phase,
            isRepeat: fields & 1 != 0,
            fine: fine,
            hasUnsupportedModifiers: modifiers != 0 && !fine
        )
    }
}

public enum BrightnessBoostState: Equatable, Sendable {
    case off, preparing, on, stopping, unavailable
}

public enum BrightnessAdjustmentMode: Equatable, Sendable {
    case boost, dim

    var nativeHandoffDirection: BrightnessDirection { self == .dim ? .up : .down }
}

public enum BrightnessKeyAction: Equatable, Sendable {
    case passthrough
    case consume
    case start(Double)
    case set(Double)
    case stop
}

public enum BrightnessKeyPolicy {
    /// Keep the backlight at a lit keyboard step. Hardware zero is off on a
    /// MacBook and cannot be usefully darkened with transfer-table scaling.
    public static let dimmingHardwareCeiling = 1.0 / 16 + 0.001

    /// Shared by the cached key decision and the fresh read immediately before
    /// starting a session, so a stale endpoint cannot start the wrong range.
    public static func canStart(mode: BrightnessAdjustmentMode, normalBrightness: Double?,
                                available: Bool, ceiling: Double) -> Bool {
        guard available, let normalBrightness, normalBrightness.isFinite,
              normalBrightness >= 0, normalBrightness <= 1.0001 else { return false }
        switch mode {
        case .boost: return normalBrightness >= 0.999 && ceiling.isFinite && ceiling > 1.01
        case .dim: return normalBrightness > 0 && normalBrightness <= dimmingHardwareCeiling
        }
    }

    public static func action(
        event: BrightnessKeyEvent,
        state: BrightnessBoostState,
        factor: Double,
        ceiling: Double,
        normalBrightness: Double?,
        available: Bool,
        dimmingAvailable: Bool = false,
        mode: BrightnessAdjustmentMode? = nil
    ) -> BrightnessKeyAction {
        guard event.phase == .down, !event.hasUnsupportedModifiers else { return .passthrough }
        let step = event.fine ? 1.0 / 64 : 1.0 / 16

        switch state {
        case .off:
            // A held native key must not cross either hardware endpoint. A new
            // press at the confirmed endpoint opts into the extra range.
            guard !event.isRepeat else { return .passthrough }
            let requestedMode: BrightnessAdjustmentMode = event.direction == .up ? .boost : .dim
            guard canStart(mode: requestedMode, normalBrightness: normalBrightness,
                           available: requestedMode == .dim ? dimmingAvailable : available,
                           ceiling: ceiling) else { return .passthrough }
            return requestedMode == .dim
                ? .start(max(DisplayAdjustmentRange.minimumFactor, 1 - step))
                : .start(min(1 + step, ceiling))
        case .preparing, .on:
            guard factor.isFinite else { return .stop }
            let activeMode = mode ?? (factor < 1 ? .dim : .boost)
            switch activeMode {
            case .dim:
                guard factor > 0, factor <= 1 else { return .stop }
                let current = max(DisplayAdjustmentRange.minimumFactor, factor)
                let next = min(max(current + (event.direction == .up ? step : -step),
                                   DisplayAdjustmentRange.minimumFactor), 1)
                if event.direction == .up, next >= 1 { return .stop }
                return next == factor ? .consume : .set(next)
            case .boost:
                guard ceiling.isFinite, ceiling > 1.01, factor >= 1 else { return .stop }
                let current = min(factor, ceiling)
                let next = min(max(current + (event.direction == .up ? step : -step), 1), ceiling)
                if event.direction == .down, next <= 1 { return .stop }
                return next == factor ? .consume : .set(next)
            }
        case .stopping:
            // Wait for restoration instead of changing hardware brightness while
            // the guardian is still restoring the saved transfer tables.
            return .consume
        case .unavailable:
            return .passthrough
        }
    }
}

/// Keeps a held key with the handler that accepted its initial press. After
/// restoration, Down from boost or Up from dimming returns to macOS on the next
/// repeat, without posting synthetic events.
public struct BrightnessKeySequence: Sendable {
    private var consumedDirections: Set<BrightnessDirection> = []
    private var nativeHandoffDirections: Set<BrightnessDirection> = []
    private var nativeDownHeldAtFloor = false

    public func holdsNativeDownRepeat(_ event: BrightnessKeyEvent) -> Bool {
        nativeDownHeldAtFloor && event.direction == .down && event.phase == .down && event.isRepeat
    }

    public init() {}

    public mutating func reset() {
        consumedDirections.removeAll()
        nativeHandoffDirections.removeAll()
        nativeDownHeldAtFloor = false
    }

    public mutating func route(
        event: BrightnessKeyEvent,
        state: BrightnessBoostState,
        factor: Double,
        ceiling: Double,
        normalBrightness: Double?,
        available: Bool,
        dimmingAvailable: Bool = false,
        mode: BrightnessAdjustmentMode? = nil,
        nativeDownReadPending: Bool = false
    ) -> BrightnessKeyAction {
        let owned = consumedDirections.contains(event.direction)
        if event.phase == .up {
            if event.direction == .down { nativeDownHeldAtFloor = false }
            consumedDirections.remove(event.direction)
            nativeHandoffDirections.remove(event.direction)
            return owned ? .consume : .passthrough
        }
        if holdsNativeDownRepeat(event) { return .consume }
        if event.direction == .down, nativeDownReadPending, !event.hasUnsupportedModifiers {
            // A paused native repeat still needs its key-up delivered to macOS.
            // A fresh press intercepted while a read settles belongs to us.
            if !event.isRepeat {
                consumedDirections.insert(.down)
                nativeHandoffDirections.remove(.down)
            }
            return .consume
        }
        if event.direction == .down, event.isRepeat, !owned, state == .off,
           !event.hasUnsupportedModifiers,
           BrightnessKeyPolicy.canStart(mode: .dim, normalBrightness: normalBrightness,
                                        available: dimmingAvailable, ceiling: ceiling) {
            nativeDownHeldAtFloor = true
            return .consume
        }
        guard !event.isRepeat || owned else { return .passthrough }

        let activeMode = mode ?? (factor < 1 ? .dim : .boost)
        let action = BrightnessKeyPolicy.action(
            event: event, state: state, factor: factor, ceiling: ceiling,
            normalBrightness: normalBrightness, available: available,
            dimmingAvailable: dimmingAvailable, mode: activeMode
        )
        if action == .passthrough {
            guard owned else { return .passthrough }
            if state == .off, event.isRepeat, !event.hasUnsupportedModifiers,
               nativeHandoffDirections.contains(event.direction) {
                consumedDirections.remove(event.direction)
                nativeHandoffDirections.remove(event.direction)
                return .passthrough
            }
            return .consume
        }

        if state == .on || state == .preparing {
            if event.direction == activeMode.nativeHandoffDirection {
                nativeHandoffDirections.insert(event.direction)
            } else {
                nativeHandoffDirections.remove(event.direction)
            }
        }
        consumedDirections.insert(event.direction)
        return action
    }
}
