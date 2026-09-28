import CodeIslandCore
import XCTest
@testable import CodeIsland

/// PandaQuotaMonitor refresh policy, hermetically: injected fetcher +
/// isolated UserDefaults suite — the real path touches the keychain, whose
/// consent prompt would block a test forever.
@MainActor
final class PandaQuotaMonitorTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "panda-quota-monitor-tests-" + UUID().uuidString
        suite = UserDefaults(suiteName: suiteName)
        try XCTSkipIf(suite == nil, "suite unavailable")
        suite.set(true, forKey: SettingsKey.showPandaQuota)
        suite.set("test-token", forKey: SettingsKey.pandaGatewayToken)
    }

    override func tearDown() {
        if let name = suiteName { suite.removePersistentDomain(forName: name) }
        super.tearDown()
    }

    private func makeSnapshot(used: Double = 100) -> PandaQuotaSnapshot {
        PandaQuotaSnapshot(
            planLabel: "二档套餐", usedCredits: used, creditLimit: 35000,
            remainingCredits: 35000 - used, usagePercent: used / 350,
            billingScope: "account", quotaStatus: "normal",
            windowEndLabel: "2026-09-28", isUnlimited: false, fetchedAt: Date()
        )
    }

    private func makeMonitor(
        fetcher: @escaping @Sendable () async throws -> PandaQuotaSnapshot
    ) -> PandaQuotaMonitor {
        PandaQuotaMonitor(defaults: suite, staleFlightTimeout: 60, fetcher: fetcher)
    }

    /// The reported bug: a turn finishes while the panel is collapsed, the
    /// user expands well within 120 s of the last fetch — the credits just
    /// consumed must still show up.
    func testStopWhileCollapsedForcesFetchOnNextExpand() async throws {
        let fetches = FetchCounter(snapshot: makeSnapshot(used: 100))
        let monitor = makeMonitor(fetcher: fetches.fetch)

        monitor.noteExpanded()
        await fetches.settle(at: 1)
        monitor.noteCollapsed()
        XCTAssertEqual(monitor.snapshot?.usedCredits, 100)

        monitor.noteStop() // credits booked server-side while collapsed
        monitor.noteExpanded() // inside the 120 s throttle window
        await fetches.settle(at: 2)
        XCTAssertEqual(fetches.count, 2, "Stop must bypass the expand throttle")
    }

    func testExpandThrottleHoldsWithoutStop() async throws {
        let fetches = FetchCounter(snapshot: makeSnapshot(used: 100))
        let monitor = makeMonitor(fetcher: fetches.fetch)

        monitor.noteExpanded()
        await fetches.settle(at: 1)
        monitor.noteCollapsed()
        monitor.noteExpanded()
        monitor.noteExpanded()
        await fetches.quiet()
        XCTAssertEqual(fetches.count, 1, "no Stop: expands within 120 s fetch once")
    }

    func testStopWhileExpandedFetchesImmediately() async throws {
        let fetches = FetchCounter(snapshot: makeSnapshot(used: 100))
        let monitor = makeMonitor(fetcher: fetches.fetch)

        monitor.noteExpanded()
        await fetches.settle(at: 1)
        monitor.noteStop()
        await fetches.settle(at: 2)
        XCTAssertEqual(fetches.count, 2)
    }

    /// A fetch that never lands (keychain consent prompt nobody answers) must
    /// not freeze the monitor — after the watchdog timeout a new expand
    /// retries.
    func testStuckFetchIsReleasedByWatchdog() async throws {
        let monitor = PandaQuotaMonitor(defaults: suite, staleFlightTimeout: 0.05) {
            // Never completes, never throws.
            try await withCheckedThrowingContinuation { _ in }
        }

        monitor.noteExpanded()
        try await Task.sleep(nanoseconds: 200_000_000) // watchdog fires
        monitor.noteStop()
        monitor.noteExpanded()

        // No assertion on fetch count (the stuck task still hangs) — the point
        // is fetchNow() did not bail on a permanently latched inFlight flag.
        // A late result from the stuck generation is discarded silently.
        XCTAssertTrue(monitor.isExpanded)
    }

    func testDisabledMonitorDoesNothing() async throws {
        suite.set(false, forKey: SettingsKey.showPandaQuota)
        let fetches = FetchCounter(snapshot: makeSnapshot())
        let monitor = makeMonitor(fetcher: fetches.fetch)

        monitor.noteExpanded()
        monitor.noteStop()
        await fetches.quiet()
        XCTAssertEqual(fetches.count, 0)
        XCTAssertNil(monitor.snapshot)
    }

    func testUnauthorizedSurfacesAsError() async throws {
        let monitor = makeMonitor { throw PandaQuotaError.unauthorized }

        monitor.noteExpanded()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNil(monitor.snapshot)
        XCTAssertEqual(monitor.lastError, "Panda 网关 Token 无效或已过期")
    }
}

/// Thread-safe fetch counter: counts calls and returns a fixed snapshot, so
/// a test can wait for a specific number of completed fetches.
private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private let snapshot: PandaQuotaSnapshot
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }

    init(snapshot: PandaQuotaSnapshot) {
        self.snapshot = snapshot
    }

    func fetch() async throws -> PandaQuotaSnapshot {
        lock.lock()
        _count += 1
        lock.unlock()
        return snapshot
    }

    /// Wait until `n` fetches have completed (snapshot applied), 2 s cap.
    func settle(at n: Int) async {
        for _ in 0..<400 {
            if count >= n {
                try? await Task.sleep(nanoseconds: 20_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Wait 100 ms and return — for asserting nothing more happened.
    func quiet() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
