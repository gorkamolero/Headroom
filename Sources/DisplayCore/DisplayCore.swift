import Foundation
import CoreGraphics
import ColorSync
import CryptoKit
import Darwin

public enum DisplayError: Error, LocalizedError {
    case invalid(String), coreGraphics(String, Int32), io(String), busy
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .io(let s): return s
        case .coreGraphics(let s, let code): return "\(s) failed (CoreGraphics \(code))."
        case .busy: return "Another Headroom process owns this display or recovery lock."
        }
    }
}

/// Bounded transfer-table adjustment. A nonzero floor keeps software dimming
/// recoverable without deliberately blacking out the display.
public enum DisplayAdjustmentRange {
    public static let minimumFactor: Double = 0.1
    public static let maximumFactor: Double = 2
}

public struct GammaTable: Codable, Equatable {
    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]
    public var count: Int { red.count }
    public var maximum: Float { max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0) }

    public init(red: [Float], green: [Float], blue: [Float]) throws {
        guard !red.isEmpty, red.count <= 65536, red.count == green.count, red.count == blue.count else {
            throw DisplayError.invalid("Gamma tables must contain equal, nonempty channel arrays (at most 65,536 entries).")
        }
        guard [red, green, blue].allSatisfy({ $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 16 } }) else {
            throw DisplayError.invalid("Gamma tables contain invalid or excessive values.")
        }
        self.red = red; self.green = green; self.blue = blue
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(red: c.decode([Float].self, forKey: .red), green: c.decode([Float].self, forKey: .green), blue: c.decode([Float].self, forKey: .blue))
    }

    public static func read(display: CGDirectDisplayID) throws -> GammaTable {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0, capacity <= 65536 else { throw DisplayError.invalid("Display has no usable transfer table.") }
        var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r
        var count: UInt32 = 0
        let result = CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &count)
        guard result == .success else { throw DisplayError.coreGraphics("Reading transfer table", result.rawValue) }
        guard count > 0, count <= capacity else { throw DisplayError.invalid("Display returned an invalid sample count.") }
        return try GammaTable(red: Array(r.prefix(Int(count))), green: Array(g.prefix(Int(count))), blue: Array(b.prefix(Int(count))))
    }

    public func apply(display: CGDirectDisplayID) throws {
        let result = CGSetDisplayTransferByTable(display, UInt32(count), red, green, blue)
        guard result == .success else { throw DisplayError.coreGraphics("Writing transfer table", result.rawValue) }
    }

    /// Always invoke on the saved original table, never the latest readback.
    /// Values above 1 are an explicitly experimental use of the CoreGraphics API.
    public func scaled(factor: Float) throws -> GammaTable {
        guard factor.isFinite, factor >= Float(DisplayAdjustmentRange.minimumFactor), factor <= Float(DisplayAdjustmentRange.maximumFactor) else {
            throw DisplayError.invalid("Brightness adjustment must be between 0.1 and 2.")
        }
        return try GammaTable(red: red.map { $0 * factor }, green: green.map { $0 * factor }, blue: blue.map { $0 * factor })
    }

    public func maxDifference(from other: GammaTable) -> Float {
        guard count == other.count else { return .infinity }
        return zip(red + green + blue, other.red + other.green + other.blue).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    fileprivate var unitClamped: GammaTable {
        // The setter's documented range is 0...1, so this is another known
        // possible result of an experimental out-of-range write.
        try! GammaTable(red: red.map { min(1, $0) }, green: green.map { min(1, $0) }, blue: blue.map { min(1, $0) })
    }
}

