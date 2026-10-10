import Foundation

/// A heartbeat never extends the fixed experiment deadline. Only explicitly
/// renewable sessions accept a separate renewal command, and an expired
/// session cannot be revived by either command.
public struct SessionLease {
    public static let heartbeatTimeout: TimeInterval = 5
    public static let renewalDuration: TimeInterval = 30
    public let renewable: Bool
    public private(set) var deadline: TimeInterval
    public private(set) var lastHeartbeat: TimeInterval

    public init(now: TimeInterval, duration: TimeInterval, renewable: Bool = false) throws {
        guard now.isFinite, now >= 0, duration.isFinite, duration >= 1, duration <= 45 else {
            throw DisplayError.invalid("Session duration must be between 1 and 45 seconds.")
        }
        self.renewable = renewable
        self.deadline = now + duration
        self.lastHeartbeat = now
    }

    public func expiryReason(at now: TimeInterval) -> String? {
        if !now.isFinite || now < lastHeartbeat { return "invalidClock" }
        if now >= deadline { return "deadline" }
        if now - lastHeartbeat >= Self.heartbeatTimeout { return "leaseExpired" }
        return nil
    }

    public mutating func heartbeat(at now: TimeInterval) throws {
        guard expiryReason(at: now) == nil else { throw DisplayError.invalid("Session has expired and must be restored before starting again.") }
        lastHeartbeat = now
    }

    public mutating func renew(at now: TimeInterval) throws {
        guard renewable else { throw DisplayError.invalid("This fixed experiment does not permit renewal.") }
        guard expiryReason(at: now) == nil else { throw DisplayError.invalid("An expired session cannot be renewed.") }
        deadline = now + Self.renewalDuration
        lastHeartbeat = now
    }
}
