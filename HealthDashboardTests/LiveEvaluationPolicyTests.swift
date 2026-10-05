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

    // MARK: 6. needsReevaluation truth table

    func testNeedsReevaluationTruthTable() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let t1 = t0.addingTimeInterval(60)

        XCTAssertTrue(LiveEvaluationPolicy.needsReevaluation(previousUpdatedAt: t0, currentUpdatedAt: t1), "newer")
        XCTAssertFalse(LiveEvaluationPolicy.needsReevaluation(previousUpdatedAt: t1, currentUpdatedAt: t1), "equal")
        XCTAssertFalse(LiveEvaluationPolicy.needsReevaluation(previousUpdatedAt: t1, currentUpdatedAt: t0), "older")
        XCTAssertTrue(LiveEvaluationPolicy.needsReevaluation(previousUpdatedAt: nil, currentUpdatedAt: t0), "nil previous")
        XCTAssertFalse(LiveEvaluationPolicy.needsReevaluation(previousUpdatedAt: t0, currentUpdatedAt: nil), "nil current")
        XCTAssertFalse(LiveEvaluationPolicy.needsReevaluation(previousUpdatedAt: nil, currentUpdatedAt: nil), "both nil")
    }

    // MARK: 7. THE INVARIANT: a display re-evaluation reproduces what the persisting writer produced
    //
    // hkObserver (the writer of record) evaluates and persists E1. The card then re-evaluates the same
    // inputs for display (E2, never persisting). E2 must equal E1 in EVERY field, including
    // drivers[].consecutiveDays: E2 reads the slot E1 just wrote, so the streak counts agree.
    // `flags` is compared as a set (its order is nondeterministic: Dictionary(grouping:).keys).

    private func fields(_ r: ReadinessResult) throws -> [String: Any] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var j = try JSONSerialization.jsonObject(with: enc.encode(r)) as! [String: Any]
        if let flags = j["flags"] as? [String] { j["flags"] = flags.sorted() }
        return j
    }

    func testDisplayReevaluationEqualsThePersistingEvaluationInEveryField() throws {
        let h = history(endingDaysFromToday: 0)

        clearLog(); seedYesterdayRecord()
        let e1 = ReadinessEngine.evaluate(history: h, manual: .default)        // as hkObserver would have
        let logAfterE1 = SharedStore.loadVerdictLog()
        let dataAfterE1 = logData()

        let e2 = LiveEvaluationPolicy.evaluateForDisplay(history: h, manual: .default)

        let f1 = try fields(e1), f2 = try fields(e2)
        for key in Set(f1.keys).union(f2.keys).sorted() {
            XCTAssertTrue(
                NSDictionary(dictionary: [key: f1[key] ?? NSNull()]).isEqual(to: [key: f2[key] ?? NSNull()]),
                "field '\(key)': E1=\(String(describing: f1[key])) E2=\(String(describing: f2[key]))"
            )
        }
        XCTAssertEqual(e1.drivers, e2.drivers, "drivers including consecutiveDays")
        XCTAssertFalse(e1.drivers.isEmpty, "fixture must exercise drivers")
        XCTAssertTrue(e1.drivers.contains { $0.consecutiveDays > 0 }, "fixture must exercise consecutiveDays")

        // The display evaluation changed nothing in the store.
        XCTAssertEqual(SharedStore.loadVerdictLog(), logAfterE1)
        XCTAssertEqual(logData(), dataAfterE1, "same stored Data: no re-encode happened")
    }

    // MARK: 8. evaluateForDisplay never touches the log

    func testDisplayEvaluationNeverCreatesTheLogOnAnEmptyLog() {
        clearLog()
        _ = LiveEvaluationPolicy.evaluateForDisplay(history: history(endingDaysFromToday: 0), manual: .default)
        XCTAssertNil(logData())
    }

    func testDisplayEvaluationNeverModifiesAnExistingLog() {
        clearLog(); seedYesterdayRecord()
        let before = logData()
        // Even with history that ends today (which a persisting call WOULD write).
        _ = LiveEvaluationPolicy.evaluateForDisplay(history: history(endingDaysFromToday: 0), manual: .default)
        _ = LiveEvaluationPolicy.evaluateForDisplay(history: history(endingDaysFromToday: -1), manual: .default)
        XCTAssertEqual(logData(), before)
    }
}
