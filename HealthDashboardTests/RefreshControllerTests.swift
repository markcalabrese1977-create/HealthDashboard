import XCTest
@testable import HealthDashboard

// Refresh watchdog: a Refresh whose fetch never completes must not leave isRefreshing stuck, and a
// fetch that completes after it was timed out must not write anything.

/// A fetch stub that parks until the test releases it (or never does).
private actor Gate {
    private var cont: CheckedContinuation<[DailyHealthPoint], Error>?
    private var early: [DailyHealthPoint]?
    private(set) var calls = 0

    func wait() async throws -> [DailyHealthPoint] {
        calls += 1
        if let early { return early }
        return try await withCheckedThrowingContinuation { cont = $0 }
    }

    func release(_ points: [DailyHealthPoint]) {
        if let c = cont { cont = nil; c.resume(returning: points) } else { early = points }
    }
}

private func payload(_ marker: Double) -> [DailyHealthPoint] {
    [ReadinessParityTests.point(day: 28, steps: marker)]
}

@MainActor
final class RefreshControllerTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func bump() { lock.lock(); n += 1; lock.unlock() }
    }

    private var applied: [Double] = []
    private var abandons = 0
    private var savedDurations: Data?
    private var suite: UserDefaults? { UserDefaults(suiteName: SharedStore.appGroupID) }

    override func setUp() {
        super.setUp()
        savedDurations = suite?.data(forKey: RefreshDurationLog.key)
        suite?.removeObject(forKey: RefreshDurationLog.key)
    }

    override func tearDown() {
        if let savedDurations { suite?.set(savedDurations, forKey: RefreshDurationLog.key) }
        else { suite?.removeObject(forKey: RefreshDurationLog.key) }
        super.tearDown()
    }

    private func makeController(timeout: TimeInterval = 0.15) -> RefreshController {
        RefreshController(timeoutSeconds: timeout, abandonInFlight: { [unowned self] in self.abandons += 1 })
    }

    private func apply(_ points: [DailyHealthPoint]) { applied.append(points.last?.steps ?? -1) }

    func testHungFetchTimesOutThenNextRefreshStartsFresh() async {
        let c = makeController()
        let hung = Gate()

        let first = await c.run(source: .userTap, fetch: { try await hung.wait() }, apply: { self.apply($0) })

        XCTAssertEqual(first, .timedOut)
        XCTAssertFalse(c.isRefreshing, "isRefreshing must be reset after a timeout")
        XCTAssertEqual(c.errorText, "Refresh timed out after 45 s — tap to retry.")
        XCTAssertEqual(RefreshDurationLog.load().last?.outcome, "timeout", "the timeout path records outcome=timeout")
        XCTAssertEqual(RefreshDurationLog.load().last?.source, "userTap")
        XCTAssertEqual(abandons, 1, "the in-flight HealthKit fetch must be abandoned on timeout")
        XCTAssertTrue(applied.isEmpty)

        let fresh = Counter()
        let second = await c.run(source: .userTap,
                                 fetch: { fresh.bump(); return payload(2) },
                                 apply: { self.apply($0) })

        XCTAssertEqual(second, .applied)
        XCTAssertEqual(fresh.value, 1, "the next tap must start a new fetch, not rejoin the hung one")
        XCTAssertEqual(applied, [2])
        XCTAssertNil(c.errorText, "errorText clears on the next tap")
    }

    func testLateOrphanAfterTimeoutWritesNothing() async {
        let c = makeController()
        let hung = Gate()

        _ = await c.run(source: .userTap, fetch: { try await hung.wait() }, apply: { self.apply($0) })
        await hung.release(payload(111))                 // the orphan completes late
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(applied.isEmpty, "a fetch that finished after its timeout must not apply")
        XCTAssertFalse(c.isRefreshing)
        XCTAssertNotNil(c.errorText, "the orphan must not clear the timeout error")
    }

    func testOrphanCompletingDuringNextRefreshDoesNotApply() async {
        let c = makeController(timeout: 2)
        let orphan = Gate()
        let current = Gate()

        let shortC = makeController(timeout: 0.1)
        _ = await shortC.run(source: .userTap, fetch: { try await orphan.wait() }, apply: { self.apply($0) })

        // A second refresh is in flight when the orphan completes.
        let run = Task { @MainActor in
            await c.run(source: .userTap, fetch: { try await current.wait() }, apply: { self.apply($0) })
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await orphan.release(payload(111))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(applied.isEmpty, "the orphan's payload must never be applied")

        await current.release(payload(222))
        let outcome = await run.value

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(applied, [222], "only the current fetch's payload is applied")
    }

    func testSupersededRunDoesNotApply() async {
        let c = makeController(timeout: 2)
        let g = Gate()
        let run = Task { @MainActor in
            await c.run(source: .userTap, fetch: { try await g.wait() }, apply: { self.apply($0) })
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        c.supersedeCurrentRun()                          // e.g. a forced reset while the fetch is out
        await g.release(payload(333))
        let outcome = await run.value

        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertFalse(c.isRefreshing)
    }

    func testTapWhileRefreshingSaysSoAndAutoRefreshStaysQuiet() async {
        let c = makeController(timeout: 2)
        let g = Gate()
        let run = Task { @MainActor in
            await c.run(source: .userTap, fetch: { try await g.wait() }, apply: { self.apply($0) })
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(c.isRefreshing)
        XCTAssertNil(c.refreshNote, "the note is cleared when a tap starts a refresh")

        let auto = await c.run(source: .autoLoop, fetch: { payload(9) }, apply: { self.apply($0) })
        XCTAssertEqual(auto, .skippedAlreadyRefreshing)
        XCTAssertNil(c.refreshNote, "the 5-minute loop must not flash a note")

        let tap = await c.run(source: .userTap, fetch: { payload(9) }, apply: { self.apply($0) })
        XCTAssertEqual(tap, .skippedAlreadyRefreshing)
        XCTAssertEqual(c.refreshNote, "Already refreshing…")

        await g.release(payload(1))
        _ = await run.value
        XCTAssertEqual(applied, [1], "the skipped runs never fetched or applied")
    }

    func testSuccessNoteShowsTimeAndClearsOnNextTap() async {
        let c = makeController(timeout: 2)
        var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 16
        comps.hour = 19; comps.minute = 5
        let when = Calendar.current.date(from: comps)!

        let out = await c.run(source: .userTap, now: when, fetch: { payload(1) }, apply: { self.apply($0) })
        XCTAssertEqual(out, .applied)
        XCTAssertEqual(c.refreshNote, "Up to date · 7:05")

        let g = Gate()
        let next = Task { @MainActor in
            await c.run(source: .userTap, fetch: { try await g.wait() }, apply: { self.apply($0) })
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(c.refreshNote, "cleared on the next tap")
        await g.release(payload(2))
        _ = await next.value
    }

    func testSuccessAndErrorAreRecordedWithSourceAndJoined() async {
        struct Boom: Error {}
        let c = makeController(timeout: 2)
        let probe = RefreshProbe()
        _ = await c.run(source: .foreground, probe: probe,
                        fetch: { probe.joined = true; return payload(1) }, apply: { self.apply($0) })
        _ = await c.run(source: .autoLoop, fetch: { throw Boom() }, apply: { self.apply($0) })

        let log = RefreshDurationLog.load()
        XCTAssertEqual(log.map(\.outcome), ["success", "error"])
        XCTAssertEqual(log.map(\.source), ["foreground", "autoLoop"])
        XCTAssertEqual(log.map(\.joined), [true, false])
        XCTAssertEqual(RefreshDurationLog.line(log[0]), "⏱ refresh: \(log[0].ms) ms, outcome=success, source=foreground, joined=true")
    }

    func testFailureSetsErrorTextAndResetsRefreshing() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let c = makeController(timeout: 2)
        let out = await c.run(source: .userTap, fetch: { throw Boom() }, apply: { self.apply($0) })
        XCTAssertEqual(out, .failed)
        XCTAssertEqual(c.errorText, "boom")
        XCTAssertFalse(c.isRefreshing)
        XCTAssertEqual(abandons, 0, "an ordinary failure does not abandon the shared fetch")
    }

    // The race resumes its continuation exactly once whichever side wins. A double resume traps
    // ("CheckedContinuation resumed more than once"), so surviving this loop is the assertion.
    func testRaceResumesExactlyOnceWhenFetchAndTimeoutCollide() async {
        for i in 0..<60 {
            let c = makeController(timeout: 0.01)
            let out = await c.run(source: .userTap,
                                  fetch: {
                                      try? await Task.sleep(nanoseconds: 10_000_000)
                                      return payload(Double(i))
                                  },
                                  apply: { self.apply($0) })
            XCTAssertTrue(out == .applied || out == .timedOut, "run \(i): \(out)")
            XCTAssertFalse(c.isRefreshing)
        }
        XCTAssertLessThanOrEqual(applied.count, 60)
    }
}

// HealthKitManager's shared in-flight fetch: a timed-out fetch must be abandoned so the next
// caller starts a new one, and the abandoned creator must not return data to its caller.
@MainActor
final class HealthKitFetchAbandonTests: XCTestCase {

    override func tearDown() {
        HealthKitManager.shared.last28DaysFetchOperation = nil
        HealthKitManager.shared.abandonInFlightLast28DaysFetch()
        super.tearDown()
    }

    func testAbandonedFetchIsNotJoinedAndItsLateResultIsRejected() async throws {
        let m = HealthKitManager.shared
        let hung = Gate()
        m.last28DaysFetchOperation = { try await hung.wait() }

        let creator = Task { @MainActor in try await m.fetchLast28Days() }
        try await Task.sleep(nanoseconds: 50_000_000)

        m.abandonInFlightLast28DaysFetch()

        let fresh = Gate()
        await fresh.release(payload(2))
        m.last28DaysFetchOperation = { try await fresh.wait() }
        let got = try await m.fetchLast28Days()
        let freshCalls = await fresh.calls
        XCTAssertEqual(got.last?.steps, 2)
        XCTAssertEqual(freshCalls, 1, "the next caller starts a new fetch instead of joining the hung one")

        await hung.release(payload(1))
        let late = await creator.result
        if case .success = late { XCTFail("the abandoned creator must not return its late data") }
    }
}

// DEBUG ring buffer of refresh durations.
@MainActor
final class RefreshDurationLogTests: XCTestCase {

    private var saved: Data?
    private var suite: UserDefaults? { UserDefaults(suiteName: SharedStore.appGroupID) }

    override func setUp() {
        super.setUp()
        saved = suite?.data(forKey: RefreshDurationLog.key)
        suite?.removeObject(forKey: RefreshDurationLog.key)
    }

    override func tearDown() {
        if let saved { suite?.set(saved, forKey: RefreshDurationLog.key) }
        else { suite?.removeObject(forKey: RefreshDurationLog.key) }
        super.tearDown()
    }

    private func entry(_ ms: Int, outcome: String = "success") -> RefreshDurationEntry {
        RefreshDurationEntry(date: Date(timeIntervalSince1970: Double(ms)), ms: ms, outcome: outcome,
                             source: "userTap", joined: false)
    }

    func testKeepsNewest50() {
        for ms in 1...70 { RefreshDurationLog.record(entry(ms)) }
        let log = RefreshDurationLog.load()
        XCTAssertEqual(log.count, 50)
        XCTAssertEqual(log.first?.ms, 21)
        XCTAssertEqual(log.last?.ms, 70)
    }

    func testSummaryComputesP50P90MaxAndTimeouts() {
        // 1...10 ms: nearest-rank p50 = 5, p90 = 9, max = 10; two entries are timeouts.
        var entries = (1...8).map { entry($0) }
        entries += [entry(9, outcome: "timeout"), entry(10, outcome: "timeout")]
        let s = RefreshDurationLog.summary(of: entries)
        XCTAssertEqual(s, RefreshDurationSummary(count: 10, p50: 5, p90: 9, max: 10, timeouts: 2))
    }

    func testSummaryOfEmptyLogIsZero() {
        XCTAssertEqual(RefreshDurationLog.summary(of: []),
                       RefreshDurationSummary(count: 0, p50: 0, p90: 0, max: 0, timeouts: 0))
    }

    func testSavedKeyIsRestoredAfterTest() {
        // setUp stashed whatever was there and cleared it; the buffer starts empty.
        XCTAssertTrue(RefreshDurationLog.load().isEmpty)
    }
}
