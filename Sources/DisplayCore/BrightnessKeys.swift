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
            // Continue a held brightness key through a confirmed hardware
            // endpoint into the extra range without requiring another press.
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

/// Routes continuous held-key movement across native, dimming, and boost
/// ranges. macOS must receive the release whenever it received an earlier Down,
/// even when Headroom subsequently captured repeats at a hardware endpoint.
public struct BrightnessKeySequence: Sendable {
    private var consumedDirections: Set<BrightnessDirection> = []
    private var nativeDirections: Set<BrightnessDirection> = []
    private var nativeHandoffDirections: Set<BrightnessDirection> = []
    private var deferredDirections: Set<BrightnessDirection> = []
    private var releasedDirections: Set<BrightnessDirection> = []

    public init() {}

    public mutating func reset() {
        consumedDirections.removeAll()
        nativeDirections.removeAll()
        nativeHandoffDirections.removeAll()
        deferredDirections.removeAll()
        releasedDirections.removeAll()
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
        if event.phase == .up {
            let releaseIsOurs = consumedDirections.contains(event.direction)
                && !nativeDirections.contains(event.direction)
            consumedDirections.remove(event.direction)
            nativeDirections.remove(event.direction)
            nativeHandoffDirections.remove(event.direction)
            deferredDirections.remove(event.direction)
            releasedDirections.insert(event.direction)
            return releaseIsOurs ? .consume : .passthrough
        }
        if !event.isRepeat {
            consumedDirections.remove(event.direction)
            nativeDirections.remove(event.direction)
            nativeHandoffDirections.remove(event.direction)
            deferredDirections.remove(event.direction)
            releasedDirections.remove(event.direction)
        } else if releasedDirections.contains(event.direction) {
            // A queued repeat after release must not restart an adjustment.
            return .passthrough
        }
        let owned = consumedDirections.contains(event.direction)
        if event.isRepeat, !owned {
            // Monitoring can begin in the middle of a native key sequence.
            nativeDirections.insert(event.direction)
        }
        if event.direction == .down, nativeDownReadPending, !event.hasUnsupportedModifiers {
            if !event.isRepeat {
                consumedDirections.insert(.down)
                deferredDirections.insert(.down)
            }
            return .consume
        }
        if owned, state == .off, event.isRepeat, !deferredDirections.contains(event.direction) {
            // Resume native movement only after the corresponding restoration.
            // An unexpected stop must not silently restart the same session.
            if !event.hasUnsupportedModifiers, nativeHandoffDirections.contains(event.direction) {
                consumedDirections.remove(event.direction)
                nativeHandoffDirections.remove(event.direction)
                nativeDirections.insert(event.direction)
                return .passthrough
            }
            return .consume
        }

        let activeMode = mode ?? (factor < 1 ? .dim : .boost)
        let action = BrightnessKeyPolicy.action(
            event: event, state: state, factor: factor, ceiling: ceiling,
            normalBrightness: normalBrightness, available: available,
            dimmingAvailable: dimmingAvailable, mode: activeMode
        )
        if action == .passthrough {
            if owned, !deferredDirections.contains(event.direction) { return .consume }
            consumedDirections.remove(event.direction)
            deferredDirections.remove(event.direction)
            nativeDirections.insert(event.direction)
            return .passthrough
        }
        deferredDirections.remove(event.direction)
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
