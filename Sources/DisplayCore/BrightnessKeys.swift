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

public enum BrightnessKeyAction: Equatable, Sendable {
    case passthrough
    case consume
    case start(Double)
    case set(Double)
    case stop
}

public enum BrightnessKeyPolicy {
    public static func action(
        event: BrightnessKeyEvent,
        state: BrightnessBoostState,
        factor: Double,
        ceiling: Double,
        normalBrightness: Double?,
        available: Bool
    ) -> BrightnessKeyAction {
        guard event.phase == .down, !event.hasUnsupportedModifiers else { return .passthrough }
        let step = event.fine ? 1.0 / 64 : 1.0 / 16

        switch state {
        case .off:
            // A held key that reached the normal maximum must not enter boost.
            guard available, ceiling.isFinite, ceiling > 1.01,
                  event.direction == .up, !event.isRepeat,
                  let normalBrightness, normalBrightness.isFinite,
                  normalBrightness >= 0.999, normalBrightness <= 1.0001 else { return .passthrough }
            return .start(min(1 + step, ceiling))
        case .preparing, .on:
            guard factor.isFinite, ceiling.isFinite, ceiling > 1.01 else { return .stop }
            let current = min(max(factor, 1), ceiling)
            let next = min(max(current + (event.direction == .up ? step : -step), 1), ceiling)
            if event.direction == .down, next <= 1 { return .stop }
            return next == factor ? .consume : .set(next)
        case .stopping:
            // Wait for restoration instead of changing hardware brightness while
            // the guardian is still restoring the saved transfer tables.
            return .consume
        case .unavailable:
            return .passthrough
        }
    }
}

/// Keeps a held key with the handler that accepted its initial press. A restored
/// Down sequence may return to macOS on the next repeat, without posting events.
public struct BrightnessKeySequence: Sendable {
    private var consumedDirections: Set<BrightnessDirection> = []

    public init() {}

    public mutating func reset() {
        consumedDirections.removeAll()
    }

    public mutating func route(
        event: BrightnessKeyEvent,
        state: BrightnessBoostState,
        factor: Double,
        ceiling: Double,
        normalBrightness: Double?,
        available: Bool
    ) -> BrightnessKeyAction {
        let owned = consumedDirections.contains(event.direction)
        if event.phase == .up {
            consumedDirections.remove(event.direction)
            return owned ? .consume : .passthrough
        }
        guard !event.isRepeat || owned else { return .passthrough }

        let action = BrightnessKeyPolicy.action(
            event: event, state: state, factor: factor, ceiling: ceiling,
            normalBrightness: normalBrightness, available: available
        )
        if action == .passthrough {
            guard owned else { return .passthrough }
            if event.direction == .down, state == .off, event.isRepeat,
               !event.hasUnsupportedModifiers {
                consumedDirections.remove(.down)
                return .passthrough
            }
            return .consume
        }

        consumedDirections.insert(event.direction)
        return action
    }
}
