/// A short detent between native brightness and software dimming/boost. The
/// caller confirms actual arrival after hardware readback or gamma restoration;
/// projected values alone must not start the pause's deadline.
public struct BrightnessBoundaryPause: Sendable {
    public static let duration = 0.35

    private enum Phase: Sendable {
        case waiting
        case pausing(startedAt: Double, until: Double)
    }

    private var phase: Phase?
    public private(set) var armedDirection: BrightnessDirection?

    public var isWaiting: Bool {
        if case .waiting = phase { return true }
        return false
    }

    public init() {}

    /// Called once when an adjustment is projected to reach a boundary.
    /// Duplicate arrival requests in the same direction cannot extend a pause.
    public mutating func begin(direction: BrightnessDirection) {
        guard armedDirection != direction else { return }
        armedDirection = direction
        phase = .waiting
    }

    /// Called only after the physical boundary is confirmed. A release, fresh
    /// press, reversal, or cancellation before confirmation prevents rearming.
    public mutating func reachedBoundary(now: Double) {
        guard case .waiting = phase else { return }
        guard now.isFinite, (now + Self.duration).isFinite else { reset(); return }
        phase = .pausing(startedAt: now, until: now + Self.duration)
    }

    public mutating func shouldPause(event: BrightnessKeyEvent, now: Double) -> Bool {
        if event.phase == .up {
            reset()
            return false
        }
        // Preserve ordinary modified-key behavior without disturbing a pending
        // supported brightness hold. Key-up above always ends that hold.
        guard !event.hasUnsupportedModifiers else { return false }
        guard event.isRepeat, event.direction == armedDirection else {
            reset()
            return false
        }
        guard now.isFinite else { reset(); return false }
        switch phase {
        case .waiting:
            return true
        case .pausing(let startedAt, let deadline):
            guard now >= startedAt, now < deadline else { reset(); return false }
            return true
        case nil:
            return false
        }
    }

    public mutating func reset() {
        phase = nil
        armedDirection = nil
    }
}
