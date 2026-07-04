import XCTest
@testable import HealthDashboard

final class SleepCompositeValidatorTests: XCTestCase {

    private func rec(_ dateISO: String, composite: Double, matured: Bool,
                     axisScores: [SleepAxis: Double] = [:]) -> SleepAxisLogRecord {
        let subs = axisScores.map {
            SleepSubScore(axis: $0.key, score: $0.value, effectiveWeight: 20, available: true)
        }
        return SleepAxisLogRecord(
            dateISO: dateISO,
            composite: composite,
            matured: matured,
            availableAxes: subs.map { $0.axis },
            subScores: subs
        )
    }

    // MARK: - Pearson

    func testPearsonPerfectPositive() {
        XCTAssertEqual(SleepCompositeValidator.pearson([1, 2, 3], [2, 4, 6])!, 1.0, accuracy: 1e-9)
    }

    func testPearsonPerfectNegative() {
        XCTAssertEqual(SleepCompositeValidator.pearson([1, 2, 3], [6, 4, 2])!, -1.0, accuracy: 1e-9)
    }

    func testPearsonNilWhenNoVariance() {
        XCTAssertNil(SleepCompositeValidator.pearson([5, 5, 5], [1, 2, 3]))
    }

    func testPearsonNilWhenTooFewPoints() {
        XCTAssertNil(SleepCompositeValidator.pearson([1], [2]))
    }

    // MARK: - nextDayISO

    func testNextDayISO() {
        XCTAssertEqual(SleepCompositeValidator.nextDayISO("2026-05-28"), "2026-05-29")
    }

    func testNextDayISOMonthBoundary() {
        XCTAssertEqual(SleepCompositeValidator.nextDayISO("2026-05-31"), "2026-06-01")
    }

    // MARK: - Matured pairing (composite(D) → readiness(D+1))

    func testMaturedPairsExcludeNonMaturedAndPairNextDay() {
        let axisLog = [
            rec("2026-05-01", composite: 80, matured: true),
            rec("2026-05-02", composite: 60, matured: true),
            rec("2026-05-03", composite: 40, matured: false)   // must be excluded
        ]
        let readinessByDate = ["2026-05-02": 3, "2026-05-03": -2, "2026-05-04": 1]

        let (x, y) = SleepCompositeValidator.maturedPairs(axisLog: axisLog, readinessByDate: readinessByDate)
        XCTAssertEqual(x, [80, 60])       // 05-01→readiness(05-02), 05-02→readiness(05-03)
        XCTAssertEqual(y, [3, -2])
    }

    func testMaturedPairsSkipsMissingNextDayReadiness() {
        let axisLog = [rec("2026-05-10", composite: 70, matured: true)]
        // No 05-11 entry → the pair is dropped.
        let (x, y) = SleepCompositeValidator.maturedPairs(axisLog: axisLog, readinessByDate: ["2026-05-10": 2])
        XCTAssertTrue(x.isEmpty)
        XCTAssertTrue(y.isEmpty)
    }

    // MARK: - Per-axis diagnosis

    func testMaturedAxisPairsSelectsAxisScore() {
        let axisLog = [
            rec("2026-05-01", composite: 80, matured: true, axisScores: [.duration: 90]),
            rec("2026-05-02", composite: 60, matured: true, axisScores: [.duration: 50])
        ]
        let readinessByDate = ["2026-05-02": 4, "2026-05-03": -1]
        let (x, y) = SleepCompositeValidator.maturedAxisPairs(
            axis: .duration, axisLog: axisLog, readinessByDate: readinessByDate)
        XCTAssertEqual(x, [90, 50])
        XCTAssertEqual(y, [4, -1])
    }

    // MARK: - Report

    func testBuildReportCountsMaturedPairs() {
        let axisLog = [
            rec("2026-05-01", composite: 80, matured: true),
            rec("2026-05-02", composite: 60, matured: true),
            rec("2026-05-03", composite: 90, matured: false)
        ]
        let readinessByDate = ["2026-05-02": 3, "2026-05-03": -2]
        let report = SleepCompositeValidator.buildReport(axisLog: axisLog, readinessByDate: readinessByDate)
        XCTAssertEqual(report.n, 2)
        XCTAssertNotNil(report.rawR)
    }

    // MARK: - Off-by-one audit: pairs composite(D) with readiness(D+1), never readiness(D)

    func testPairingUsesNextDayNotSameDay() {
        // Same-day and next-day readiness deliberately differ. A correct pair takes D+1.
        let axisLog = [rec("2026-05-01", composite: 80, matured: true)]
        let readinessByDate = ["2026-05-01": 99, "2026-05-02": 7]   // 99 = same-day trap
        let (x, y) = SleepCompositeValidator.maturedPairs(axisLog: axisLog, readinessByDate: readinessByDate)
        XCTAssertEqual(x, [80])
        XCTAssertEqual(y, [7], "Must use readiness(D+1)=7, not readiness(D)=99")
    }

