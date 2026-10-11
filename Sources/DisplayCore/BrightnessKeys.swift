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

        return decoded(direction: direction, phase: phase,
                       isRepeat: fields & 1 != 0, modifierBits: modifierBits)
    }

    /// Some keyboards deliver brightness as ordinary keyDown/keyUp events.
    /// The narrow 144/145 mapping is documented in Lunar's pinned dependency:
    /// https://github.com/alin23/MediaKeyTap/blob/5b8ee686bc90d917cba4f029b47c2a8541a4f58d/MediaKeyTap/MediaKeyTap.swift#L122-L129
    /// F14/F15 and every other key retain their existing meaning.
    public static func parseKeyboard(keyCode: Int64, phase: BrightnessKeyPhase,
                                     isRepeat: Bool, modifierBits: UInt64) -> Self? {
        let direction: BrightnessDirection
        switch keyCode {
        case 144: direction = .up
        case 145: direction = .down
        default: return nil
        }
        return decoded(direction: direction, phase: phase,
                       isRepeat: isRepeat, modifierBits: modifierBits)
    }

    private static func decoded(direction: BrightnessDirection, phase: BrightnessKeyPhase,
                                isRepeat: Bool, modifierBits: UInt64) -> Self {
        let shift: UInt64 = 1 << 17
        let control: UInt64 = 1 << 18
        let option: UInt64 = 1 << 19
        let command: UInt64 = 1 << 20
        let modifiers = modifierBits & (shift | control | option | command)
        let fine = modifiers == (shift | option)
        return Self(
            direction: direction,
            phase: phase,
            isRepeat: isRepeat,
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
}

public enum BrightnessKeyAction: Equatable, Sendable {
    case passthrough
    case consume
    case setNative(Double)
    case start(Double)
    case set(Double)
    case stop
}

public enum BrightnessKeyPolicy {
    /// Keep the native backlight lit before applying software dimming.
    public static let hardwareFloor = 0.01
    private static let endpointTolerance = 0.0001

    public static func canStart(mode: BrightnessAdjustmentMode, normalBrightness: Double?,
                                available: Bool, ceiling: Double) -> Bool {
        guard available, let normalBrightness, normalBrightness.isFinite,
              normalBrightness >= 0, normalBrightness <= 1 + endpointTolerance else { return false }
        switch mode {
        case .boost:
            return normalBrightness >= 1 - endpointTolerance && ceiling.isFinite && ceiling > 1.01
        case .dim:
            return normalBrightness > 0 && normalBrightness <= hardwareFloor + endpointTolerance
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
        mode: BrightnessAdjustmentMode? = nil,
        nativeAvailable: Bool = true
    ) -> BrightnessKeyAction {
        guard event.phase == .down, !event.hasUnsupportedModifiers else { return .passthrough }
        // Loss of native control must never send hardware changes through while
        // the guardian is still restoring the saved gamma tables.
        if state == .stopping { return .consume }
        guard nativeAvailable else { return .passthrough }
        let step = event.fine ? 1.0 / 64 : 1.0 / 16
        switch state {
        case .off, .unavailable:
            guard let normalBrightness, normalBrightness.isFinite,
                  normalBrightness >= 0, normalBrightness <= 1 + endpointTolerance else { return .passthrough }
            let normal = min(1, normalBrightness)
            switch event.direction {
            case .up:
                if normal < 1 - endpointTolerance {
                    let next = min(1, normal + step)
                    // Hardware readbacks use Float precision. Exact endpoints
                    // let the controller recognize arrival and arm its detent.
                    return .setNative(next >= 1 - endpointTolerance ? 1 : next)
                }
                if state == .off, canStart(mode: .boost, normalBrightness: normal,
                                          available: available, ceiling: ceiling) {
                    return .start(min(1 + step, ceiling))
                }
                return .consume
            case .down:
                if normal > hardwareFloor + endpointTolerance {
                    let next = max(hardwareFloor, normal - step)
                    return .setNative(next <= hardwareFloor + endpointTolerance ? hardwareFloor : next)
                }
                if state == .off, canStart(mode: .dim, normalBrightness: normal,
                                          available: dimmingAvailable, ceiling: ceiling) {
                    return .start(max(DisplayAdjustmentRange.minimumFactor, 1 - step))
                }
                // Hardware zero is already off. Never increase it on Down.
                return .consume
            }
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
            // Hardware changes wait until the guardian restores the original
            // gamma tables. The next repeat then resumes native movement.
            return .consume
        }
    }
}

/// Headroom owns supported brightness-key sequences throughout the native and
/// software ranges. A release still reaches macOS if an earlier fallback event
/// in that same sequence was passed through.
public struct BrightnessKeySequence: Sendable {
    private var consumedDirections: Set<BrightnessDirection> = []
    private var nativeDirections: Set<BrightnessDirection> = []
    private var releasedDirections: Set<BrightnessDirection> = []

    public init() {}

    public mutating func reset() {
        // Cancellation must not restart a held adjustment on its next repeat.
        releasedDirections.formUnion(consumedDirections)
        releasedDirections.formUnion(nativeDirections)
        // Keep both kinds of release obligations until key-up or a fresh press.
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
        nativeAvailable: Bool = true
    ) -> BrightnessKeyAction {
        if event.phase == .up {
            let releaseIsOurs = consumedDirections.contains(event.direction)
                && !nativeDirections.contains(event.direction)
            consumedDirections.remove(event.direction)
            nativeDirections.remove(event.direction)
            releasedDirections.insert(event.direction)
            return releaseIsOurs ? .consume : .passthrough
        }
        if !event.isRepeat {
            consumedDirections.remove(event.direction)
            nativeDirections.remove(event.direction)
            releasedDirections.remove(event.direction)
        } else if releasedDirections.contains(event.direction) {
            return .consume
        }
        let owned = consumedDirections.contains(event.direction)
        if event.isRepeat, !owned {
            // If monitoring starts mid-hold, assume the original press reached
            // macOS so its eventual release cannot leave a native key held.
            nativeDirections.insert(event.direction)
        }
        let action = BrightnessKeyPolicy.action(
            event: event, state: state, factor: factor, ceiling: ceiling,
            normalBrightness: normalBrightness, available: available,
            dimmingAvailable: dimmingAvailable, mode: mode, nativeAvailable: nativeAvailable
        )
        if action == .passthrough {
            if owned, event.hasUnsupportedModifiers { return .consume }
            nativeDirections.insert(event.direction)
            return .passthrough
        }
        consumedDirections.insert(event.direction)
        return action
    }
}
