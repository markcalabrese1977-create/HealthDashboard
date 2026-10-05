import XCTest
@testable import HealthDashboard

final class LiveEvaluationPolicyTests: XCTestCase {

    // MARK: Helpers

    private func clearLog() {
        UserDefaults(suiteName: SharedStore.appGroupID)?.removeObject(forKey: SharedStore.verdictLogKey)
    }

    private func logData() -> Data? {
        UserDefaults(suiteName: SharedStore.appGroupID)?.data(forKey: SharedStore.verdictLogKey)
    }

    private func isoDay(daysFromToday offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        return LiveEvaluationPolicy.todayISO(now: d)
    }

    private func point(dayISO: String, rhr: Double = 65, hrv: Double = 30) -> DailyHealthPoint {
        DailyHealthPoint(
            dayISO: dayISO,
            restingHR: rhr,
            hrvMS: hrv,
            sleepHours: 8,
            sleepInBedHours: 8.7,
            respiratoryRate: 15,
            spo2Pct: 98,
            wristTempDeltaC: 36.5,
            steps: 8000,
            activeEnergyKcal: 500,
            exerciseMinutes: 45,
            standHours: 10,
            workoutCount: 1,
            workoutMinutes: 60,
            workoutEnergyKcal: 400,
            dailyTrimp: nil,
            bodyWeightLb: nil,
            bodyFatPct: nil,
            leanMassLb: nil
        )
    }

    /// 28 days ending `endOffset` days from today (0 = ends today, -1 = ends yesterday); the last
    /// day carries a deviation so the evaluation is not a trivial all-neutral one.
    private func history(endingDaysFromToday endOffset: Int) -> [DailyHealthPoint] {
        (0..<28).map { i in
            let offset = endOffset - (27 - i)
            return point(dayISO: isoDay(daysFromToday: offset),
                         rhr: i == 27 ? 71 : 65,
                         hrv: i == 27 ? 25 : 30)
        }
    }

    private func seedYesterdayRecord() {
        SharedStore.appendVerdictLog(
            DailyVerdictRecord(dateISO: isoDay(daysFromToday: -1), rawTotal: -5, rawRecovery: -5,
                               rawTruth: .yellow, rawRecoveryTruth: .yellow)
        )
    }

    // MARK: 1. Slot-key agreement

    func testTodayISOMatchesTheEnginesPersistedSlotKey() throws {
        clearLog()
        let before = LiveEvaluationPolicy.todayISO()
        _ = ReadinessEngine.evaluate(history: history(endingDaysFromToday: 0), manual: .default)
        let after = LiveEvaluationPolicy.todayISO()

        let records = SharedStore.loadVerdictLog()
        XCTAssertEqual(records.count, 1)
        let key = try XCTUnwrap(records.first).dateISO
        XCTAssertTrue(key == before || key == after,
                      "engine slot key \(key) must equal todayISO() (before=\(before), after=\(after))")
    }

    // MARK: 2. Predicate

    func testShouldSuppressPredicateTable() {
        let today = "2026-10-05"
        XCTAssertFalse(LiveEvaluationPolicy.shouldSuppressPersistence(historyLastDayISO: "2026-10-05", todayISO: today))
        XCTAssertTrue(LiveEvaluationPolicy.shouldSuppressPersistence(historyLastDayISO: "2026-10-04", todayISO: today))
        XCTAssertTrue(LiveEvaluationPolicy.shouldSuppressPersistence(historyLastDayISO: nil, todayISO: today))
        // A history that ends in the future is also "not today".
        XCTAssertTrue(LiveEvaluationPolicy.shouldSuppressPersistence(historyLastDayISO: "2026-10-06", todayISO: today))
    }

    func testEmptyHistoryIsTreatedAsNotToday() {
        clearLog()
        _ = LiveEvaluationPolicy.evaluateForLive(history: [], manual: .default)
        XCTAssertNil(logData(), "empty history must not create the log key")
    }

    // MARK: 3. History ending yesterday: no persistence

    func testStaleHistoryLeavesStoredLogUnchanged() {
        clearLog()
        seedYesterdayRecord()
        let before = logData()
        XCTAssertNotNil(before)

        _ = LiveEvaluationPolicy.evaluateForLive(history: history(endingDaysFromToday: -1), manual: .default)

        XCTAssertEqual(logData(), before)
    }

    func testStaleHistoryOnEmptyLogCreatesNoKey() {
        clearLog()
        _ = LiveEvaluationPolicy.evaluateForLive(history: history(endingDaysFromToday: -1), manual: .default)
        XCTAssertNil(logData())
    }

    // MARK: 4. History ending today: persists

    func testHistoryEndingTodayPersistsTodaysRecord() {
        clearLog()
        let before = LiveEvaluationPolicy.todayISO()
        _ = LiveEvaluationPolicy.evaluateForLive(history: history(endingDaysFromToday: 0), manual: .default)
        let after = LiveEvaluationPolicy.todayISO()

        let keys = Set(SharedStore.loadVerdictLog().map { $0.dateISO })
        XCTAssertTrue(keys.contains(before) || keys.contains(after), "\(keys)")
    }

    // MARK: 5. Verdict-level equivalence for the stale case
    //
    // Suppressing persistence must not change what the card shows. Compared: every verdict-level field.
    // Excluded, deliberately:
    //   * drivers[].consecutiveDays: SharedStore.consecutiveDaysActive reads TODAY's slot after the
    //     call's own write, so a persisting call counts its own flag (1) where a suppressed call
    //     finds no slot (0). It feeds only display copy (the "Nth day" badge, the HRV subtitle),
    //     never a verdict, score, gate or confidence field.
    //   * flags order: built from Dictionary(grouping:).keys, whose order is unspecified, so it is
    //     compared as a set.
    func testStaleEvaluationMatchesPlainPersistingEvaluationOnVerdictFields() {
        let stale = history(endingDaysFromToday: -1)

        clearLog(); seedYesterdayRecord()
        let live = LiveEvaluationPolicy.evaluateForLive(history: stale, manual: .default)

        clearLog(); seedYesterdayRecord()
        let plain = ReadinessEngine.evaluate(history: stale, manual: .default)

        XCTAssertEqual(live.truth, plain.truth)
        XCTAssertEqual(live.rawTruth, plain.rawTruth)
        XCTAssertEqual(live.action, plain.action)
        XCTAssertEqual(live.rawRecoveryTruth, plain.rawRecoveryTruth)
        XCTAssertEqual(live.confidence, plain.confidence)
        XCTAssertEqual(live.totalScore, plain.totalScore)
        XCTAssertEqual(live.canPushKeyLift, plain.canPushKeyLift)
        XCTAssertEqual(Set(live.flags), Set(plain.flags))
        XCTAssertEqual(live.drivers.map { $0.label }, plain.drivers.map { $0.label })
        XCTAssertEqual(live.drivers.map { $0.isNegative }, plain.drivers.map { $0.isNegative })
        XCTAssertEqual(live.drivers.map { $0.impact }, plain.drivers.map { $0.impact })
    }
}