public struct DisplayIdentity: Codable, Equatable {
    public let displayID: CGDirectDisplayID
    public let uuid: String
    public let configuration: String
    public init(displayID: CGDirectDisplayID, uuid: String, configuration: String) {
        self.displayID = displayID; self.uuid = uuid; self.configuration = configuration
    }
    public static func capture(display: CGDirectDisplayID) throws -> DisplayIdentity {
        guard CGDisplayIsOnline(display) != 0 else { throw DisplayError.invalid("Display is disconnected.") }
        let identifier = CGDisplayCreateUUIDFromDisplayID(display).takeRetainedValue()
        let uuid = CFUUIDCreateString(nil, identifier)! as String
        let profile = CGDisplayCopyColorSpace(display).copyICCData() as Data?
        let profileHash = profile.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "no-profile"
        let mode = CGDisplayCopyDisplayMode(display)
        let configuration = "\(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0):\(mode?.refreshRate ?? 0):\(profileHash)"
        return DisplayIdentity(displayID: display, uuid: uuid, configuration: configuration)
    }
    public static func resolve(uuid: String) -> CGDirectDisplayID? {
        guard UUID(uuidString: uuid) != nil, let value = CFUUIDCreateFromString(nil, uuid as CFString) else { return nil }
        // ColorSync's reverse UUID lookup assumes the process has initialized
        // its CoreGraphics display connection. A standalone crash-recovery
        // process has not necessarily made any earlier display API call.
        var onlineCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &onlineCount) == .success, onlineCount > 0 else { return nil }
        let display = CGDisplayGetDisplayIDFromUUID(value)
        guard display != kCGNullDirectDisplay, CGDisplayIsOnline(display) != 0,
              let actual = try? capture(display: display), actual.uuid == uuid else { return nil }
        return display
    }
}

public protocol DisplayAccess {
    func identity(display: CGDirectDisplayID) throws -> DisplayIdentity
    func resolve(uuid: String) -> CGDirectDisplayID?
    func read(display: CGDirectDisplayID) throws -> GammaTable
    func apply(_ table: GammaTable, display: CGDirectDisplayID) throws
}
public struct SystemDisplayAccess: DisplayAccess {
    public init() {}
    public func identity(display: CGDirectDisplayID) throws -> DisplayIdentity { try .capture(display: display) }
    public func resolve(uuid: String) -> CGDirectDisplayID? { DisplayIdentity.resolve(uuid: uuid) }
    public func read(display: CGDirectDisplayID) throws -> GammaTable { try .read(display: display) }
    public func apply(_ table: GammaTable, display: CGDirectDisplayID) throws { try table.apply(display: display) }
}

public struct RecoveryJournal: Codable {
    public let schema: Int
    public let identity: DisplayIdentity
    public let baseline: GammaTable
    public var proposed: GammaTable
    public var lastReadback: GammaTable?
    public let createdAt: Date
    public init(identity: DisplayIdentity, baseline: GammaTable, proposed: GammaTable) {
        self.schema = 1; self.identity = identity; self.baseline = baseline; self.proposed = proposed
        self.lastReadback = nil; self.createdAt = Date()
    }
    public func validate() throws {
        guard schema == 1, UUID(uuidString: identity.uuid) != nil,
              proposed.count == baseline.count, lastReadback.map({ $0.count == baseline.count }) ?? true else {
            throw DisplayError.invalid("Recovery journal is invalid or from an unsupported version.")
        }
    }
    public func owns(_ current: GammaTable, tolerance: Float = 0.0005) -> Bool {
        current.maxDifference(from: proposed) <= tolerance ||
        current.maxDifference(from: proposed.unitClamped) <= tolerance ||
        lastReadback.map { current.maxDifference(from: $0) <= tolerance } == true
    }
    public mutating func recordReadback(_ readback: GammaTable) throws {
        guard owns(readback) || readback.maxDifference(from: baseline) <= 0.0005 else {
            throw DisplayError.invalid("Unexpected transfer readback; possible concurrent external transform. Ownership was not claimed.")
        }
        lastReadback = readback
    }
}

public struct RecoveryResult: Codable {
    public let uuid: String
    public let status: String
    public let message: String
    public let difference: Float?
    public var succeeded: Bool { status == "restored" || status == "alreadyOriginal" }
}

/// A process-held advisory lock for one physical display, shared by all Headroom
/// clients regardless of their journal directory. Never remove its lock file:
/// unlinking would allow another process to lock a different inode for this UUID.
public final class DisplayMutationLock {
    public let uuid: String
    fileprivate let directory: URL
    private let lockFD: Int32

    fileprivate init(uuid: String, directory: URL) throws {
        guard let identifier = UUID(uuidString: uuid) else { throw DisplayError.invalid("Display lock requires a valid display UUID.") }
        self.uuid = identifier.uuidString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let path = self.directory.appendingPathComponent(self.uuid + ".lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DisplayError.io("Cannot open display lock: \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw DisplayError.busy }
        self.lockFD = fd
    }

