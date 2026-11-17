import XCTest
@testable import HealthDashboard

// Query D: yellows that reached yellow without two cluster flags (the score path).
final class SubThresholdYellowTests: XCTestCase {

    private var suite: UserDefaults? { UserDefaults(suiteName: SharedStore.appGroupID) }
    private var saved: Data?

    override func setUp() {
        super.setUp()
        saved = suite?.data(forKey: SharedStore.verdictLogKey)
    }

    override func tearDown() {
        if let saved { suite?.set(saved, forKey: SharedStore.verdictLogKey) }
        else { suite?.removeObject(forKey: SharedStore.verdictLogKey) }
        super.tearDown()
    }

    private func seed(_ records: [DailyVerdictRecord]) {
        suite?.set(try! JSONEncoder().encode(records), forKey: SharedStore.verdictLogKey)
    }

    func testCountsSeparateScoreOnlyFromClusterAndLoadYellows() {
        seed([
            // (a) 0-flag recovery yellow: score path, every signal under its own flag threshold
            DailyVerdictRecord(dateISO: "2001-01-01", rawTotal: -4, rawRecovery: -4,
                               rawTruth: .yellow, rawRecoveryTruth: .yellow),
            // (b) 1-flag recovery yellow (rhrUp4 = legacy key for rhrUp3): flag plus score fillers
            DailyVerdictRecord(dateISO: "2001-01-02", rawTotal: -5, rawRecovery: -5,
                               rawTruth: .yellow, rhrUp4: true, rawRecoveryTruth: .yellow),
            // (c) 2-flag yellow: cluster path
            DailyVerdictRecord(dateISO: "2001-01-03", rawTotal: -3, rawRecovery: -3,
                               rawTruth: .yellow, tempUp03: true, rrUp10: true, rawRecoveryTruth: .yellow),
            // (d) load-only yellow: load-stripped verdict is green
            DailyVerdictRecord(dateISO: "2001-01-04", rawTotal: -4, rawRecovery: -1,
                               rawTruth: .yellow, rawRecoveryTruth: .green),
            // green day: never counted
            DailyVerdictRecord(dateISO: "2001-01-05", rawTotal: 0, rawRecovery: 0,
                               rawTruth: .green, rawRecoveryTruth: .green),
        ])

        let s = SharedStore.dumpSubThresholdYellows()

        XCTAssertEqual(s.recoveryYellows, 3)
        XCTAssertEqual(s.scoreOnly, 2)
        XCTAssertEqual(s.zeroFlag, 1)
        XCTAssertEqual(s.yellows, 4)
        XCTAssertEqual(s.loadOnly, 1)
        XCTAssertEqual(s.scoreOnlyDates, ["2001-01-01", "2001-01-02"])
    }
}
