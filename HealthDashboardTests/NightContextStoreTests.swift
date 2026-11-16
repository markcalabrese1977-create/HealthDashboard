import XCTest
@testable import HealthDashboard

// NightContextTag capture store: round-trips, and is isolated from the manual-inputs and
// verdict-log stores (it must not read or write either).
final class NightContextStoreTests: XCTestCase {

    private var suite: UserDefaults? { UserDefaults(suiteName: SharedStore.appGroupID) }
    private var savedContext: Data?
    private var hadContext = false

    override func setUp() {
        super.setUp()
        // Snapshot and clear only this store's key so the tests don't depend on device state.
        savedContext = suite?.data(forKey: SharedStore.nightContextKey)
        hadContext = savedContext != nil
        suite?.removeObject(forKey: SharedStore.nightContextKey)
    }

    override func tearDown() {
        if hadContext, let saved = savedContext {
            suite?.set(saved, forKey: SharedStore.nightContextKey)
        } else {
            suite?.removeObject(forKey: SharedStore.nightContextKey)
        }
        super.tearDown()
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    func testTagRoundTripsAndUnsets() {
        let d = day(2001, 3, 4)
        XCTAssertTrue(SharedStore.nightContextTags(for: d).isEmpty)

        SharedStore.setNightContextTag(.warmRoom, on: true, for: d)
        XCTAssertEqual(SharedStore.nightContextTags(for: d), [.warmRoom])
        XCTAssertTrue(SharedStore.nightContextTags(for: day(2001, 3, 5)).isEmpty, "tags are per night")

        SharedStore.setNightContextTag(.warmRoom, on: false, for: d)
        XCTAssertTrue(SharedStore.nightContextTags(for: d).isEmpty)
        XCTAssertNil(SharedStore.loadNightContext()["2001-03-04"], "an empty set removes the day entry")
    }

    func testRawValueIsStable() {
        XCTAssertEqual(NightContextTag.warmRoom.rawValue, "warmRoom")
    }

    func testUnknownStoredTagSurvivesReadModifyWrite() {
        let d = day(2001, 3, 4)
        let raw = try! JSONEncoder().encode(["2001-03-04": ["someFutureTag"]])
        suite?.set(raw, forKey: SharedStore.nightContextKey)

        XCTAssertTrue(SharedStore.nightContextTags(for: d).isEmpty, "unknown tags are not surfaced")
        SharedStore.setNightContextTag(.warmRoom, on: true, for: d)

        XCTAssertEqual(Set(SharedStore.loadNightContext()["2001-03-04"] ?? []),
                       ["someFutureTag", "warmRoom"])
    }

    func testTrimKeepsNewest60Days() {
        let base = day(2001, 1, 1)
        for i in 0..<62 {
            let d = Calendar.current.date(byAdding: .day, value: i, to: base)!
            SharedStore.setNightContextTag(.warmRoom, on: true, for: d)
        }
        let all = SharedStore.loadNightContext()
        XCTAssertEqual(all.count, 60)
        XCTAssertEqual(all.keys.sorted().first, "2001-01-03", "two oldest days dropped")
    }

    func testDoesNotTouchManualOrVerdictLog() {
        // Seed a manual value dated today so loadManual() has nothing to expire (it removes an
        // expired key), and restore whatever the store held afterwards.
        let savedManual = suite?.data(forKey: SharedStore.manualKey)
        defer {
            if let savedManual { suite?.set(savedManual, forKey: SharedStore.manualKey) }
            else { suite?.removeObject(forKey: SharedStore.manualKey) }
        }
        SharedStore.saveManual(ManualReadinessInputs(painLevel: 3, isSick: false))

        let manualBefore = SharedStore.loadManual()
        let logBefore = SharedStore.loadVerdictLog()
        let manualRawBefore = suite?.data(forKey: SharedStore.manualKey)
        let logRawBefore = suite?.data(forKey: SharedStore.verdictLogKey)

        let d = day(2001, 3, 4)
        SharedStore.setNightContextTag(.warmRoom, on: true, for: d)
        _ = SharedStore.nightContextTags(for: d)
        SharedStore.setNightContextTag(.warmRoom, on: false, for: d)

        XCTAssertEqual(SharedStore.loadManual(), manualBefore)
        XCTAssertEqual(SharedStore.loadVerdictLog(), logBefore)
        XCTAssertEqual(suite?.data(forKey: SharedStore.manualKey), manualRawBefore)
        XCTAssertEqual(suite?.data(forKey: SharedStore.verdictLogKey), logRawBefore)
    }
}

// Sleep driver row and Sleep tile read the same value (ReadinessResult.sleepDelta) in the same format.
final class SleepDriverSubtitleTests: XCTestCase {

    private func result(sleepDelta: Double?, negative: Bool = true) -> ReadinessResult {
        var r = ReadinessResult.empty
        r.action = .yellow
        r.truth = .yellow
        r.rawTruth = .yellow
        r.sleepDelta = sleepDelta
        r.drivers = [ReadinessDriver(label: "Sleep", impact: 1, isNegative: negative,
                                     reason: "ENGINE REASON", consecutiveDays: 0)]
        return r
    }

    func testNegativeSleepRowShowsTileNumber() {
        let r = result(sleepDelta: -0.54)
        XCTAssertEqual(r.driverDisplays().first?.subtitle, "0.5 h under target.")
        // Same formatting the tile applies to the same value: String(format: "%.1f", d).
        XCTAssertEqual(String(format: "%.1f", abs(-0.54)), "0.5")
    }

    func testFallsBackToEngineReasonWithoutDelta() {
        XCTAssertEqual(result(sleepDelta: nil).driverDisplays().first?.subtitle, "ENGINE REASON")
    }

    func testPositiveSleepRowKeepsEngineReason() {
        XCTAssertEqual(result(sleepDelta: 0.8, negative: false).driverDisplays().first?.subtitle, "ENGINE REASON")
    }
}
