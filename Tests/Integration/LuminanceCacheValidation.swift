import Foundation

/// Deterministic fake providers only. No private API or display is accessed.
@main struct LuminanceCacheValidation {
    private static var checks: [String: Bool] = [:]
    static func main() {
        let time = TestClock(10)
        let provider = ControlledProvider()
        let cache = CachedDisplayLuminanceReader(clock: { time.now }, makeReader: {
            provider.recordFactoryThread()
            return provider
        })
        check(cache.reading(displayID: 0) == nil && provider.calls == 0, "zeroIDDoesNotScheduleWork")
        check(cache.reading(displayID: 1) == nil, "coldCacheIsUnavailable")
        check(wait { provider.calls == 1 }, "workerStarted")
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { _ = cache.reading(displayID: 1) }
        let coldElapsed = ProcessInfo.processInfo.systemUptime - started
        check(coldElapsed < 0.2, "blockedProviderDoesNotBlockCaller")
        check(provider.calls == 1, "repeatedColdReadsCoalesce")
        check(!provider.factoryOnMain && !provider.readOnMain, "factoryAndReadsStayOffMainThread")
        provider.allow(nits: 400)
        check(wait { cache.reading(displayID: 1)?.referenceNits == 400 }, "completedReadingBecomesAvailable")
        time.set(10.05)
        for _ in 0..<100 { _ = cache.reading(displayID: 1) }
        check(provider.calls == 1, "refreshIsRateLimited")

        provider.block()
        time.set(10.11)
        check(cache.reading(displayID: 1)?.referenceNits == 400, "freshCacheSurvivesInflightRefresh")
        check(wait { provider.calls == 2 }, "refreshStarted")
        for _ in 0..<100 { _ = cache.reading(displayID: 1) }
        check(provider.calls == 2, "inflightRefreshCoalesces")
        time.set(11)
        check(cache.reading(displayID: 1) == nil, "readingExpiresAtOneSecond")
        time.set(11.2)
        let staleStarted = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { _ = cache.reading(displayID: 1) }
        check(ProcessInfo.processInfo.systemUptime - staleStarted < 0.2, "staleReadAlsoReturnsImmediately")
        provider.allow(nits: 800)
        check(wait { provider.completed == 2 }, "delayedProviderCompleted")
        Thread.sleep(forTimeInterval: 0.02)
        check(cache.reading(displayID: 1) == nil, "lateResultCannotReviveStaleReading")

        time.set(11.31)
        provider.allow(nits: 900)
        check(cache.reading(displayID: 1) == nil, "retryStartsUnavailable")
        check(wait { cache.reading(displayID: 1)?.referenceNits == 900 }, "freshRetryRecovers")
        time.set(11.42)
        provider.allow(nits: nil)
        _ = cache.reading(displayID: 1)
        check(wait { provider.completed == 4 }, "unavailableProviderCompleted")
        check(wait { cache.reading(displayID: 1) == nil }, "unavailableResultClearsEarlierReading")
        check(provider.maximumConcurrent == 1, "providerCallsAreSerial")

        let limitedTime = TestClock(20)
        let limitedProvider = ControlledProvider()
        let limited = CachedDisplayLuminanceReader(maximumDisplays: 2, clock: { limitedTime.now },
                                                  makeReader: { limitedProvider })
        for id in UInt32(1)...100 { _ = limited.reading(displayID: id) }
        check(wait { limitedProvider.calls == 1 }, "limitedWorkerStarted")
        limitedProvider.allow(nits: 500)
        check(wait { limitedProvider.completed == 2 }, "boundedPendingWorkCompletes")
        Thread.sleep(forTimeInterval: 0.02)
        check(limitedProvider.calls == 2, "manyIDsCannotCreateUnboundedPendingWork")
        limitedTime.set(20.2)
        _ = limited.reading(displayID: 3)
        check(wait { limited.reading(displayID: 3)?.referenceNits == 500 }, "completedOldIDCanBeEvicted")
        check(limitedProvider.calls == 3, "evictionSchedulesOnlyRequestedDisplay")

        let lifecycleProvider = ControlledProvider()
        var lifecycle: CachedDisplayLuminanceReader? = CachedDisplayLuminanceReader(makeReader: { lifecycleProvider })
        weak var weakCache = lifecycle
        _ = lifecycle?.reading(displayID: 1)
        check(wait { lifecycleProvider.calls == 1 }, "lifecycleWorkerStarted")
        lifecycle = nil
        check(weakCache == nil, "stalledCallDoesNotRetainOwner")
        weakCache = nil
        lifecycleProvider.allow(nits: 200)
        check(wait { lifecycleProvider.completed == 1 }, "orphanedWorkerCanFinishSafely")

        let report: [String: Any] = ["allPassed": checks.values.allSatisfy { $0 }, "checkCount": checks.count,
                                   "checks": checks, "thousandBlockedReadsSeconds": coldElapsed,
                                   "usesFakeProvidersOnly": true, "displaySettingsWritten": false]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
    private static func check(_ condition: Bool, _ name: String) { checks[name] = condition }
    private static func wait(_ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }
}

private final class TestClock {
    private let lock = NSLock()
    private var value: Double
    init(_ value: Double) { self.value = value }
    var now: Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); self.value = value; lock.unlock() }
}

private final class ControlledProvider: DisplayLuminanceReading {
    private let condition = NSCondition()
    private var isBlocked = true
    private var nits: Double?
    private var callCount = 0
    private var completedCount = 0
    private var active = 0
    private var maximumActive = 0
    private var factoryMain = false
    private var readMain = false
    var calls: Int { synchronized { callCount } }
    var completed: Int { synchronized { completedCount } }
    var maximumConcurrent: Int { synchronized { maximumActive } }
    var factoryOnMain: Bool { synchronized { factoryMain } }
    var readOnMain: Bool { synchronized { readMain } }
    func recordFactoryThread() { synchronized { factoryMain = Thread.isMainThread } }
    func allow(nits: Double?) {
        synchronized { self.nits = nits; isBlocked = false; condition.broadcast() }
    }
    func block() { synchronized { isBlocked = true } }
    func reading(displayID: UInt32) -> DisplayLuminanceReadingSnapshot? {
        condition.lock()
        defer { condition.unlock() }
        callCount += 1
        active += 1
        maximumActive = max(maximumActive, active)
        readMain = readMain || Thread.isMainThread
        let deadline = Date().addingTimeInterval(3)
        while isBlocked && condition.wait(until: deadline) {}
        active -= 1
        completedCount += 1
        return nits.map { DisplayLuminanceReadingSnapshot(referenceNits: $0, maximumHDRNits: 1600) }
    }
    private func synchronized<T>(_ body: () -> T) -> T {
        condition.lock(); defer { condition.unlock() }; return body()
    }
}
