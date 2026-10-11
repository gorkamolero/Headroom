import XCTest
import CoreGraphics
@testable import DisplayCore

final class FakeDisplay: DisplayAccess {
    let uuid = "00000000-0000-0000-0000-000000000123"
    var connected = true
    var displayID: UInt32 = 22
    var configuration = "original-profile"
    var table: GammaTable
    var writes: [(UInt32, GammaTable)] = []
    var discardWrites = false
    var reads = 0
    var afterRead: ((Int) -> Void)?
    init(_ table: GammaTable) { self.table = table }
    func identity(display: CGDirectDisplayID) throws -> DisplayIdentity { .init(displayID: displayID, uuid: uuid, configuration: configuration) }
    func resolve(uuid: String) -> CGDirectDisplayID? { connected && uuid == self.uuid ? displayID : nil }
    func read(display: CGDirectDisplayID) throws -> GammaTable {
        reads += 1
        let readback = table
        afterRead?(reads)
        return readback
    }
    func apply(_ table: GammaTable, display: CGDirectDisplayID) throws {
        writes.append((display, table)); if !discardWrites { self.table = table }
    }
}

final class DisplayCoreTests: XCTestCase {
    private var displayLockDirectory: URL!
    override func setUpWithError() throws {
        displayLockDirectory = try directory()
    }
    func makeStore(directory: URL) throws -> RecoveryStore {
        try RecoveryStore(directory: directory, displayLockDirectory: displayLockDirectory)
    }

    func testFixedSessionCannotBeRenewedOrKeptAlivePastDeadline() throws {
        var lease = try SessionLease(now: 0, duration: 20)
        for second in stride(from: 1.0, through: 19.0, by: 1) { try lease.heartbeat(at: second) }
        XCTAssertThrowsError(try lease.renew(at: 19))
        XCTAssertEqual(lease.deadline, 20)
        XCTAssertEqual(lease.expiryReason(at: 20), "deadline")
        XCTAssertThrowsError(try lease.heartbeat(at: 20))
    }
    func testRenewableSessionExtendsOnlyByExplicitRenewal() throws {
        var lease = try SessionLease(now: 0, duration: 30, renewable: true)
        for second in stride(from: 1.0, through: 10.0, by: 1) { try lease.heartbeat(at: second) }
        XCTAssertEqual(lease.deadline, 30)
        try lease.renew(at: 10)
        XCTAssertEqual(lease.deadline, 40)
        XCTAssertEqual(lease.lastHeartbeat, 10)
    }
    func testRenewableSessionStillExpiresAfterMissingHeartbeat() throws {
        var lease = try SessionLease(now: 0, duration: 30, renewable: true)
        try lease.renew(at: 1)
        XCTAssertNil(lease.expiryReason(at: 5.99))
        XCTAssertEqual(lease.expiryReason(at: 6), "leaseExpired")
        XCTAssertThrowsError(try lease.renew(at: 6))
        XCTAssertThrowsError(try lease.heartbeat(at: 6))
        XCTAssertEqual(lease.deadline, 31)
    }
    func testHeartbeatCannotRescueExpiredRenewableDeadline() throws {
        var lease = try SessionLease(now: 0, duration: 3, renewable: true)
        try lease.heartbeat(at: 2)
        XCTAssertThrowsError(try lease.renew(at: 3))
        XCTAssertEqual(lease.deadline, 3)
    }
    func testInvalidLeaseDurationsAndClockAreRejected() throws {
        for duration in [0.0, 45.01, .infinity, .nan] { XCTAssertThrowsError(try SessionLease(now: 0, duration: duration)) }
        var lease = try SessionLease(now: 10, duration: 30, renewable: true)
        XCTAssertThrowsError(try lease.renew(at: 9))
        XCTAssertThrowsError(try lease.heartbeat(at: .nan))
        XCTAssertEqual(lease.deadline, 40)
    }
    func baseline() throws -> GammaTable { try .init(red: [0, 0.2, 0.7, 1], green: [0, 0.21, 0.72, 1], blue: [0, 0.18, 0.68, 1]) }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func journal(fake: FakeDisplay, original: GammaTable) throws -> RecoveryJournal {
        var journal = RecoveryJournal(identity: try fake.identity(display: 1), baseline: original, proposed: try original.scaled(factor: 1.5))
        journal.lastReadback = journal.proposed
        fake.table = journal.proposed
        return journal
    }

