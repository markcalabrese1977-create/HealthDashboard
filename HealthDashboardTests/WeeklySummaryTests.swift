import XCTest
@testable import HealthDashboard

final class WeeklySummaryTests: XCTestCase {

    // MARK: Fixed reference date and fixture

    /// Wednesday 2026-10-14, local noon. ISO week: Mon 2026-10-12 ... Sun 2026-10-18.
    /// This week so far: Oct 12, 13, 14. Prior week: Oct 5 ... Oct 11.
    static let wednesday: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 14; c.hour = 12
        return Calendar.current.date(from: c)!
    }()

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    static func iso(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// 28 deterministic, varied days ending `lastDay` (inclusive). Values are pure functions of the
    /// day index, so the fixture never changes.
    static func fixture(endingOn lastDay: Date, count: Int = 28) -> [DailyHealthPoint] {
        (0..<count).map { i in
            let day = Calendar.current.date(byAdding: .day, value: i - (count - 1), to: lastDay)!
            let sleep = 6.5 + Double((i * 3) % 8) / 4.0
            let workout = (i % 3 == 0)
            return DailyHealthPoint(
                dayISO: iso(day),
                restingHR: 58 + Double((i * 7) % 6),
                hrvMS: 26 + Double((i * 5) % 9),
                sleepHours: sleep,
                sleepInBedHours: sleep + 0.5 + Double(i % 3) / 10.0,
                respiratoryRate: 14.0 + Double((i * 2) % 5) / 5.0,
                spo2Pct: 97 + Double(i % 3) * 0.5,
                wristTempDeltaC: 0.0 + Double(i % 4) / 10.0 - 0.1,
                steps: 6000 + Double((i * 937) % 5000),
                activeEnergyKcal: 400 + Double((i * 61) % 300),
                exerciseMinutes: 20 + Double((i * 11) % 50),
                standHours: 8 + Double(i % 5),
                workoutCount: workout ? 1 : 0,
                workoutMinutes: workout ? 45 : 0,
                workoutEnergyKcal: workout ? 350 : 0,
                dailyTrimp: workout ? 30 + Double((i * 13) % 40) : nil,
                bodyWeightLb: nil,
                bodyFatPct: nil,
                leanMassLb: nil
            )
        }
    }

    // MARK: Verdict-log isolation
    //
    // These tests seed the shared verdict log (the badge is evaluate-driven, see below). Clear it before
    // AND after every test so nothing leaks into other test classes or into the next test.

    private func clearVerdictLog() {
        UserDefaults(suiteName: SharedStore.appGroupID)?.removeObject(forKey: SharedStore.verdictLogKey)
    }

    override func setUp() {
        super.setUp()
        clearVerdictLog()
    }

    override func tearDown() {
        clearVerdictLog()
        super.tearDown()
    }

    // MARK: Verdict-log seeding
    //
    // build() runs ReadinessEngine.evaluate per day of this week for the badge. The engine's
    // hysteresis gate reads the verdict log's record for WALL-CLOCK yesterday, so the badge is only
    // deterministic if that record is pinned. These tests clear the log and seed a green record.
    // (build's evaluate calls are persistence-suppressed, so they never write the log.)

    private func wallClockYesterdayISO() -> String {
        let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return Self.iso(y)
    }

    /// Seeds a green record for wall-clock yesterday, computed at RUNTIME from `Date()` (never a
    /// hard-coded date), because the gate looks up yesterday relative to the moment the test runs.
    private func seedGreenYesterday() {
        clearVerdictLog()
        SharedStore.appendVerdictLog(
            DailyVerdictRecord(dateISO: wallClockYesterdayISO(), rawTotal: 4, rawRecovery: 4,
                               rawTruth: .green, rawRecoveryTruth: .green)
        )
    }

    // MARK: Characterization: pins build()'s CURRENT outputs for a fixed Wednesday (2026-10-14).
    //
    // The expected numbers below were produced by running the unchanged logic once and hard-coding
    // the results. They exist so later changes to WeeklySummary.build can prove they left the
    // existing five rows, the badge and the narrative alone.
    //
    // NOT pinned: the "Oct 12 – Oct 14 · vs Oct 5 – Oct 11" date-range label. It is computed in the
    // private `WeeklySummaryCard.dateRangeLabel` from `Date()`, outside build(), so a fixed date
    // cannot reach it without editing the view.

    private let accuracy = 1e-9

    private func wednesdaySummary() throws -> WeeklySummary {
        seedGreenYesterday()
        return try XCTUnwrap(WeeklySummary.build(
            history: Self.fixture(endingOn: Self.wednesday), manual: .default, today: Self.wednesday))
    }

    func testWindowMembershipOnAWednesday() throws {
        let s = try wednesdaySummary()
        XCTAssertEqual(s.thisWeek.map { $0.dayISO }, ["2026-10-12", "2026-10-13", "2026-10-14"])
        XCTAssertEqual(s.priorWeek.map { $0.dayISO },
                       ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08",
                        "2026-10-09", "2026-10-10", "2026-10-11"])
    }

    func testFiveRowsOrderTitlesAndAverages() throws {
        let s = try wednesdaySummary()
        XCTAssertEqual(s.metrics.map { $0.title }, ["HRV", "Resting HR", "Sleep", "Sleep Eff", "Resp Rate"])

        let expected: [(title: String, this: Double, prior: Double, dir: WeeklySummary.MetricWeek.Direction)] = [
            ("HRV",        30.0,                29.428571428571427, .up),
            ("Resting HR", 60.0,                60.142857142857146, .neutral),
            ("Sleep",      7.333333333333333,   7.392857142857143,  .neutral),
            ("Sleep Eff",  92.47138638748567,   92.62598471699432,  .neutral),
            ("Resp Rate",  14.4,                14.4,               .neutral),
        ]
        for (m, e) in zip(s.metrics, expected) {
            XCTAssertEqual(m.thisWeekAvg ?? .nan, e.this, accuracy: accuracy, "\(e.title) this")
            XCTAssertEqual(m.priorWeekAvg ?? .nan, e.prior, accuracy: accuracy, "\(e.title) prior")
            XCTAssertEqual(m.direction, e.dir, "\(e.title) direction")
        }
    }

    func testRowUnitsAndFormatting() throws {
        let s = try wednesdaySummary()
        let byTitle = Dictionary(uniqueKeysWithValues: s.metrics.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["HRV"]?.unit, "ms");           XCTAssertEqual(byTitle["HRV"]?.formatDigits, 0)
        XCTAssertEqual(byTitle["Resting HR"]?.unit, "bpm");   XCTAssertEqual(byTitle["Resting HR"]?.formatDigits, 0)
        XCTAssertEqual(byTitle["Sleep"]?.unit, "h");          XCTAssertEqual(byTitle["Sleep"]?.formatDigits, 1)
        XCTAssertEqual(byTitle["Sleep Eff"]?.unit, "%");      XCTAssertEqual(byTitle["Sleep Eff"]?.formatDigits, 0)
        XCTAssertEqual(byTitle["Resp Rate"]?.unit, "br/min"); XCTAssertEqual(byTitle["Resp Rate"]?.formatDigits, 1)
        XCTAssertEqual(byTitle["HRV"]?.higherIsBetter, true)
        XCTAssertEqual(byTitle["Resting HR"]?.higherIsBetter, false)
        XCTAssertEqual(byTitle["Resp Rate"]?.higherIsBetter, false)
    }

    func testNarrativeSentencesOnAWednesday() throws {
        let s = try wednesdaySummary()
        XCTAssertEqual(
            s.narrative,
            "HRV averaged 30 ms this week, up 1 ms from last week — a positive recovery trend. Sleep was consistent at 7h 19m average. Resting HR held steady at 60 bpm. You trained 1 day this week."
        )
    }

    // The badge is evaluate-driven, so it is only pinnable with the verdict log pinned (see the seeding
    // note above). With wall-clock yesterday's record green, every raw-green day displays green.
    func testBadgeWithSeededGreenYesterdayIsStrongWeek() throws {
        let s = try wednesdaySummary()
        XCTAssertEqual(try XCTUnwrap(s.avgReadinessScore), 2.0, accuracy: accuracy)
        XCTAssertEqual(s.readinessColor, .green)
    }

    // CHARACTERIZATION OF CURRENT BEHAVIOR. NOT DESIRED BEHAVIOR.
    // The hysteresis gate reads the verdict-log record for WALL-CLOCK yesterday for every day in the
    // weekly loop (not the day before each evaluated day). So when that record is missing, every
    // raw-green day is held at yellow and the badge reads "Mixed week" (average score 1.0) regardless
    // of how good the week was. This test pins that quirk so a deliberate change to it shows up as a
    // test change; it does not endorse it.
    func testCharacterization_emptyLogHoldsRawGreenDaysAtYellow_notDesiredBehavior() throws {
        clearVerdictLog()
        let s = try XCTUnwrap(WeeklySummary.build(
            history: Self.fixture(endingOn: Self.wednesday), manual: .default, today: Self.wednesday))
        XCTAssertEqual(try XCTUnwrap(s.avgReadinessScore), 1.0, accuracy: accuracy)
        XCTAssertEqual(s.readinessColor, .yellow)
    }

    func testSundayWindowAveragesBadgeAndNarrative() throws {
        seedGreenYesterday()
        let sunday = Self.date(2026, 10, 18)
        let s = try XCTUnwrap(WeeklySummary.build(
            history: Self.fixture(endingOn: sunday), manual: .default, today: sunday))

        XCTAssertEqual(s.thisWeek.map { $0.dayISO },
                       ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15",
                        "2026-10-16", "2026-10-17", "2026-10-18"])
        XCTAssertEqual(s.priorWeek.count, 7)

        let expected: [(Double, Double)] = [
            (30.285714285714285, 30.0),                 // HRV
            (60.57142857142857,  60.42857142857143),    // Resting HR
            (7.357142857142857,  7.25),                 // Sleep
            (92.62546511350999,  92.1443636519199),     // Sleep Eff
            (14.457142857142857, 14.37142857142857),    // Resp Rate
        ]
        for (m, e) in zip(s.metrics, expected) {
            XCTAssertEqual(m.thisWeekAvg ?? .nan, e.0, accuracy: accuracy, "\(m.title) this")
            XCTAssertEqual(m.priorWeekAvg ?? .nan, e.1, accuracy: accuracy, "\(m.title) prior")
            XCTAssertEqual(m.direction, .neutral, "\(m.title) direction")
        }
        XCTAssertEqual(try XCTUnwrap(s.avgReadinessScore), 2.0, accuracy: accuracy)
        XCTAssertEqual(s.readinessColor, .green)
        XCTAssertEqual(
            s.narrative,
            "HRV was stable this week, averaging 30 ms. Sleep was consistent at 7h 21m average. Resting HR held steady at 61 bpm. You trained 3 days this week."
        )
    }

    // MARK: nil cases

    func testBuildReturnsNilWhenFewerThanSevenPoints() {
        let six = Self.fixture(endingOn: Self.wednesday, count: 6)
        XCTAssertNil(WeeklySummary.build(history: six, manual: .default, today: Self.wednesday))
    }

    func testBuildReturnsSummaryAtExactlySevenPoints() {
        let seven = Self.fixture(endingOn: Self.wednesday, count: 7)
        XCTAssertNotNil(WeeklySummary.build(history: seven, manual: .default, today: Self.wednesday))
    }

    // History that ends the previous Sunday has no point on or after this Monday: the card is hidden.
    func testBuildReturnsNilWhenThisWeekIsEmpty() {
        let previousSunday = Self.date(2026, 10, 11)
        let h = Self.fixture(endingOn: previousSunday)
        XCTAssertNil(WeeklySummary.build(history: h, manual: .default, today: Self.wednesday))
    }

    // MARK: Load comparison (commit 2)
    //
    // Commit 1's characterization tests above are unchanged and still run through build(), which now
    // also fills `loadComparison`; they passing is the proof that the five rows, the badge and the
    // narrative did not move.

    private let cal = Calendar(identifier: .iso8601)

    /// A fixture whose TRIMP and mechanical load come ONLY from the given per-day maps (nil elsewhere).
    private func loadHistory(
        endingOn last: Date, count: Int = 28,
        trimp: [String: Double] = [:], ml: [String: Double] = [:]
    ) -> [DailyHealthPoint] {
        Self.fixture(endingOn: last, count: count).map { point in
            var p = point
            p.dailyTrimp = trimp[p.dayISO]
            p.mechanicalLoad = ml[p.dayISO]
            return p
        }
    }

    private func isoOf(_ d: Date) -> String { LoadWeekComparison.dayISO(d) }

    // 1. Window sizes by weekday ------------------------------------------------------------

    func testMondayHasNoCompletedDaysSoNil() {
        let monday = Self.date(2026, 10, 12)
        XCTAssertNil(LoadWeekComparison.compute(history: loadHistory(endingOn: monday), today: monday))
    }

    func testTuesdayComparesOneDayAgainstOneDay() throws {
        let tuesday = Self.date(2026, 10, 13)
        let c = try XCTUnwrap(LoadWeekComparison.compute(history: loadHistory(endingOn: tuesday), today: tuesday))
        XCTAssertEqual(c.completedDays, 1)
        XCTAssertEqual([isoOf(c.thisWindowStart), isoOf(c.thisWindowEnd)], ["2026-10-12", "2026-10-12"])
        XCTAssertEqual([isoOf(c.priorWindowStart), isoOf(c.priorWindowEnd)], ["2026-10-05", "2026-10-05"])
    }

    func testWednesdayComparesTwoDays() throws {
        let c = try XCTUnwrap(LoadWeekComparison.compute(
            history: loadHistory(endingOn: Self.wednesday), today: Self.wednesday))
        XCTAssertEqual(c.completedDays, 2)
        XCTAssertEqual([isoOf(c.thisWindowStart), isoOf(c.thisWindowEnd)], ["2026-10-12", "2026-10-13"])
        XCTAssertEqual([isoOf(c.priorWindowStart), isoOf(c.priorWindowEnd)], ["2026-10-05", "2026-10-06"])
    }

    func testSundayComparesMondayThroughSaturdayAgainstTheSameSixDays() throws {
        let sunday = Self.date(2026, 10, 18)
        let c = try XCTUnwrap(LoadWeekComparison.compute(history: loadHistory(endingOn: sunday), today: sunday))
        XCTAssertEqual(c.completedDays, 6)
        XCTAssertEqual([isoOf(c.thisWindowStart), isoOf(c.thisWindowEnd)], ["2026-10-12", "2026-10-17"])
        XCTAssertEqual([isoOf(c.priorWindowStart), isoOf(c.priorWindowEnd)], ["2026-10-05", "2026-10-10"])
    }

    func testWindowAcrossAMonthBoundary() throws {
        let thursday = Self.date(2026, 10, 1)      // week starts Monday 2026-09-28
        let c = try XCTUnwrap(LoadWeekComparison.compute(history: loadHistory(endingOn: thursday), today: thursday))
        XCTAssertEqual(c.completedDays, 3)
        XCTAssertEqual([isoOf(c.thisWindowStart), isoOf(c.thisWindowEnd)], ["2026-09-28", "2026-09-30"])
        XCTAssertEqual([isoOf(c.priorWindowStart), isoOf(c.priorWindowEnd)], ["2026-09-21", "2026-09-23"])
        XCTAssertEqual(
            LoadWeekComparison.caption(thisStart: c.thisWindowStart, thisEnd: c.thisWindowEnd,
                                       priorStart: c.priorWindowStart, priorEnd: c.priorWindowEnd,
                                       locale: Locale(identifier: "en_US")),
            "Load (completed days): Sep 28 – Sep 30 vs Sep 21 – Sep 23")
    }

    // 2. Sums and delta; nil days count as 0 -------------------------------------------------

    func testSumsAndDeltasCountNilDaysAsZero() throws {
        let h = loadHistory(
            endingOn: Self.wednesday,
            trimp: ["2026-10-12": 40, /* 10-13 nil */ "2026-10-05": 25, "2026-10-06": 35],
            ml:    ["2026-10-12": 12000, "2026-10-13": 3000, /* 10-05 nil */ "2026-10-06": 9000]
        )
        let c = try XCTUnwrap(LoadWeekComparison.compute(history: h, today: Self.wednesday))
        XCTAssertEqual(c.trimpThis, 40);     XCTAssertEqual(c.trimpPrior, 60);    XCTAssertEqual(c.trimpDelta, -20)
        XCTAssertEqual(c.strengthThis, 15000); XCTAssertEqual(c.strengthPrior, 9000); XCTAssertEqual(c.strengthDelta, 6000)
        XCTAssertTrue(c.showsTrimp)
        XCTAssertTrue(c.showsStrength)
    }

    // 3. A missing point in either window gives nil ----------------------------------------------

    func testMissingPointInThisWindowGivesNil() {
        let h = loadHistory(endingOn: Self.wednesday).filter { $0.dayISO != "2026-10-13" }
        XCTAssertNil(LoadWeekComparison.compute(history: h, today: Self.wednesday))
    }

    func testMissingPointInPriorWindowGivesNil() {
        let h = loadHistory(endingOn: Self.wednesday).filter { $0.dayISO != "2026-10-06" }
        XCTAssertNil(LoadWeekComparison.compute(history: h, today: Self.wednesday))
    }

    func testMissingPointsOutsideTheWindowsDoNotMatter() {
        // 10-04 is before the prior window; 10-14 is today (never part of a window).
        let h = loadHistory(endingOn: Self.wednesday).filter { $0.dayISO != "2026-10-04" && $0.dayISO != "2026-10-14" }
        XCTAssertNotNil(LoadWeekComparison.compute(history: h, today: Self.wednesday))
    }

    // 4. Availability flags ----------------------------------------------------------------

    func testNoPositiveTrimpAnywhereHidesTrimpButNotStrength() throws {
        let h = loadHistory(endingOn: Self.wednesday, trimp: ["2026-10-12": 0], ml: ["2026-10-12": 5000])
        let c = try XCTUnwrap(LoadWeekComparison.compute(history: h, today: Self.wednesday))
        XCTAssertFalse(c.showsTrimp, "a 0 is not a positive value")
        XCTAssertTrue(c.showsStrength)
    }

    func testNoPositiveMechanicalLoadAnywhereHidesStrengthButNotTrimp() throws {
        let h = loadHistory(endingOn: Self.wednesday, trimp: ["2026-10-06": 33])
        let c = try XCTUnwrap(LoadWeekComparison.compute(history: h, today: Self.wednesday))
        XCTAssertTrue(c.showsTrimp)
        XCTAssertFalse(c.showsStrength)
    }

    func testBothHiddenWhenNeitherLoadExistsAnywhere() throws {
        let c = try XCTUnwrap(LoadWeekComparison.compute(
            history: loadHistory(endingOn: Self.wednesday), today: Self.wednesday))
        XCTAssertFalse(c.showsTrimp)
        XCTAssertFalse(c.showsStrength)
    }

    func testAPositiveValueOutsideBothWindowsStillEnablesTheRow() throws {
        // 10-01 is in neither window, but the user clearly has TRIMP data.
        let h = loadHistory(endingOn: Self.wednesday, trimp: ["2026-10-01": 50])
        let c = try XCTUnwrap(LoadWeekComparison.compute(history: h, today: Self.wednesday))
        XCTAssertTrue(c.showsTrimp)
        XCTAssertEqual(c.trimpThis, 0)
        XCTAssertEqual(c.trimpPrior, 0)
    }

    // 5. Zero prior vs non-zero current; both zero ---------------------------------------------

    func testZeroPriorWithNonZeroCurrentIsARealPositiveDelta() {
        XCTAssertEqual(LoadWeekComparison.deltaDisplay(this: 30, prior: 0), .up(30))
    }

    func testNonZeroPriorWithZeroCurrentIsARealNegativeDelta() {
        XCTAssertEqual(LoadWeekComparison.deltaDisplay(this: 0, prior: 30), .down(30))
    }

    func testBothZeroIsADash() {
        XCTAssertEqual(LoadWeekComparison.deltaDisplay(this: 0, prior: 0), .dash)
    }

    // 6. The 5% neutral threshold (inclusive) ------------------------------------------------

    func testFivePercentBoundary() {
        // prior 200: 5% is exactly 10.
        XCTAssertEqual(LoadWeekComparison.deltaDisplay(this: 210, prior: 200), .dash, "exactly +5% is neutral")
        XCTAssertEqual(LoadWeekComparison.deltaDisplay(this: 190, prior: 200), .dash, "exactly -5% is neutral")
        XCTAssertEqual(LoadWeekComparison.deltaDisplay(this: 211, prior: 200), .up(11))
        XCTAssertEqual(LoadWeekComparison.deltaDisplay(this: 189, prior: 200), .down(11))
        XCTAssertEqual(LoadWeekComparison.deltaDisplay(this: 200, prior: 200), .dash)
        // prior 100: 5% is 5.
        XCTAssertEqual(LoadWeekComparison.deltaDisplay(this: 105, prior: 100), .dash)
        XCTAssertEqual(LoadWeekComparison.deltaDisplay(this: 105.5, prior: 100), .up(5.5))
    }

    // 7. Today's partial point is never included -------------------------------------------------

    func testTodaysPartialPointIsNeverInAnyWindow() throws {
        let h = loadHistory(
            endingOn: Self.wednesday,
            trimp: ["2026-10-12": 10, "2026-10-13": 20, "2026-10-05": 5, "2026-10-06": 6,
                    "2026-10-14": 999],           // today, partial
            ml:    ["2026-10-12": 100, "2026-10-13": 200, "2026-10-05": 50, "2026-10-06": 60,
                    "2026-10-14": 99999]          // today, partial
        )
        let c = try XCTUnwrap(LoadWeekComparison.compute(history: h, today: Self.wednesday))
        XCTAssertEqual(c.trimpThis, 30)
        XCTAssertEqual(c.trimpPrior, 11)
        XCTAssertEqual(c.strengthThis, 300)
        XCTAssertEqual(c.strengthPrior, 110)
    }

    // 8. The existing outputs are unchanged with loadComparison present ----------------------------

    func testLoadComparisonIsPresentAndTheExistingOutputsAreUnchanged() throws {
        let s = try wednesdaySummary()
        let load = try XCTUnwrap(s.loadComparison)
        XCTAssertEqual(load.completedDays, 2)
        XCTAssertEqual(s.metrics.map { $0.title }, ["HRV", "Resting HR", "Sleep", "Sleep Eff", "Resp Rate"])
        XCTAssertEqual(s.metrics.first?.thisWeekAvg ?? .nan, 30.0, accuracy: accuracy)
        XCTAssertEqual(s.readinessColor, .green)
        XCTAssertEqual(
            s.narrative,
            "HRV averaged 30 ms this week, up 1 ms from last week — a positive recovery trend. Sleep was consistent at 7h 19m average. Resting HR held steady at 60 bpm. You trained 1 day this week."
        )
    }

    func testBuildLeavesLoadComparisonNilOnMonday() throws {
        seedGreenYesterday()
        let monday = Self.date(2026, 10, 12)
        let s = try XCTUnwrap(WeeklySummary.build(
            history: Self.fixture(endingOn: monday), manual: .default, today: monday))
        XCTAssertNil(s.loadComparison)
        XCTAssertEqual(s.thisWeek.count, 1, "Monday: one (partial) day this week; the card still shows")
    }

    // 9. Caption ------------------------------------------------------------------------------------

    func testCaptionForASingleDay() {
        XCTAssertEqual(
            LoadWeekComparison.caption(
                thisStart: Self.date(2026, 10, 12), thisEnd: Self.date(2026, 10, 12),
                priorStart: Self.date(2026, 10, 5), priorEnd: Self.date(2026, 10, 5),
                locale: Locale(identifier: "en_US")),
            "Load (completed days): Oct 12 vs Oct 5")
    }

    func testCaptionForARange() {
        XCTAssertEqual(
            LoadWeekComparison.caption(
                thisStart: Self.date(2026, 10, 12), thisEnd: Self.date(2026, 10, 17),
                priorStart: Self.date(2026, 10, 5), priorEnd: Self.date(2026, 10, 10),
                locale: Locale(identifier: "en_US")),
            "Load (completed days): Oct 12 – Oct 17 vs Oct 5 – Oct 10")
    }

    func testComputedCaptionMatchesTheWindowDates() throws {
        let c = try XCTUnwrap(LoadWeekComparison.compute(
            history: loadHistory(endingOn: Self.wednesday), today: Self.wednesday))
        XCTAssertEqual(
            LoadWeekComparison.caption(thisStart: c.thisWindowStart, thisEnd: c.thisWindowEnd,
                                       priorStart: c.priorWindowStart, priorEnd: c.priorWindowEnd,
                                       locale: Locale(identifier: "en_US")),
            "Load (completed days): Oct 12 – Oct 13 vs Oct 5 – Oct 6")
    }

    // 10. Total formatting ----------------------------------------------------------------------------

    func testFormatTotalUsesGroupingSeparators() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(LoadWeekComparison.formatTotal(15853, locale: us), "15,853")
        XCTAssertEqual(LoadWeekComparison.formatTotal(0, locale: us), "0")
        XCTAssertEqual(LoadWeekComparison.formatTotal(999.6, locale: us), "1,000")
        XCTAssertEqual(LoadWeekComparison.formatTotal(37.2, locale: us), "37")
    }
}