    fileprivate func matches(uuid: String, directory: URL) -> Bool {
        UUID(uuidString: uuid)?.uuidString == self.uuid && directory.standardizedFileURL.resolvingSymlinksInPath().path == self.directory.path
    }

    deinit { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
}

/// Own this object for the entire guardian lifetime. Its directory lock protects
/// journal bookkeeping; a separate DisplayMutationLock must cover each display
/// from before baseline capture until restoration, including failed retries.
public final class RecoveryStore {
    public static var defaultDisplayLockDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HeadroomShared/DisplayLocks", isDirectory: true)
    }
    public let directory: URL
    private let displayLockDirectory: URL
    private let lockFD: Int32
    public init(directory: URL, displayLockDirectory: URL = RecoveryStore.defaultDisplayLockDirectory) throws {
        self.directory = directory
        self.displayLockDirectory = displayLockDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent("guardian.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DisplayError.io("Cannot open recovery lock: \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw DisplayError.busy }
        self.lockFD = fd
    }
    deinit { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
    /// Acquire before reading a baseline. Keeping this token alive is what
    /// prevents a second Headroom client from capturing a boosted/clamped table.
    public func acquireDisplayLock(uuid: String) throws -> DisplayMutationLock {
        try DisplayMutationLock(uuid: uuid, directory: displayLockDirectory)
    }
    /// The only other standard client locations we inspect. An explicitly
    /// supplied --journal-dir still checks these locations, without searching
    /// arbitrary directories for recovery files.
    public static func standardRecoveryDirectories(uuid: String) throws -> [URL] {
        guard let identifier = UUID(uuidString: uuid) else { throw DisplayError.invalid("Peer recovery requires a valid display UUID.") }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            support.appendingPathComponent("HeadroomLab/Recovery", isDirectory: true),
            support.appendingPathComponent("Headroom/Recovery/\(identifier.uuidString)", isDirectory: true)
        ]
    }
    /// Before capturing a new baseline, recover this physical display's journal
    /// from known peer clients. The caller keeps display ownership across this
    /// operation and its subsequent baseline capture. Failure is never ignored.
    public func recoverOtherClientJournals(uuid: String, heldLock: DisplayMutationLock, directories: [URL]? = nil, access: DisplayAccess = SystemDisplayAccess()) throws -> [RecoveryResult] {
        guard heldLock.matches(uuid: uuid, directory: displayLockDirectory) else {
            throw DisplayError.invalid("Peer recovery requires ownership of the same physical display.")
        }
        defer { withExtendedLifetime(heldLock) {} }
        var visited = Set([directory.standardizedFileURL.resolvingSymlinksInPath().path])
        var results: [RecoveryResult] = []
        for candidate in try directories ?? Self.standardRecoveryDirectories(uuid: uuid) {
            let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard visited.insert(canonical.path).inserted else { continue }
            let journalURL = canonical.appendingPathComponent(heldLock.uuid + ".json")
            var metadata = stat()
            if Darwin.lstat(journalURL.path, &metadata) != 0 {
                if errno == ENOENT { continue }
                throw DisplayError.io("Cannot inspect previous Headroom recovery journal: \(String(cString: strerror(errno)))")
            }
            let outcome: RecoveryResult
            do {
                let peer = try RecoveryStore(directory: canonical, displayLockDirectory: displayLockDirectory)
                defer { withExtendedLifetime(peer) {} }
                let journal = try peer.load(journalURL)
                outcome = peer.recover(journal, access: access, heldLock: heldLock)
            } catch DisplayError.busy {
                outcome = RecoveryResult(uuid: uuid, status: "busy", message: "Another Headroom client owns a pending recovery journal; a new baseline was not captured.", difference: nil)
            } catch {
                outcome = RecoveryResult(uuid: uuid, status: "failed", message: "Previous Headroom recovery remains unresolved: \(error.localizedDescription)", difference: nil)
            }
            results.append(outcome)
            if !outcome.succeeded { break }
        }
        return results
    }
    public func path(for journal: RecoveryJournal) -> URL { directory.appendingPathComponent(journal.identity.uuid + ".json") }
    public func save(_ journal: RecoveryJournal) throws {
        try journal.validate()
        let data = try JSONEncoder().encode(journal)
        let destination = path(for: journal)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DisplayError.io("Cannot create recovery journal.") }
        var didClose = false
        defer { if !didClose { Darwin.close(fd) }; try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw DisplayError.io("Could not persist original display settings.") }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw DisplayError.io("Could not synchronize recovery journal.") }
        Darwin.close(fd); didClose = true
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw DisplayError.io("Could not commit recovery journal.") }
        try synchronizeDirectory()
    }
    private func synchronizeDirectory() throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw DisplayError.io("Cannot synchronize recovery directory.") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw DisplayError.io("Could not synchronize recovery directory.") }
    }
    public func remove(_ journal: RecoveryJournal) throws {
        try FileManager.default.removeItem(at: path(for: journal)); try synchronizeDirectory()
    }
    public func journalURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }
    public func load(_ url: URL) throws -> RecoveryJournal {
        let data = try Data(contentsOf: url)
        guard data.count <= 10_000_000 else { throw DisplayError.invalid("Recovery journal is too large.") }
        let journal = try JSONDecoder().decode(RecoveryJournal.self, from: data)
        try journal.validate()
        guard url.lastPathComponent == journal.identity.uuid + ".json" else { throw DisplayError.invalid("Recovery journal identity does not match its filename.") }
        return journal
    }
    public func recover(_ journal: RecoveryJournal, access: DisplayAccess = SystemDisplayAccess(), heldLock: DisplayMutationLock? = nil) -> RecoveryResult {
        let uuid = journal.identity.uuid
        func result(_ status: String, _ message: String, _ difference: Float? = nil) -> RecoveryResult {
            RecoveryResult(uuid: uuid, status: status, message: message, difference: difference?.isFinite == true ? difference : nil)
        }
        do {
            try journal.validate()
            let ownership: DisplayMutationLock
            if let heldLock {
                guard heldLock.matches(uuid: uuid, directory: displayLockDirectory) else {
                    throw DisplayError.invalid("Display recovery was given a lock for a different display or lock directory.")
                }
                ownership = heldLock
            } else {
                ownership = try acquireDisplayLock(uuid: uuid)
            }
            // Keep exclusive ownership through the restore readback and journal
            // removal, even if a release-build optimizer shortens object lifetime.
            defer { withExtendedLifetime(ownership) {} }
            guard let display = access.resolve(uuid: uuid) else { return result("disconnected", "Original display is disconnected; recovery journal retained.") }
            let identity = try access.identity(display: display)
            guard identity.uuid == uuid else { return result("conflict", "Display identity changed; recovery journal retained.") }
            let current = try access.read(display: display)
            if current.maxDifference(from: journal.baseline) <= 0.0005 {
                try remove(journal); return result("alreadyOriginal", "Original transfer tables are already active.", current.maxDifference(from: journal.baseline))
            }
            guard identity.configuration == journal.identity.configuration else { return result("conflict", "Display mode or color profile changed; stale baseline was not written.") }
            guard journal.owns(current) else { return result("conflict", "Another display transform is active; it was not overwritten. Recovery journal retained.") }
            // A display can be disconnected, have its ID reused, or change
            // profile while the table read is in flight. Revalidate immediately
            // before writing; our lock excludes Headroom peers, not ColorSync.
            guard try access.identity(display: display) == identity else {
                return result("conflict", "Display identity or configuration changed during recovery; stale baseline was not written.")
            }
            try access.apply(journal.baseline, display: display)
            let difference = try access.read(display: display).maxDifference(from: journal.baseline)
            guard difference <= 0.0005 else { return result("failed", "Original transfer table restoration could not be verified.", difference) }
            guard try access.identity(display: display) == identity else {
                return result("conflict", "Display configuration changed while verifying restoration; recovery journal retained.")
            }
            try remove(journal)
            return result("restored", "Original transfer tables restored and read back successfully.", difference)
        } catch DisplayError.busy { return result("busy", "Another Headroom process owns this display; recovery did not read or change its transfer tables.") }
        catch { return result("failed", error.localizedDescription) }
    }
    public func recoverAll(access: DisplayAccess = SystemDisplayAccess()) -> [RecoveryResult] {
        do {
            return try journalURLs().map { url in
                do { return recover(try load(url), access: access) }
                catch { return RecoveryResult(uuid: url.deletingPathExtension().lastPathComponent, status: "invalid", message: error.localizedDescription, difference: nil) }
            }
        } catch { return [RecoveryResult(uuid: "", status: "failed", message: error.localizedDescription, difference: nil)] }
    }
}