    func testAbsoluteSliderUpdatesPreserveOriginalAndChannelShape() throws {
        let original = try baseline()
        let high = try original.scaled(factor: 1.5)
        let low = try original.scaled(factor: 1.2)
        XCTAssertEqual(low.red[2], 0.84, accuracy: 0.00001)
        XCTAssertEqual(low.green[2], 0.864, accuracy: 0.00001)
        XCTAssertEqual(original.maximum, 1)
        XCTAssertEqual(high.maximum, 1.5)
        XCTAssertEqual(try original.scaled(factor: 1), original)
    }
    func testDimmingKeepsChannelShapeAndUsesImmutableBaseline() throws {
        let original = try baseline()
        let first = try original.scaled(factor: 0.4)
        let second = try original.scaled(factor: 0.8)
        XCTAssertEqual(first.red[2], 0.28, accuracy: 0.00001)
        XCTAssertEqual(first.green[2], 0.288, accuracy: 0.00001)
        XCTAssertEqual(second.blue[2], 0.544, accuracy: 0.00001)
        XCTAssertEqual(second.maximum, 0.8, accuracy: 0.00001)
        XCTAssertEqual(original.maximum, 1)
        let floor = try original.scaled(factor: Float(DisplayAdjustmentRange.minimumFactor))
        XCTAssertEqual(floor.maximum, 0.1, accuracy: 0.00001)
    }
    func testDimmingCrashBeforeReadbackRestoresExactOriginal() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        let proposed = try original.scaled(factor: 0.1)
        let entry = RecoveryJournal(identity: try fake.identity(display: fake.displayID), baseline: original, proposed: proposed)
        let store = try makeStore(directory: directory())
        try store.save(entry)
        fake.table = proposed
        let outcomes = store.recoverAll(access: fake)
        XCTAssertEqual(outcomes.map(\.status), ["restored"])
        XCTAssertEqual(outcomes.first?.difference, 0)
        XCTAssertEqual(fake.table, original)
        XCTAssertTrue(try store.journalURLs().isEmpty)
    }
    func testRepeatedDimmingUpdatesRestoreSavedOriginalRatherThanDividingReadback() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        var entry = RecoveryJournal(identity: try fake.identity(display: fake.displayID), baseline: original, proposed: try original.scaled(factor: 0.5))
        let store = try makeStore(directory: directory())
        for factor: Float in [0.5, 0.1, 0.75, 0.2] {
            entry.proposed = try entry.baseline.scaled(factor: factor)
            try store.save(entry)
            fake.table = entry.proposed
            try entry.recordReadback(fake.table)
            try store.save(entry)
            XCTAssertEqual(fake.table.maximum, factor, accuracy: 0.00001)
        }
        XCTAssertEqual(store.recoverAll(access: fake).first?.status, "restored")
        XCTAssertEqual(fake.table, original)
        XCTAssertTrue(try store.journalURLs().isEmpty)
    }
    func testDimmingRecoveryDoesNotOverwriteAnExternalDimmer() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        let entry = RecoveryJournal(identity: try fake.identity(display: fake.displayID), baseline: original, proposed: try original.scaled(factor: 0.4))
        let store = try makeStore(directory: directory())
        try store.save(entry)
        fake.table = try original.scaled(factor: 0.6)
        XCTAssertEqual(store.recoverAll(access: fake).first?.status, "conflict")
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(try store.journalURLs().count, 1)
    }
    func testMaximumFactorClampedReadbackRestoresExactOriginalIncludingLostHighlights() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        let proposal = try original.scaled(factor: 2)
        var entry = RecoveryJournal(identity: try fake.identity(display: fake.displayID), baseline: original, proposed: proposal)
        let store = try makeStore(directory: directory())
        try store.save(entry)

        // Model the observed API behavior: the higher two distinct baseline
        // samples collapse to one after the setter clamps the doubled table.
        fake.table = try GammaTable(red: proposal.red.map { min(1, $0) }, green: proposal.green.map { min(1, $0) }, blue: proposal.blue.map { min(1, $0) })
        XCTAssertEqual(proposal.maximum, 2)
        XCTAssertEqual(fake.table.red[2], fake.table.red[3])
        XCTAssertNotEqual(original.red[2], original.red[3])
        try entry.recordReadback(fake.read(display: fake.displayID))
        try store.save(entry)

        // Recovery must use the durable original, not attempt to divide the
        // clipped readback, which cannot reconstruct the lost highlight values.
        let result = store.recoverAll(access: fake)
        XCTAssertEqual(result.map(\.status), ["restored"])
        XCTAssertEqual(result.first?.difference, 0)
        XCTAssertEqual(fake.table, original)
        XCTAssertEqual(fake.writes.count, 1)
        XCTAssertEqual(fake.writes.first?.1, original)
        XCTAssertTrue(try store.journalURLs().isEmpty)
    }
    func testInvalidTablesAndFactorsAreRejectedOnDecodeToo() throws {
        XCTAssertThrowsError(try GammaTable(red: [], green: [], blue: []))
        XCTAssertThrowsError(try GammaTable(red: [0], green: [0, 1], blue: [0]))
        XCTAssertThrowsError(try GammaTable(red: [.nan], green: [0], blue: [0]))
        XCTAssertThrowsError(try GammaTable(red: [-0.1], green: [0], blue: [0]))
        let original = try baseline()
        for factor: Float in [-0.1, 0, 0.099, 2.01, .infinity, .nan] { XCTAssertThrowsError(try original.scaled(factor: factor)) }
        let malformed = Data(#"{"red":[0],"green":[0,1],"blue":[0]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(GammaTable.self, from: malformed))
    }
    func testLockExcludesSecondGuardian() throws {
        let path = try directory()
        let first = try makeStore(directory: path)
        XCTAssertThrowsError(try makeStore(directory: path))
        withExtendedLifetime(first) {}
    }
    func testDifferentJournalDirectoriesCannotOwnTheSameDisplay() throws {
        let firstStore = try makeStore(directory: directory())
        let secondStore = try makeStore(directory: directory())
        let uuid = "AAAAAAAA-0000-0000-0000-000000000123"
        var first: DisplayMutationLock? = try firstStore.acquireDisplayLock(uuid: uuid)
        XCTAssertThrowsError(try secondStore.acquireDisplayLock(uuid: uuid.lowercased())) { error in
            guard case DisplayError.busy = error else { return XCTFail("Expected display ownership conflict") }
        }
        withExtendedLifetime(first) {}
        first = nil
        let nextOwner = try secondStore.acquireDisplayLock(uuid: uuid)
        XCTAssertEqual(nextOwner.uuid, uuid)
    }
    func testIndependentDisplayUUIDsCanBeOwnedAtOnce() throws {
        let firstStore = try makeStore(directory: directory())
        let secondStore = try makeStore(directory: directory())
        let first = try firstStore.acquireDisplayLock(uuid: "00000000-0000-0000-0000-000000000123")
        let second = try secondStore.acquireDisplayLock(uuid: "00000000-0000-0000-0000-000000000456")
        XCTAssertNotEqual(first.uuid, second.uuid)
        withExtendedLifetime((first, second)) {}
    }
    func testRecoveryInAnotherJournalDirectoryDoesNotTouchOwnedDisplay() throws {
        let fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: baseline())
        let activeStore = try makeStore(directory: directory())
        let recoveryStore = try makeStore(directory: directory())
        try recoveryStore.save(entry)
        let owner = try activeStore.acquireDisplayLock(uuid: fake.uuid)
        XCTAssertEqual(recoveryStore.recoverAll(access: fake).first?.status, "busy")
        XCTAssertEqual(fake.reads, 0)
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(try recoveryStore.journalURLs().count, 1)
        withExtendedLifetime(owner) {}
    }
    func testRecoveryCanReuseMatchingHeldLockAndKeepsItUntilOwnerReleases() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: original)
        let activeStore = try makeStore(directory: directory())
        let otherStore = try makeStore(directory: directory())
        try activeStore.save(entry)
        var owner: DisplayMutationLock? = try activeStore.acquireDisplayLock(uuid: fake.uuid)
        XCTAssertEqual(activeStore.recover(entry, access: fake, heldLock: owner).status, "restored")
        XCTAssertEqual(fake.table, original)
        XCTAssertThrowsError(try otherStore.acquireDisplayLock(uuid: fake.uuid))
        withExtendedLifetime(owner) {}
        owner = nil
        let nextOwner = try otherStore.acquireDisplayLock(uuid: fake.uuid)
        XCTAssertEqual(nextOwner.uuid, fake.uuid)
    }
    func testRecoveryRejectsMismatchedLockTokenWithoutReadingOrWriting() throws {
        let fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: baseline())
        let store = try makeStore(directory: directory())
        try store.save(entry)
        let wrongDisplay = try store.acquireDisplayLock(uuid: "00000000-0000-0000-0000-000000000456")
        XCTAssertEqual(store.recover(entry, access: fake, heldLock: wrongDisplay).status, "failed")
        let foreignStore = try RecoveryStore(directory: directory(), displayLockDirectory: directory())
        let wrongDirectory = try foreignStore.acquireDisplayLock(uuid: fake.uuid)
        XCTAssertEqual(store.recover(entry, access: fake, heldLock: wrongDirectory).status, "failed")
        XCTAssertEqual(fake.reads, 0)
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(try store.journalURLs().count, 1)
    }
    func testInvalidDisplayLockUUIDDoesNotCreateAPath() throws {
        let store = try makeStore(directory: directory())
        XCTAssertThrowsError(try store.acquireDisplayLock(uuid: "../invalid"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: displayLockDirectory.path))
    }
    func testOtherClientClampedJournalRestoresBeforeNewBaselineCapture() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: original)
        fake.table = try GammaTable(red: entry.proposed.red.map { min(1, $0) }, green: entry.proposed.green.map { min(1, $0) }, blue: entry.proposed.blue.map { min(1, $0) })
        let peerDirectory = try directory()
        do { let peer = try makeStore(directory: peerDirectory); try peer.save(entry) }
        let current = try makeStore(directory: directory())
        let owner = try current.acquireDisplayLock(uuid: fake.uuid)
        let results = try current.recoverOtherClientJournals(uuid: fake.uuid, heldLock: owner, directories: [peerDirectory], access: fake)
        XCTAssertEqual(results.map(\.status), ["restored"])
        XCTAssertEqual(try fake.read(display: fake.displayID), original)
        XCTAssertEqual(fake.writes.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: peerDirectory.appendingPathComponent(fake.uuid + ".json").path))
        XCTAssertThrowsError(try current.acquireDisplayLock(uuid: fake.uuid))
        withExtendedLifetime(owner) {}
    }
    func testOtherClientBusyJournalBlocksWithoutDisplayAccess() throws {
        let fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: baseline())
        let peer = try makeStore(directory: directory())
        try peer.save(entry)
        let current = try makeStore(directory: directory())
        let owner = try current.acquireDisplayLock(uuid: fake.uuid)
        let results = try current.recoverOtherClientJournals(uuid: fake.uuid, heldLock: owner, directories: [peer.directory], access: fake)
        XCTAssertEqual(results.map(\.status), ["busy"])
        XCTAssertEqual(fake.reads, 0)
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(try peer.journalURLs().count, 1)
        withExtendedLifetime((peer, owner)) {}
    }
    func testOtherClientConflictingJournalIsRetainedWithoutOverride() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: original)
        let peerDirectory = try directory()
        do { let peer = try makeStore(directory: peerDirectory); try peer.save(entry) }
        fake.configuration = "different-profile"
        let current = try makeStore(directory: directory())
        let owner = try current.acquireDisplayLock(uuid: fake.uuid)
        let results = try current.recoverOtherClientJournals(uuid: fake.uuid, heldLock: owner, directories: [peerDirectory], access: fake)
        XCTAssertEqual(results.map(\.status), ["conflict"])
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: peerDirectory.appendingPathComponent(fake.uuid + ".json").path))
    }
    func testOtherClientRecoverySkipsOwnCanonicalDirectoryAndDoesNotCreateMissingPeers() throws {
        let fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: baseline())
        let current = try makeStore(directory: directory())
        try current.save(entry)
        let alias = try directory()
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: current.directory)
        let absent = try directory()
        let owner = try current.acquireDisplayLock(uuid: fake.uuid)
        let results = try current.recoverOtherClientJournals(uuid: fake.uuid, heldLock: owner, directories: [alias, current.directory, absent], access: fake)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(fake.reads, 0)
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(try current.journalURLs().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }
    func testOtherClientInvalidJournalBlocksWithoutDisplayAccess() throws {
        let fake = FakeDisplay(try baseline())
        let peerDirectory = try directory()
        try FileManager.default.createDirectory(at: peerDirectory, withIntermediateDirectories: true)
        let journalURL = peerDirectory.appendingPathComponent(fake.uuid + ".json")
        try Data("invalid journal".utf8).write(to: journalURL)
        let current = try makeStore(directory: directory())
        let owner = try current.acquireDisplayLock(uuid: fake.uuid)
        let results = try current.recoverOtherClientJournals(uuid: fake.uuid, heldLock: owner, directories: [peerDirectory], access: fake)
        XCTAssertEqual(results.map(\.status), ["failed"])
        XCTAssertEqual(fake.reads, 0)
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }
    func testOtherClientRecoveryRequiresMatchingHeldToken() throws {
        let fake = FakeDisplay(try baseline())
        let current = try makeStore(directory: directory())
        let wrongOwner = try current.acquireDisplayLock(uuid: "00000000-0000-0000-0000-000000000456")
        XCTAssertThrowsError(try current.recoverOtherClientJournals(uuid: fake.uuid, heldLock: wrongOwner, directories: [], access: fake))
        XCTAssertEqual(fake.reads, 0)
        XCTAssertTrue(fake.writes.isEmpty)
    }
    func testStandardPeerDirectoriesAreOnlyKnownLabAndMenuLocations() throws {
        let uuid = "aaaaaaaa-0000-0000-0000-000000000123"
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let paths = try RecoveryStore.standardRecoveryDirectories(uuid: uuid).map(\.path)
        XCTAssertEqual(paths, [support.appendingPathComponent("HeadroomLab/Recovery").path, support.appendingPathComponent("Headroom/Recovery/" + uuid.uppercased()).path])
        XCTAssertThrowsError(try RecoveryStore.standardRecoveryDirectories(uuid: "../../other"))
    }
    func testRecoveryUsesUUIDAfterDisplayIDChanges() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: original)
        let store = try makeStore(directory: directory())
        try store.save(entry)
        fake.displayID = 99
        let result = store.recoverAll(access: fake)
        XCTAssertEqual(result.first?.status, "restored")
        XCTAssertEqual(fake.writes.first?.0, 99)
        XCTAssertEqual(fake.table, original)
        XCTAssertTrue(try store.journalURLs().isEmpty)
    }
    func testDisconnectedDisplayRetainsJournalWithoutAnyWrite() throws {
        let fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: baseline())
        let store = try makeStore(directory: directory()); try store.save(entry)
        fake.connected = false
        XCTAssertEqual(store.recoverAll(access: fake).first?.status, "disconnected")
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(try store.journalURLs().count, 1)
    }
    func testExternalTransformIsNotOverwritten() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: original)
        let store = try makeStore(directory: directory()); try store.save(entry)
        fake.table = try original.scaled(factor: 1.1)
        XCTAssertEqual(store.recoverAll(access: fake).first?.status, "conflict")
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(try store.journalURLs().count, 1)
    }
    func testConcurrentExternalReadbackCannotBeClaimedAsOwnWrite() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        var entry = try journal(fake: fake, original: original)
        let previous = entry.lastReadback
        let store = try makeStore(directory: directory()); try store.save(entry)
        // Simulate another program writing between our setter and readback.
        fake.table = try original.scaled(factor: 1.1)
        XCTAssertThrowsError(try entry.recordReadback(fake.read(display: fake.displayID)))
        XCTAssertEqual(entry.lastReadback, previous)
        XCTAssertEqual(store.recover(entry, access: fake).status, "conflict")
        XCTAssertTrue(fake.writes.isEmpty)
    }
    func testChangedProfileBlocksStaleBaseline() throws {
        let fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: baseline())
        let store = try makeStore(directory: directory()); try store.save(entry)
        fake.configuration = "new-profile"
        XCTAssertEqual(store.recoverAll(access: fake).first?.status, "conflict")
        XCTAssertTrue(fake.writes.isEmpty)
    }
    func testProfileChangeDuringRecoveryReadDoesNotWriteStaleBaseline() throws {
        let fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: baseline())
        let store = try makeStore(directory: directory()); try store.save(entry)
        fake.afterRead = { [weak fake] _ in fake?.configuration = "changed-during-read" }
        let result = store.recoverAll(access: fake)
        XCTAssertEqual(result.first?.status, "conflict")
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(try store.journalURLs().count, 1)
    }
    func testConfigurationChangeDuringRestorationVerificationRetainsJournal() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: original)
        let store = try makeStore(directory: directory()); try store.save(entry)
        fake.afterRead = { [weak fake] count in
            if count == 2 { fake?.configuration = "changed-during-verification" }
        }
        let result = store.recoverAll(access: fake)
        XCTAssertEqual(result.first?.status, "conflict")
        XCTAssertEqual(fake.writes.count, 1)
        XCTAssertEqual(fake.table, original)
        XCTAssertEqual(try store.journalURLs().count, 1)
    }
    func testCrashBetweenWriteAndReadbackRecoversProposedTable() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        var entry = try journal(fake: fake, original: original); entry.lastReadback = nil
        let store = try makeStore(directory: directory()); try store.save(entry)
        XCTAssertEqual(store.recoverAll(access: fake).first?.status, "restored")
        XCTAssertEqual(fake.table, original)
    }
    func testClampedSetterResultRecoversEvenBeforeReadbackWasJournaled() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        var entry = try journal(fake: fake, original: original); entry.lastReadback = nil
        fake.table = try GammaTable(red: entry.proposed.red.map { min(1, $0) }, green: entry.proposed.green.map { min(1, $0) }, blue: entry.proposed.blue.map { min(1, $0) })
        let store = try makeStore(directory: directory()); try store.save(entry)
        XCTAssertEqual(store.recoverAll(access: fake).first?.status, "restored")
        XCTAssertEqual(fake.table, original)
    }
    func testAlreadyRestoredJournalIsRetiredWithoutMutation() throws {
        let original = try baseline(), fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: original)
        let store = try makeStore(directory: directory()); try store.save(entry)
        fake.table = original
        XCTAssertEqual(store.recoverAll(access: fake).first?.status, "alreadyOriginal")
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertTrue(try store.journalURLs().isEmpty)
    }
    func testFailedReadbackVerificationRetainsRecoveryJournal() throws {
        let fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: baseline())
        let store = try makeStore(directory: directory()); try store.save(entry)
        fake.discardWrites = true
        XCTAssertEqual(store.recoverAll(access: fake).first?.status, "failed")
        XCTAssertEqual(try store.journalURLs().count, 1)
    }
    func testWrongJournalFilenameCannotResolveAnotherDisplay() throws {
        let fake = FakeDisplay(try baseline())
        let entry = try journal(fake: fake, original: baseline())
        let store = try makeStore(directory: directory())
        let url = store.directory.appendingPathComponent("wrong.json")
        try JSONEncoder().encode(entry).write(to: url)
        XCTAssertEqual(store.recoverAll(access: fake).first?.status, "invalid")
        XCTAssertTrue(fake.writes.isEmpty)
    }
}