    func testNoEndpointReuseAcrossContiguousDays() {
        // 3 contiguous matured days, all readiness present. Expect exactly D→D+1 with no
        // composite reused and no readiness reused: (d1→r2, d2→r3, d3→r4).
        let axisLog = [
            rec("2026-05-01", composite: 10, matured: true),
            rec("2026-05-02", composite: 20, matured: true),
            rec("2026-05-03", composite: 30, matured: true)
        ]
        let readinessByDate = ["2026-05-02": 2, "2026-05-03": 3, "2026-05-04": 4]
        let (x, y) = SleepCompositeValidator.maturedPairs(axisLog: axisLog, readinessByDate: readinessByDate)
        XCTAssertEqual(x, [10, 20, 30])
        XCTAssertEqual(y, [2, 3, 4])
        XCTAssertEqual(Set(x).count, x.count, "No composite reused")
        XCTAssertEqual(Set(y).count, y.count, "No readiness reused")
    }

    func testMaturedPairDatesMatchesN() {
        let axisLog = [
            rec("2026-05-01", composite: 80, matured: true),
            rec("2026-05-02", composite: 60, matured: true),
            rec("2026-05-03", composite: 40, matured: false)
        ]
        let readinessByDate = ["2026-05-02": 3, "2026-05-03": -2, "2026-05-04": 1]
        let dates = SleepCompositeValidator.maturedPairDates(axisLog: axisLog, readinessByDate: readinessByDate)
        XCTAssertEqual(dates.map { $0.d }, ["2026-05-01", "2026-05-02"])
        XCTAssertEqual(dates.map { $0.next }, ["2026-05-02", "2026-05-03"])
        // n from maturedPairs must equal the audit list length.
        let (x, _) = SleepCompositeValidator.maturedPairs(axisLog: axisLog, readinessByDate: readinessByDate)
        XCTAssertEqual(x.count, dates.count)
    }

    func testExcludeNextDayDropsProvisionalTodayPair() {
        let axisLog = [
            rec("2026-05-27", composite: 70, matured: true),
            rec("2026-05-28", composite: 80, matured: true)
        ]
        let readinessByDate = ["2026-05-28": 3, "2026-05-29": 5]   // 05-29 = in-progress "today"
        let full = SleepCompositeValidator.buildReport(axisLog: axisLog, readinessByDate: readinessByDate)
        XCTAssertEqual(full.n, 2)
        // Excluding today drops ONLY the 05-28→05-29 pair (self-healing tomorrow).
        let guarded = SleepCompositeValidator.buildReport(
            axisLog: axisLog, readinessByDate: readinessByDate, excludeNextDayISO: "2026-05-29")
        XCTAssertEqual(guarded.n, 1)
    }

    // MARK: - Partial correlation

    func testPartialUndefinedWhenControlIsCollinear() {
        // rXZ = 1 ⇒ denom 0 ⇒ partial undefined (nil), not a bogus number.
        XCTAssertNil(SleepCompositeValidator.partial(rXY: 0.6, rXZ: 1.0, rYZ: 0.6))
    }

    func testPartialZeroWhenCorrelationFullyMediatedByControl() {
        // rXY == rXZ·rYZ ⇒ the X–Y correlation is entirely explained by the control ⇒
        // partial 0. This is exactly the confound: composite↔readiness carried only by load.
        let r = SleepCompositeValidator.partial(rXY: 0.49, rXZ: 0.7, rYZ: 0.7)!
        XCTAssertEqual(r, 0, accuracy: 1e-9)
    }

    func testPartialPreservesDirectCorrelation() {
        // No mediation (control correlates with neither) ⇒ partial == raw.
        XCTAssertEqual(SleepCompositeValidator.partial(rXY: -0.40, rXZ: 0, rYZ: 0)!, -0.40, accuracy: 1e-9)
    }

    func testPartialShrinksSpuriousNegative() {
        // A negative raw r that's partly load-driven shrinks toward 0 once load is controlled.
        // rXY=-0.32, load correlates + with composite, − with readiness (the stated confound).
        let raw = -0.32
        let partial = SleepCompositeValidator.partial(rXY: raw, rXZ: 0.5, rYZ: -0.5)!
        XCTAssertGreaterThan(partial, raw, "Controlling load moves a load-driven negative toward 0")
        XCTAssertLessThan(partial, 0, "But doesn't necessarily flip it")
    }

    func testMaturedTriplesAligns() {
        let axisLog = [
            rec("2026-05-01", composite: 80, matured: true),
            rec("2026-05-02", composite: 60, matured: true)
        ]
        let readinessByDate = ["2026-05-02": 3, "2026-05-03": -2]
        let loadByDate = ["2026-05-01": 100.0, "2026-05-02": 40.0]
        let (x, y, z) = SleepCompositeValidator.maturedTriples(
            axisLog: axisLog, readinessByDate: readinessByDate, controlByDate: loadByDate)
        XCTAssertEqual(x, [80, 60])
        XCTAssertEqual(y, [3, -2])
        XCTAssertEqual(z, [100, 40], "Control is load(D), keyed by the composite day")
    }
}
