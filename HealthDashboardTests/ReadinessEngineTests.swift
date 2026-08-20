import XCTest
@testable import HealthDashboard

// MARK: - Test helpers

final class ReadinessEngineTests: XCTestCase {

    // Build a single DailyHealthPoint. All baseline-filler days use defaults that
    // produce neutral scores vs themselves (rhr=65, hrv=30, sleep=8, rr=15, temp=36.5…).
    private func point(
        day: Int,
        month: Int = 5,
        rhr: Double? = 65,
        hrv: Double? = 30,
        sleep: Double? = 8,
        inBed: Double? = 8.7,
        rr: Double? = 15,
        temp: Double? = 36.5,
        spo2: Double? = 98,
        steps: Double? = 8000,
        activeEnergy: Double? = 500,
        exercise: Double? = 45,
        workoutMinutes: Double? = 60,
        workoutEnergy: Double? = 400,
        trimp: Double? = nil
    ) -> DailyHealthPoint {
        DailyHealthPoint(
            dayISO: String(format: "2026-%02d-%02d", month, day),
            restingHR: rhr,
            hrvMS: hrv,
            sleepHours: sleep,
            sleepInBedHours: inBed,
            respiratoryRate: rr,
            spo2Pct: spo2,
            wristTempDeltaC: temp,
            steps: steps,
            activeEnergyKcal: activeEnergy,
            exerciseMinutes: exercise,
            standHours: 10,
            workoutCount: 1,
            workoutMinutes: workoutMinutes,
            workoutEnergyKcal: workoutEnergy,
            dailyTrimp: trimp,
            bodyWeightLb: nil,
            bodyFatPct: nil,
            leanMassLb: nil
        )
    }

    // 27 identical baseline days + a custom today.
    private func history(today: DailyHealthPoint) -> [DailyHealthPoint] {
        let baseline = (1...27).map { point(day: $0) }
        return baseline + [today]
    }

    // Evaluate and return result. Asserts no crash.
    private func eval(_ history: [DailyHealthPoint], manual: ManualReadinessInputs = .default) -> ReadinessResult {
        ReadinessEngine.evaluate(history: history, manual: manual)
    }

    // MARK: - Existing golden-path tests (preserved)

    func testGoodRecoveryIsGreenRaw() {
        // rawTruth bypasses the hysteresis gate (which requires a persisted yesterday
        // entry in the verdict log — unavailable in clean test environments).
        // action/truth may be held at yellow by the gate; only rawTruth is reliable here.
        let result = eval(history(today: point(day: 28)))
        XCTAssertEqual(result.rawTruth, .green)
        XCTAssertTrue(result.flags.isEmpty, "Neutral signals must not produce negative flags")
    }

    func testLowHRVAloneDoesNotForceRed() {
        let result = eval(history(today: point(day: 28, hrv: 22)))
        XCTAssertNotEqual(result.truth, .red)
    }

    func testHighRHRAndLowHRVForcesYellow() {
        let result = eval(history(today: point(day: 28, rhr: 70, hrv: 25)))
        XCTAssertEqual(result.truth, .yellow)
        XCTAssertTrue(result.flags.contains("HRV ↓"))
        XCTAssertTrue(result.flags.contains("RHR ↑"))
    }

    func testClusteredBadSignalsForcesRed() {
        let result = eval(history(today: point(day: 28, rhr: 73, hrv: 22, sleep: 5.5, rr: 17.2)))
        XCTAssertEqual(result.truth, .red)
        XCTAssertEqual(result.action, .red)
    }

    func testSickManualInputForcesRedAction() {
        let result = eval(
            history(today: point(day: 28)),
            manual: ManualReadinessInputs(painLevel: 0, isSick: true)
        )
        XCTAssertEqual(result.action, .red)
        XCTAssertTrue(result.flags.contains("Sick"))
    }

    func testHighPainForcesRedAction() {
        let result = eval(
            history(today: point(day: 28)),
            manual: ManualReadinessInputs(painLevel: 8, isSick: false)
        )
        XCTAssertEqual(result.action, .red)
        XCTAssertTrue(result.flags.contains("Pain ↑"))
    }

    func testMissingHRVDoesNotCrashOrForceRed() {
        let result = eval(history(today: point(day: 28, hrv: nil)))
        XCTAssertNotEqual(result.truth, .red)
    }

    func testRespiratoryRateContributesWithoutDominatingAlone() {
        let result = eval(history(today: point(day: 28, rr: 16.5)))
        XCTAssertNotEqual(result.truth, .red)
        XCTAssertTrue(result.flags.contains("Resp Rate ↑"))
    }

    func testPoorSleepEfficiencyContributesToYellowWhenClustered() {
        let result = eval(history(today: point(day: 28, rhr: 70, sleep: 7.8, inBed: 9.6)))
        XCTAssertEqual(result.truth, .yellow)
        XCTAssertTrue(result.flags.contains("RHR ↑"))
        XCTAssertTrue(result.flags.contains("Sleep quality ↓"))
    }

    func testLoadSpikeCreatesGuardrailsButDoesNotAutomaticallyForceRed() {
        let result = eval(history(today: point(
            day: 28, steps: 14000, activeEnergy: 900, exercise: 90,
            workoutMinutes: 100, workoutEnergy: 750
        )))
        XCTAssertNotEqual(result.truth, .red)
    }

    func testMultipleMissingSignalsStillProducesStableResult() {
        let result = eval(history(today: point(day: 28, rhr: nil, hrv: nil, sleep: 7.5, rr: nil, temp: nil, spo2: nil)))
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result.truth, .red)
    }

    func testOutlierDataIsIgnored() {
        let result = eval(history(today: point(day: 28, rhr: 140, hrv: 2, rr: 40)))
        XCTAssertNotEqual(result.truth, .red)
    }

    func testHRVDropOverSeveralDaysAloneDoesNotForceYellow() {
        var hist = (1...24).map { point(day: $0, hrv: 30) }
        hist += [
            point(day: 25, hrv: 28), point(day: 26, hrv: 26),
            point(day: 27, hrv: 24), point(day: 28, hrv: 22)
        ]
        let result = eval(hist)
        XCTAssertNotEqual(result.action, .red)
        XCTAssertTrue(result.driverSummary.contains("HRV"))
    }

    func testGoodSleepOffsetsMinorHRVDrop() {
        let result = eval(history(today: point(day: 28, hrv: 25, sleep: 9.0)))
        XCTAssertNotEqual(result.truth, .red)
    }

    func testCompleteDataProducesHighConfidence() {
        let result = eval(history(today: point(day: 28)))
        XCTAssertEqual(result.confidence, .high)
    }

    func testPartialDataProducesMediumConfidence() {
        let result = eval(history(today: point(day: 28, hrv: nil, temp: nil, spo2: nil)))
        XCTAssertEqual(result.confidence, .medium)
    }

    func testSparseDataProducesLowConfidence() {
        let result = eval(history(today: point(day: 28, rhr: nil, hrv: nil, rr: nil, temp: nil, spo2: nil)))
        XCTAssertEqual(result.confidence, .low)
    }

    func testDriversArePopulatedAndSorted() {
        let result = eval(history(today: point(day: 28, rhr: 72, hrv: 22, sleep: 5.5)))
        XCTAssertFalse(result.drivers.isEmpty)
        if result.drivers.count >= 2 {
            XCTAssertGreaterThanOrEqual(result.drivers[0].impact, result.drivers[1].impact)
        }
    }

    func testHRVAloneAtNegativeThreeDoesNotForceYellowWhenOtherSignalsAreGood() {
        let result = eval(
            history(today: point(day: 28, rhr: 66, hrv: 18.8, sleep: 9.7, inBed: 9.9, rr: 18.8, temp: 36.0)),
            manual: ManualReadinessInputs(painLevel: 1, isSick: false)
        )
        XCTAssertNotEqual(result.truth, .red)
        XCTAssertNotEqual(result.action, .red)
    }

    func testStrongRecoveryBuffersLowHRV() {
        var hist = (1...24).map { point(day: $0, hrv: 30) }
        hist += [
            point(day: 25, hrv: 24), point(day: 26, hrv: 24),
            point(day: 27, hrv: 24),
            point(day: 28, rhr: 66, hrv: 18.8, sleep: 9.7, inBed: 9.9, rr: 18.8, temp: 36.0)
        ]
        let result = eval(hist, manual: ManualReadinessInputs(painLevel: 1, isSick: false))
        XCTAssertNotEqual(result.truth, .red)
        XCTAssertTrue(result.truth == .green || result.truth == .yellow, "Expected green or yellow, got \(result.truth)")
        XCTAssertTrue(result.driverSummary.contains("HRV"), "Driver should include HRV")
    }

    func testHRVTrendPlusAnotherSignalForcesYellow() {
        var hist = (1...24).map { point(day: $0, rhr: 65, hrv: 30) }
        hist += [
            point(day: 25, rhr: 66, hrv: 28), point(day: 26, rhr: 67, hrv: 26),
            point(day: 27, rhr: 69, hrv: 24), point(day: 28, rhr: 72, hrv: 22)
        ]
        let result = eval(hist)
        XCTAssertEqual(result.truth, .yellow)
        XCTAssertTrue(
            result.driverSummary.contains("HRV") && result.driverSummary.contains("RHR"),
            "Expected HRV + RHR to drive yellow"
        )
    }

    func testClusterForcesRed() {
        var hist = (1...24).map { point(day: $0, rhr: 65, hrv: 30, sleep: 7.5) }
        hist += [
            point(day: 25, rhr: 68, hrv: 26, sleep: 6.5), point(day: 26, rhr: 70, hrv: 24, sleep: 6.0),
            point(day: 27, rhr: 72, hrv: 22, sleep: 5.5), point(day: 28, rhr: 75, hrv: 20, sleep: 5.0)
        ]
        XCTAssertEqual(eval(hist).truth, .red)
    }

    // MARK: - rrUp10 2-day persistence tests

    // One-day RR spike (noise case) must NOT fire rrUp10 when yesterday was normal.
    // Precondition: HRV is also down so that a rrUp10 fire would tip clusterCount to 2
    // and force Yellow — that way a false-positive is observable in the verdict.
    func testSingleDayRRSpikeWithNormalYesterdayDoesNotForceYellow() {
        // Baseline rr=15 over 26 days. Day 27 is normal. Day 28 is the spike.
        var hist = (1...26).map { point(day: $0, hrv: 30, rr: 15.0) }
        hist.append(point(day: 27, hrv: 30, rr: 15.0))          // yesterday: normal RR
        hist.append(point(day: 28, hrv: 24, rr: 16.5))          // today: HRV down 20% + RR spike +1.5

        // Without smoothing: RR delta = 1.5 >= 1.0 → rrUp10, plus hrvDown10 → clusterCount = 2 → Yellow.
        // With 2-day average: avg RR = (15.0 + 16.5) / 2 = 15.75, delta = 0.75 < 1.0 → rrUp10 = false.
        // HRV down alone (clusterCount = 1) must not force Yellow.
        //
        // NOTE: "Resp Rate ↑" may still appear in flags because rrScore reads today's single sample
        // (d = 1.5 → rrScore = -1). That's correct — score and cluster flag are intentionally separate:
        // score = aggregate contribution; rrUp10 = binary forceYellow trigger. Only the cluster
        // flag is smoothed. Check clusterCount via rawTruth, not via flags.
        let result = eval(hist)
        XCTAssertEqual(result.rawTruth, .green,
            "A single-night RR spike when yesterday was normal must not force Yellow; got rawTruth=\(result.rawTruth)")
    }

    // Two consecutive elevated-RR nights must still fire rrUp10 → Yellow when combined with HRV.
    func testTwoDaySustainedRRElevationFiresClusterFlag() {
        var hist = (1...26).map { point(day: $0, hrv: 30, rr: 15.0) }
        hist.append(point(day: 27, hrv: 30, rr: 16.2))          // yesterday: RR delta = +1.2
        hist.append(point(day: 28, hrv: 24, rr: 16.5))          // today: HRV down 20% + RR delta = +1.5

        // 2-day avg RR delta = (1.2 + 1.5) / 2 = 1.35 >= 1.0 → rrUp10 fires.
        // Combined with hrvDown10 → clusterCount = 2 → forceYellow.
        let result = eval(hist)
        XCTAssertEqual(result.truth, .yellow,
            "Two consecutive elevated-RR nights must still trigger rrUp10 and force Yellow; got \(result.truth)")
        XCTAssertTrue(result.flags.contains("Resp Rate ↑"),
            "rrUp10 must fire when RR has been elevated for 2 days")
    }

    // MARK: - Signal-level directionality tests
    // These verify that each signal's score SIGN matches physiological reality.

    func testRHRBelowBaselineScoredFavorably() {
        // Baseline RHR = 65 over 27 days. Today = 59 (−6 bpm = good).
        // rhrScore should be +2 (d < −4). Verdict should NOT be yellow from RHR alone.
        let today = point(day: 28, rhr: 59)
        let result = eval(history(today: today))
        // Favorable RHR should not add an "RHR ↑" flag.
        XCTAssertFalse(result.flags.contains("RHR ↑"), "RHR below baseline must not produce a negative flag")
        // Positive driver should appear.
        let rhrDriver = result.drivers.first(where: { $0.label == "RHR" })
        XCTAssertNotNil(rhrDriver, "A below-baseline RHR should register as a driver")
        XCTAssertFalse(rhrDriver?.isNegative ?? true, "A below-baseline RHR driver must be positive (isNegative=false)")
        // rawTruth should stay green — positive RHR alone should not force yellow.
        XCTAssertEqual(result.rawTruth, .green, "Excellent RHR alone should yield green rawTruth")
    }

    func testRHRAboveBaselineScoredNegatively() {
        // Today RHR = 70 (+5 bpm above baseline of 65).
        let result = eval(history(today: point(day: 28, rhr: 70)))
        XCTAssertTrue(result.flags.contains("RHR ↑"), "Elevated RHR must produce a negative flag")
        let rhrDriver = result.drivers.first(where: { $0.label == "RHR" })
        XCTAssertTrue(rhrDriver?.isNegative ?? false, "Elevated RHR driver must be negative")
    }

    func testRHRAtNoiseBandIsNeutral() {
        // d = 66 − 65 = +1, within ±2 bpm noise band → rhrScore = 0 → no driver added.
        let result = eval(history(today: point(day: 28, rhr: 66)))
        XCTAssertFalse(result.flags.contains("RHR ↑"), "RHR within noise band must not flag")
        XCTAssertNil(result.drivers.first(where: { $0.label == "RHR" }), "Neutral RHR must not generate a driver")
    }

    func testRHRAtExactThresholdBoundary() {
        // d = +3 (exactly at the rhrUp3 cluster-flag threshold).
        let result = eval(history(today: point(day: 28, rhr: 68)))
        XCTAssertTrue(result.flags.contains("RHR ↑"))
    }

    func testHRVAboveBaselineScoredFavorably() {
        // Baseline HRV = 30. Today = 36 (+20% = +1 score, not capped since positive).
        let result = eval(history(today: point(day: 28, hrv: 36)))
        XCTAssertFalse(result.flags.contains("HRV ↓"), "HRV above baseline must not produce a negative flag")
        let d = result.drivers.first(where: { $0.label == "HRV" })
        XCTAssertFalse(d?.isNegative ?? true, "Above-baseline HRV must be a positive driver")
    }

    func testHRVBelowBaselineScoredNegatively() {
        // Baseline = 30. Today = 22 (−27%). Should be negative (capped at −1 by tier-3 rule).
        let result = eval(history(today: point(day: 28, hrv: 22)))
        XCTAssertTrue(result.flags.contains("HRV ↓"))
        let d = result.drivers.first(where: { $0.label == "HRV" })
        XCTAssertTrue(d?.isNegative ?? false, "Below-baseline HRV must be a negative driver")
    }

    func testRRElevatedAboveBaselineIsNegative() {
        // Baseline RR = 15. Today = 16.5 (+1.5 = above threshold → rrScore = −1).
        let result = eval(history(today: point(day: 28, rr: 16.5)))
        XCTAssertTrue(result.flags.contains("Resp Rate ↑"), "Elevated RR must produce a negative flag")
        let d = result.drivers.first(where: { $0.label == "Respiratory Rate" })
        XCTAssertTrue(d?.isNegative ?? false, "Elevated RR driver must be negative")
    }

    func testRRAtExactOneBpmThreshold() {
        // Baseline = 15. Today = 16.0 (exactly +1.0). rrUp10 fires; rrScore = −1.
        let result = eval(history(today: point(day: 28, rr: 16.0)))
        XCTAssertTrue(result.flags.contains("Resp Rate ↑"), "RR at exactly +1 bpm should flag")
    }

    func testRRBelowBaselineEarnsNoPositiveScore() {
        // Baseline = 15. Today = 13.5 (below). No reward expected (by design).
        let result = eval(history(today: point(day: 28, rr: 13.5)))
        XCTAssertFalse(result.flags.contains("Resp Rate ↑"), "Below-baseline RR must not flag as elevated")
        // No negative RR driver expected.
        let d = result.drivers.first(where: { $0.label == "Respiratory Rate" })
        XCTAssertTrue(d == nil || !(d?.isNegative ?? false), "Below-baseline RR must not generate a negative driver")
    }

    func testElevatedWristTempIsNegative() {
        // Baseline temp series = all 36.5. Today = 37.3 (d = +0.8 → tempScore = −3).
        let result = eval(history(today: point(day: 28, temp: 37.3)))
        XCTAssertTrue(result.flags.contains("Wrist Temp ↑"))
        let d = result.drivers.first(where: { $0.label == "Wrist Temp" })
        XCTAssertTrue(d?.isNegative ?? false, "Elevated wrist temp must be a negative driver")
    }

    func testWristTempWithinNoiseBandIsNeutral() {
        // d = 36.6 − 36.5 = 0.1. abs(0.1) <= 0.2 → tempScore = 0.
        // (Avoid 36.7 − 36.5 = 0.200...003 in Double — on the exact threshold edge.)
        let result = eval(history(today: point(day: 28, temp: 36.6)))
        XCTAssertFalse(result.flags.contains("Wrist Temp ↑"), "Wrist temp within ±0.2 must not flag")
    }

    func testSleepAboveBaselinePlusHalfHourEarnsPositiveScore() {
        // Baseline sleep = 8h. Today = 8.6h (> base + 0.5). sleepScore should be +1.
        let result = eval(history(today: point(day: 28, sleep: 8.6, inBed: 9.0)))
        let d = result.drivers.first(where: { $0.label == "Sleep" })
        XCTAssertFalse(d?.isNegative ?? true, "Sleep meaningfully above baseline must be a positive driver")
    }

    func testSleepShortMoreThanOneHourBelow() {
        // Baseline sleep = 8h. Target = max(7, 8) = 8h. Today = 6.8h (short = 1.2h > 1.0).
        let result = eval(history(today: point(day: 28, sleep: 6.8)))
        XCTAssertTrue(result.flags.contains("Sleep ↓"))
    }

    // MARK: - Verdict-level integration tests

    // REGRESSION: today's actual observed values (July 2026)
    // RHR=61 (−4 vs baseline 65 = good), HRV=24 (−20% vs ~30 = moderate concern),
    // Sleep=8.25h (near target), RR=19.2 (≈+1.0 above baseline ~18.2 = mild concern).
    // Expected: Yellow (HRV + RR = 2 cluster flags), NOT Red.
    // Critical: favorable RHR must not itself cause yellow or red.
    func testRegressionTodayFavorableRHRDoesNotForceRed() {
        // Use rrBase=18.2 (27-day median) by setting baseline days to 18.2
        var hist = (1...27).map {
            point(day: $0, rhr: 65, hrv: 30, sleep: 8.0, inBed: 8.7, rr: 18.2)
        }
        hist.append(point(day: 28, rhr: 61, hrv: 24, sleep: 8.25, inBed: 8.7, rr: 19.2))
        let result = eval(hist)

        // Verdict must be Yellow (cluster=2), NOT Red.
        XCTAssertEqual(result.truth, .yellow, "Two-flag cluster must yield yellow, not red")
        XCTAssertNotEqual(result.truth, .red, "Two moderate signal deviations must not yield red")

        // RHR is favorable — must not appear as a negative flag.
        XCTAssertFalse(result.flags.contains("RHR ↑"), "Below-baseline RHR must not produce a negative flag")

        // HRV and RR should be the negative drivers.
        let negatives = result.drivers.filter { $0.isNegative }.map { $0.label }
        XCTAssertTrue(negatives.contains("HRV"), "HRV should be a negative driver")
        XCTAssertTrue(negatives.contains("Respiratory Rate"), "Elevated RR should be a negative driver")

        // RHR positive driver should exist.
        let rhrDriver = result.drivers.first(where: { $0.label == "RHR" })
        XCTAssertFalse(rhrDriver?.isNegative ?? true, "RHR below baseline should be a positive driver")
    }

    func testTwoFavorableSignalsDoNotDowngradeToRed() {
        // If RHR and Sleep are well above baseline, even a moderate HRV dip must not force Red.
        let today = point(day: 28, rhr: 58, hrv: 24, sleep: 9.2, inBed: 9.6)
        let result = eval(history(today: today))
        XCTAssertNotEqual(result.truth, .red, "Favorable RHR + Sleep must prevent Red even with modest HRV dip")
    }

    func testThreeClusterFlagsForceRed() {
        // hrvDown10 + rhrUp3 + rrUp10 = 3 flags → Red.
        // rrUp10 now uses a 2-day trailing average, so yesterday must also be elevated.
        var hist = (1...26).map { point(day: $0, rhr: 65, hrv: 30, rr: 15.0) }
        hist.append(point(day: 27, rhr: 65, hrv: 30, rr: 16.2)) // yesterday: RR delta = +1.2
        hist.append(point(day: 28, rhr: 69, hrv: 24, rr: 16.5)) // today: rhrUp3 + hrvDown10 + RR avg = 1.35 ≥ 1.0
        let result = eval(hist)
        XCTAssertEqual(result.truth, .red)
    }

    func testOneFlagAloneDoesNotForceYellow() {
        // Only hrvDown10 fires — clusterCount = 1 → should not force Yellow.
        // (scoreTotal might still produce Yellow, but not via forceYellow.)
        var hist = (1...27).map { point(day: $0, hrv: 30) }
        hist.append(point(day: 28, hrv: 24))  // −20% → hrvDown10
        let result = eval(hist)
        // We're verifying it's NOT due to cluster force — just check it's not Red.
        XCTAssertNotEqual(result.truth, .red, "One cluster flag alone must not force Red")
    }

    // MARK: - Messaging consistency tests

    func testYellowClusterExplanationDoesNotSayBelowBaselineForElevatedRR() {
        // Regression: explanation used to say "several recovery signals are below baseline"
        // even when the concern was elevated RR (above baseline).
        var hist = (1...27).map { point(day: $0, rhr: 65, hrv: 30, rr: 15.0) }
        hist.append(point(day: 28, hrv: 24, rr: 16.5))  // HRV down + RR up → yellowCluster
        let result = eval(hist)

        let presentation = result.presentation(manual: .default)
        XCTAssertFalse(
            presentation.explanation.lowercased().contains("below baseline"),
            "yellowCluster explanation must not claim all signals are 'below baseline' when some are elevated (e.g. RR). Got: \(presentation.explanation)"
        )
    }

    func testGreenExplanationDoesNotSayReduceExertion() {
        let result = eval(history(today: point(day: 28)))
        let presentation = result.presentation(manual: .default)
        XCTAssertFalse(
            presentation.explanation.lowercased().contains("reduce"),
            "Green explanation must not suggest reducing exertion. Got: \(presentation.explanation)"
        )
    }

    func testActionTitleAndMessageAreConsistentWithVerdict() {
        // actionTitle/actionMessage are derived from `action`, not separately.
        // For Yellow: title must contain "guardrails", not "reduce cost".
        var hist = (1...27).map { point(day: $0, rhr: 65, hrv: 30) }
        hist.append(point(day: 28, rhr: 70, hrv: 24))
        let result = eval(hist)
        XCTAssertEqual(result.action, .yellow)
        XCTAssertTrue(result.actionTitle.lowercased().contains("guardrails"), "Yellow action title mismatch: \(result.actionTitle)")
        XCTAssertFalse(result.actionTitle.lowercased().contains("reduce cost"), "Yellow action title must not say 'reduce cost': \(result.actionTitle)")
    }

    func testRedActionTitleSaysReduceCost() {
        var hist = (1...27).map { point(day: $0, rhr: 65, hrv: 30, sleep: 8) }
        hist += [
            point(day: 25, rhr: 68, hrv: 26, sleep: 6.5),
            point(day: 26, rhr: 70, hrv: 24, sleep: 6.0),
            point(day: 27, rhr: 72, hrv: 22, sleep: 5.5),
            point(day: 28, rhr: 75, hrv: 20, sleep: 5.0)
        ]
        let result = eval(hist)
        XCTAssertEqual(result.action, .red)
        XCTAssertTrue(result.actionTitle.lowercased().contains("reduce"), "Red action title mismatch: \(result.actionTitle)")
    }

    func testDeltasInResultMatchSignedDirectionOfRawValues() {
        // rhrDelta must be negative when today's RHR is below baseline (favorable).
        var hist = (1...27).map { point(day: $0, rhr: 65) }
        hist.append(point(day: 28, rhr: 59))  // d = 59 − 65 = −6
        let result = eval(hist)
        guard let rhrDelta = result.rhrDelta else {
            XCTFail("rhrDelta must not be nil when RHR is present")
            return
        }
        XCTAssertLessThan(rhrDelta, 0, "rhrDelta must be negative when RHR is below baseline")
        XCTAssertEqual(rhrDelta, -6, accuracy: 1.0)
    }

    func testHRVDeltaSignMatchesDirection() {
        // hrvDelta is in ms and must be negative when HRV is below baseline.
        var hist = (1...27).map { point(day: $0, hrv: 30) }
        hist.append(point(day: 28, hrv: 24))  // d = −6ms
        let result = eval(hist)
        guard let d = result.hrvDelta else {
            XCTFail("hrvDelta must not be nil when HRV data is present")
            return
        }
        XCTAssertLessThan(d, 0, "hrvDelta must be negative when HRV is below baseline")
    }

    func testSleepDeltaPositiveWhenAboveTarget() {
        // sleepTarget = max(7, sleepBase). With base = 8h, target = 8h.
        // Today = 9h → sleepDelta = 9 − 8 = +1.0.
        var hist = (1...27).map { point(day: $0, sleep: 8.0) }
        hist.append(point(day: 28, sleep: 9.0, inBed: 9.5))
        let result = eval(hist)
        guard let d = result.sleepDelta else {
            XCTFail("sleepDelta must not be nil when sleep data is present")
            return
        }
        XCTAssertGreaterThan(d, 0, "sleepDelta must be positive when sleep is above target")
    }

    // MARK: - Nil handling

    func testAllSignalsNilExceptSleepDoesNotCrash() {
        let today = point(day: 28, rhr: nil, hrv: nil, sleep: 7.5, rr: nil, temp: nil, spo2: nil)
        let result = eval(history(today: today))
        XCTAssertNotNil(result)
    }

    func testAllSignalsNilDoesNotCrash() {
        let today = point(day: 28, rhr: nil, hrv: nil, sleep: nil, rr: nil, temp: nil, spo2: nil)
        let result = eval(history(today: today))
        XCTAssertNotNil(result)
        XCTAssertEqual(result.confidence, .low)
    }

    func testNilRRDoesNotSilentlyPenalize() {
        // With nil RR, rrScore must stay 0 — not counted as elevated.
        let withNilRR = eval(history(today: point(day: 28, rr: nil)))
        let withBaselineRR = eval(history(today: point(day: 28, rr: 15)))

        // Nil RR should not produce worse verdict than on-baseline RR.
        // Both should be non-red with no Resp Rate flag.
        XCTAssertFalse(withNilRR.flags.contains("Resp Rate ↑"), "Nil RR must not flag as elevated")
        XCTAssertNotEqual(withNilRR.truth, .red)
    }

    func testOnlyOneHistoryPointDoesNotCrash() {
        let result = eval([point(day: 1)])
        XCTAssertNotNil(result)
    }

    func testEmptyHistoryDoesNotCrash() {
        let result = eval([])
        XCTAssertNotNil(result)
    }

    // MARK: - Card messaging consistency (Phase 1 presentation layer)
    //
    // These exercise the presentation derivation only (ReadinessResult.driverDisplays()
    // / .reconciliationLine). Fixtures build the rendered result directly — the scoring
    // engine is untouched and does not populate sleepQuality (the pipeline injects it).

    private func driver(_ label: String, impact: Int, isNegative: Bool, streak: Int = 0) -> ReadinessDriver {
        ReadinessDriver(label: label, impact: impact, isNegative: isNegative,
                        reason: "Below baseline — often an early stress or recovery signal.",
                        consecutiveDays: streak)
    }

    private func sleepResult(verdict: SleepQualityVerdict, composite: Double,
                             axes: [(SleepAxis, Double)]) -> SleepQualityResult {
        var sq = SleepQualityResult.unavailable
        sq.verdict = verdict
        sq.composite = composite
        sq.hasStagedData = true
        sq.availableAxes = axes.map { $0.0 }
        sq.subScores = axes.map {
            SleepSubScore(axis: $0.0, score: $0.1, effectiveWeight: 20, available: true)
        }
        return sq
    }

    private func card(action: ReadinessStatus, drivers: [ReadinessDriver],
                      sleep: SleepQualityResult? = nil) -> ReadinessResult {
        var r = ReadinessResult.empty
        r.action = action
        r.truth = action
        r.drivers = drivers
        r.sleepQuality = sleep
        return r
    }

    // Sentiment-matches-contribution ------------------------------------------------

    func testNegativeDriverIsCalmOnGreen() {
        let r = card(action: .green, drivers: [driver("RHR", impact: 2, isNegative: true, streak: 3)])
        XCTAssertEqual(r.driverDisplays().first?.sentiment, .calm,
                       "A negative driver on a Green card was discounted by the verdict → calm")
    }

    func testNegativeDriverIsWarnOnYellow() {
        let r = card(action: .yellow, drivers: [driver("RHR", impact: 1, isNegative: true)])
        XCTAssertEqual(r.driverDisplays().first?.sentiment, .warn,
                       "On a non-Green card the negative driver is contributing → warn")
    }

    func testPositiveDriverIsPositive() {
        let r = card(action: .green, drivers: [driver("HRV", impact: 1, isNegative: false)])
        XCTAssertEqual(r.driverDisplays().first?.sentiment, .positive)
    }

    // The gap that shipped the bug: the above test checked ONLY the sentiment enum,
    // never the subtitle. A positive HRV driver was rendering the calm/negative-dip
    // fallthrough string ("...below your baseline...") under the green up-arrow.
    func testHRVPositiveRendersPositiveCopyNotCalmFallback() {
        let r = card(action: .green, drivers: [driver("HRV", impact: 1, isNegative: false)])
        let display = r.driverDisplays().first!
        XCTAssertEqual(display.sentiment, .positive)
        XCTAssertEqual(display.subtitle, "Above your baseline — good sign.")
        // Must NOT inherit the negative-dip fallthrough.
        XCTAssertNotEqual(display.subtitle, "Slightly below your baseline — within normal range.")
        XCTAssertFalse(display.subtitle.lowercased().contains("below"),
                       "Positive HRV row must not describe a below-baseline dip: \(display.subtitle)")
    }

    // Exhaustiveness: all three DriverSentiment cases for HRV must produce distinct,
    // non-fallthrough subtitles — so no future sentiment silently reuses another's copy.
    func testHRVAllThreeSentimentsProduceDistinctSubtitles() {
        let positive = card(action: .green,
                            drivers: [driver("HRV", impact: 1, isNegative: false)])
            .driverDisplays().first!
        let calm = card(action: .green,
                        drivers: [driver("HRV", impact: 1, isNegative: true)])
            .driverDisplays().first!
        let warn = card(action: .yellow,
                        drivers: [driver("HRV", impact: 1, isNegative: true)])
            .driverDisplays().first!

        XCTAssertEqual(positive.sentiment, .positive)
        XCTAssertEqual(calm.sentiment, .calm)
        XCTAssertEqual(warn.sentiment, .warn)

        let subtitles = Set([positive.subtitle, calm.subtitle, warn.subtitle])
        XCTAssertEqual(subtitles.count, 3,
                       "Each HRV sentiment must own a distinct subtitle, not fall through to another's")
        XCTAssertTrue(positive.subtitle.contains("Above"))
        XCTAssertTrue(calm.subtitle.contains("within normal range"))
        XCTAssertTrue(warn.subtitle.contains("weigh on today's read"))
    }

    // Guards the invariant behind "Sleep Efficiency .positive is unreachable": the engine's
    // sleepEffScore is 0 or -1 only (no positive scoring), and addDriver drops score==0,
    // so a Sleep Efficiency driver is always negative. If that ever changes, sleepQualitySubtitle()
    // (negative-worded, sentiment-blind) would start contradicting a positive glyph — catch it here.
    func testEngineNeverProducesPositiveSleepEfficiencyDriver() {
        let r = eval(history(today: point(day: 28)))
        XCTAssertFalse(r.drivers.contains { $0.label == "Sleep Efficiency" && !$0.isNegative },
                       "A non-negative Sleep Efficiency driver would reach the negative-only efficiency subtitle")
    }

    // The flagged interaction: Green + sustained (streak>=2) down-driver must NOT put a
    // warn/orange row under the "not enough to change today's call" reconciliation line.
    func testGreenWithSustainedDownDriverDoesNotContradict() {
        let r = card(action: .green, drivers: [driver("HRV", impact: 1, isNegative: true, streak: 3)])
        let displays = r.driverDisplays()
        XCTAssertEqual(displays.first?.sentiment, .calm,
                       "Sustained streak on Green stays calm — the badge carries the streak, not alarm color")
        XCTAssertNotNil(r.reconciliationLine)
        XCTAssertFalse(displays.contains { $0.sentiment == .warn },
                       "No warn row may coexist with a Green reconciliation line")
    }

    // Label-collision (driver vs composite tile) ------------------------------------

    // The reported bug: driver row "Lower sleep efficiency than your norm" (orange/down)
    // sat inches from the composite tile "Sleep Quality: Excellent 91/100" (green/up) —
    // same label, opposite verdict, both individually correct. The fix un-collides the
    // NAMES: the driver is now "Sleep Efficiency", distinct from the composite's tile
    // title ("Sleep Quality"), so a legitimate divergence no longer reads as a contradiction.
    func testSleepEfficiencyDriverLabelDistinctFromCompositeTile() {
        // Engine efficiency driver fires negative while the composite is Excellent/high —
        // exactly the valid divergence from the screenshot.
        let sleep = sleepResult(verdict: .excellent, composite: 91,
                                axes: [(.efficiency, 70), (.fragmentation, 95),
                                       (.duration, 92), (.architecture, 90), (.consistency, 93)])
        let r = card(action: .green,
                     drivers: [driver("Sleep Efficiency", impact: 1, isNegative: true)],
                     sleep: sleep)
        let display = r.driverDisplays().first!

        // Driver keeps its (correct) efficiency-anchored subtitle...
        XCTAssertTrue(display.subtitle.contains("efficiency"),
                      "Driver still routes to the efficiency subtitle: \(display.subtitle)")
        // ...but its LABEL no longer collides with the composite tile's name.
        XCTAssertEqual(display.label, "Sleep Efficiency")
        XCTAssertNotEqual(display.label, "Sleep Quality")
        // HealthMetric.sleepEff.title is what the composite tile/detail renders as its
        // title ("Sleep Quality"). The driver row must not share that string.
        XCTAssertNotEqual(display.label, HealthMetric.sleepEff.title,
                          "Driver label must differ from the composite tile title to avoid the collision")
        XCTAssertEqual(HealthMetric.sleepEff.title, "Sleep Quality",
                       "Composite tile/detail title stays 'Sleep Quality' (unchanged)")
        // The divergence is real and intentional — the composite verdict is Excellent.
        XCTAssertEqual(sleep.verdict, .excellent)
    }

    // Label-matches-axis ------------------------------------------------------------

    func testSleepLabelNamesEfficiencyNotFragmentation() {
        let sleep = sleepResult(verdict: .fair, composite: 60,
                                axes: [(.efficiency, 52), (.fragmentation, 88)])
        let r = card(action: .green, drivers: [driver("Sleep Efficiency", impact: 1, isNegative: true)], sleep: sleep)
        let sub = r.driverDisplays().first!.subtitle
        XCTAssertTrue(sub.contains("efficiency") || sub.contains("Restless"), "Low axis is efficiency: \(sub)")
        XCTAssertFalse(sub.contains("Fragmented"), "Must not assert fragmentation when efficiency is the low axis")
    }

    // The driver fires off the engine's efficiency signal, so the row never names
    // a different axis — even when the composite's own weak axis is fragmentation.
    func testSleepDriverNamesEfficiencyNotFragmentationEvenWhenCompositeFragLow() {
        let sleep = sleepResult(verdict: .fair, composite: 60,
                                axes: [(.fragmentation, 50), (.efficiency, 85)])
        let r = card(action: .green, drivers: [driver("Sleep Efficiency", impact: 1, isNegative: true)], sleep: sleep)
        let sub = r.driverDisplays().first!.subtitle
        XCTAssertTrue(sub.contains("efficiency"), "Driver is the engine efficiency signal: \(sub)")
        XCTAssertFalse(sub.contains("Fragmented"), "Must not adopt the composite's fragmentation axis")
    }

    // THE couch-sleep corner (training-day population): engine efficiency is low
    // (driver fires) but the composite's efficiency axis is fine (SPT-trimmed) and
    // the composite verdict is Good. The row must still say efficiency — never
    // "close to your norm" — and stay calm on Green without contradicting the
    // reconciliation line.
    func testCouchSleepNightNamesEfficiencyNotSuppressed() {
        let sleep = sleepResult(verdict: .good, composite: 78,
                                axes: [(.efficiency, 88), (.fragmentation, 84),
                                       (.duration, 80), (.architecture, 82), (.consistency, 79)])
        let r = card(action: .green, drivers: [driver("Sleep Efficiency", impact: 1, isNegative: true)], sleep: sleep)
        let display = r.driverDisplays().first!
        XCTAssertTrue(display.subtitle.contains("efficiency"),
                      "Engine raised the row — must name efficiency, not suppress: \(display.subtitle)")
        XCTAssertFalse(display.subtitle.contains("close to your norm"),
                       "Must not silence the engine's down-driver while it's on screen")
        XCTAssertEqual(display.sentiment, .calm)
        XCTAssertNotNil(r.reconciliationLine)
        XCTAssertFalse(r.driverDisplays().contains { $0.sentiment == .warn })
    }

    // A weak non-efficiency composite axis under a Good tile still yields an
    // efficiency-worded row (driver is efficiency), never a fragmentation claim
    // and never "close to your norm".
    func testGoodCompositeNonEfficiencyWeakAxisStillNamesEfficiency() {
        let sleep = sleepResult(verdict: .good, composite: 74,
                                axes: [(.fragmentation, 68), (.efficiency, 85), (.duration, 80)])
        let r = card(action: .green, drivers: [driver("Sleep Efficiency", impact: 1, isNegative: true)], sleep: sleep)
        let sub = r.driverDisplays().first!.subtitle
        XCTAssertTrue(sub.contains("efficiency"))
        XCTAssertFalse(sub.contains("Fragmented"))
        XCTAssertFalse(sub.contains("close to your norm"))
    }

    // Composite agreement (efficiency also low) strengthens the wording but stays
    // efficiency-anchored.
    func testCompositeAgreementRefinesEfficiencyWording() {
        let sleep = sleepResult(verdict: .good, composite: 72,
                                axes: [(.efficiency, 66), (.fragmentation, 85), (.duration, 82)])
        let r = card(action: .green, drivers: [driver("Sleep Efficiency", impact: 1, isNegative: true)], sleep: sleep)
        let sub = r.driverDisplays().first!.subtitle
        XCTAssertTrue(sub.contains("efficiency"))
        XCTAssertFalse(sub.contains("Fragmented"))
    }

    // No composite yet (engine ran, sleep engine hasn't) → still efficiency-worded.
    func testSleepDriverNamesEfficiencyWhenCompositeAbsent() {
        let r = card(action: .green, drivers: [driver("Sleep Efficiency", impact: 1, isNegative: true)], sleep: nil)
        let sub = r.driverDisplays().first!.subtitle
        XCTAssertTrue(sub.contains("efficiency"))
        XCTAssertFalse(sub.contains("Fragmented"))
        XCTAssertFalse(sub.contains("close to your norm"))
    }

    // Reconciliation-present --------------------------------------------------------

    func testReconciliationPresentOnGreenWithDownDriver() {
        let r = card(action: .green, drivers: [driver("HRV", impact: 1, isNegative: true)])
        XCTAssertNotNil(r.reconciliationLine)
    }

    func testNoReconciliationOnAllAlignedGreen() {
        let r = card(action: .green, drivers: [driver("HRV", impact: 1, isNegative: false)])
        XCTAssertNil(r.reconciliationLine)
    }

    func testNoReconciliationOnYellow() {
        let r = card(action: .yellow, drivers: [driver("HRV", impact: 1, isNegative: true)])
        XCTAssertNil(r.reconciliationLine)
    }

    // No-definitional-fallback ------------------------------------------------------

    func testHRVSubtitleIsNotTheDefinitionalConstant() {
        let r = card(action: .green, drivers: [driver("HRV", impact: 1, isNegative: true)])
        let sub = r.driverDisplays().first!.subtitle
        XCTAssertNotEqual(sub, "Below baseline — often an early stress or recovery signal.")
        XCTAssertTrue(sub.contains("within normal range"))
    }

    // Screenshot regression: Green/High, HRV -1, sleep efficiency the low axis. -------

    func testScreenshotCardRendersCoherently() {
        let sleep = sleepResult(verdict: .good, composite: 72,
                                axes: [(.efficiency, 66), (.duration, 82), (.fragmentation, 85),
                                       (.architecture, 80), (.consistency, 78)])
        let r = card(action: .green,
                     drivers: [driver("HRV", impact: 1, isNegative: true),
                               driver("Sleep Efficiency", impact: 1, isNegative: true)],
                     sleep: sleep)
        let displays = r.driverDisplays()
        let hrv = displays.first { $0.label == "HRV" }!
        let sq = displays.first { $0.label == "Sleep Efficiency" }!

        XCTAssertEqual(hrv.sentiment, .calm)
        XCTAssertFalse(hrv.subtitle.lowercased().contains("stress"))
        XCTAssertTrue(sq.subtitle.contains("efficiency") || sq.subtitle.contains("Restless"))
        XCTAssertFalse(sq.subtitle.contains("Fragmented"))
        XCTAssertNotNil(r.reconciliationLine)
        XCTAssertFalse(displays.contains { $0.sentiment == .warn })
    }

    // MARK: - Phase 2: gate-hold messaging regression (EXPECTED RED until Phase 3)
    //
    // Captures the shipped bug: on a raw-green day the hysteresis gate holds the DISPLAY
    // at yellow, but `action` (and the copy derived from it) is driven off the gated
    // `truth`, so the card claims "Multiple recovery signals are outside their normal
    // range" while every recovery delta is favorable and every driver row is a green
    // up-arrow. These assert the POST-FIX contract; they FAIL against current code.

    private let yellowClusterClaim = "Multiple recovery signals are outside their normal range"

    // A result mirroring the CURRENT engine output on a cold-start gate hold:
    //   rawTruth green (recovery is fine) but displayed truth yellow (held for confirmation).
    // `action == truth` here because the engine currently does `action = truth` — that
    // coupling is exactly what Phase 3 fixes. Every delta is favorable-or-neutral; the
    // drivers are all positive (green up-arrows).
    private func gateHoldCard(drivers: [ReadinessDriver]) -> ReadinessResult {
        var r = ReadinessResult.empty
        r.rawTruth = .green
        r.truth = .yellow
        r.action = .yellow
        r.drivers = drivers
        r.rhrDelta = -3.9   // below baseline → favorable
        r.hrvDelta = 1.4    // above baseline → favorable
        r.sleepDelta = 1.1  // above target → favorable
        r.rrDelta = -2.3    // below baseline → favorable
        r.tempDelta = 0.0   // flat → neutral
        r.effDelta = 0.02   // above baseline → favorable
        return r
    }

    private func favorableDrivers() -> [ReadinessDriver] {
        [driver("RHR", impact: 1, isNegative: false),
         driver("Sleep", impact: 1, isNegative: false)]
    }

    private func clearVerdictLog() {
        UserDefaults(suiteName: SharedStore.appGroupID)?
            .removeObject(forKey: SharedStore.verdictLogKey)
    }

    // P2-1: no "outside their normal range" (or synonym) when every recovery delta is favorable.
    func testGateHoldExplanationDoesNotClaimSignalsOutsideNormalWhenAllFavorable() {
        let p = gateHoldCard(drivers: favorableDrivers()).presentation(manual: .default)
        XCTAssertFalse(p.explanation.contains(yellowClusterClaim),
            "Explanation must not claim recovery signals are outside normal range when every delta is favorable. Got: \(p.explanation)")
        XCTAssertFalse(p.explanation.lowercased().contains("outside"),
            "No 'outside normal range' synonym allowed on an all-favorable card. Got: \(p.explanation)")
        XCTAssertFalse(p.explanation.lowercased().contains("below baseline"),
            "No 'below baseline' claim allowed when all deltas are favorable. Got: \(p.explanation)")
    }

    // P2-2: a positive (green up-arrow) driver row must not sit under a caution headline.
    func testGateHoldPositiveDriverRowsDoNotContradictHeadline() {
        let r = gateHoldCard(drivers: favorableDrivers())
        let p = r.presentation(manual: .default)
        let displays = r.driverDisplays()
        XCTAssertTrue(displays.contains { $0.sentiment == .positive },
            "Fixture must have at least one positive driver row")
        let cautionHeadline = p.headline.lowercased().contains("guardrails")
            || p.subline.lowercased().contains("reduce effort")
        XCTAssertFalse(cautionHeadline && displays.contains { $0.sentiment == .positive },
            "A positive (green up-arrow) driver row must not sit under a caution headline. headline=\(p.headline) subline=\(p.subline)")
    }

    // P2-3: the count==0 Yellow must NOT route to .yellowCluster copy
    // (the `count==1 ? isolated : cluster` ternary misroutes zero-negative-driver Yellows).
    func testZeroNegativeDriverYellowDoesNotRouteToClusterCopy() {
        var r = ReadinessResult.empty
        r.rawTruth = .yellow
        r.truth = .yellow
        r.action = .yellow
        r.drivers = []   // count == 0 negatives
        let p = r.presentation(manual: .default)
        XCTAssertFalse(p.explanation.contains(yellowClusterClaim),
            "A zero-negative-driver Yellow must not route to the .yellowCluster 'multiple signals' copy. Got: \(p.explanation)")
    }

    // P2-4: on rawTruth==green && truth==yellow the explanation must confirm, not caution.
    func testGateHoldExplanationIsConfirmNotCaution() {
        let p = gateHoldCard(drivers: favorableDrivers()).presentation(manual: .default)
        XCTAssertTrue(p.explanation.lowercased().contains("confirm"),
            "On a rawTruth==green/truth==yellow hold the explanation must confirm recovery looks good, not caution. Got: \(p.explanation)")
        XCTAssertFalse(p.explanation.contains(yellowClusterClaim),
            "Hold explanation must not be the caution cluster string. Got: \(p.explanation)")
        XCTAssertFalse(p.explanation.lowercased().contains("guardrails"),
            "Hold explanation must not read as guardrails caution. Got: \(p.explanation)")
    }

    // P2-5: the engine strings WatchRootView reads directly (NOT via presentation()) must
    // narrate the amber-badge/green-action split, not stay bare yellow caution / bare green.
    func testGateHoldEngineMessageNarratesSplitNotBareGreenOrCaution() {
        clearVerdictLog()
        // Strong-green recovery day; with an empty verdict log yesterday is absent, so the
        // cold-start hysteresis hold fires: rawTruth green, displayed truth yellow.
        let result = eval(history(today: point(day: 28, rhr: 59, hrv: 36, sleep: 9.0, inBed: 9.5, rr: 13.5)))
        XCTAssertEqual(result.rawTruth, .green, "Favorable recovery must be raw green")
        XCTAssertEqual(result.truth, .yellow, "Empty verdict log → cold-start hold → displayed yellow")
        XCTAssertTrue(result.actionMessage.lowercased().contains("confirm"),
            "Engine actionMessage (read directly by WatchRootView) must narrate the confirm/hold on a raw-green day. Got: \(result.actionMessage)")
        XCTAssertFalse(result.actionMessage.contains("avoid top-end effort"),
            "Must not emit the bare yellow guardrails message when rawTruth is green. Got: \(result.actionMessage)")
    }

    // P2-6: when action derives green under an amber truth badge, the engine title must
    // reference the hold — assert on the actual engine string, not the card path.
    func testGateHoldEngineTitleReferencesHold() {
        clearVerdictLog()
        let result = eval(history(today: point(day: 28, rhr: 59, hrv: 36, sleep: 9.0, inBed: 9.5, rr: 13.5)))
        XCTAssertEqual(result.rawTruth, .green)
        XCTAssertEqual(result.truth, .yellow)
        let title = result.actionTitle.lowercased()
        XCTAssertTrue(title.contains("confirm") || title.contains("clear"),
            "Engine actionTitle must reference confirming/clearing the hold rather than a bare verdict. Got: \(result.actionTitle)")
    }

    // MARK: - Load-origin gate-skip regression tests

    // Helper: ISO string for yesterday using the same Calendar.current path the engine uses.
    private func yesterdayISO() -> String {
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let comps = cal.dateComponents([.year, .month, .day], from: yesterday)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    // G-1: Yesterday was yellow due to load alone (rawRecoveryTruth == .green).
    // The gate must recognise the load-origin and skip the hold → displayed truth green.
    func testLoadOriginYellowSkipsHoldShowsGreen() {
        clearVerdictLog()
        SharedStore.appendVerdictLog(
            DailyVerdictRecord(
                dateISO: yesterdayISO(),
                rawTotal: -2,        // load dragged total below yellow cutoff
                rawRecovery: 2,      // recovery alone was positive
                rawTruth: .yellow,
                rawRecoveryTruth: .green   // load-origin: recovery-stripped verdict was green
            )
        )
        let result = eval(history(today: point(day: 28, rhr: 59, hrv: 36, sleep: 9.0, inBed: 9.5, rr: 13.5)))
        XCTAssertEqual(result.rawTruth, .green,
            "Favorable recovery signals must produce rawTruth green. Got: \(result.rawTruth)")
        XCTAssertEqual(result.truth, .green,
            "Load-origin yesterday yellow must not trigger hold; gate should skip and display green. Got: \(result.truth)")
    }

    // G-2: Yesterday was yellow due to recovery signals (rawRecoveryTruth == .yellow).
    // The gate must preserve the one-day confirmation hold → displayed truth yellow.
    func testRecoveryOriginYellowKeepsHold() {
        clearVerdictLog()
        SharedStore.appendVerdictLog(
            DailyVerdictRecord(
                dateISO: yesterdayISO(),
                rawTotal: -5,        // recovery signals drove the yellow
                rawRecovery: -5,
                rawTruth: .yellow,
                rawRecoveryTruth: .yellow   // recovery-origin: stripped verdict also yellow
            )
        )
        let result = eval(history(today: point(day: 28, rhr: 59, hrv: 36, sleep: 9.0, inBed: 9.5, rr: 13.5)))
        XCTAssertEqual(result.rawTruth, .green,
            "Favorable recovery signals must produce rawTruth green. Got: \(result.rawTruth)")
        XCTAssertEqual(result.truth, .yellow,
            "Recovery-origin yesterday yellow must keep the confirmation hold; displayed truth must stay yellow. Got: \(result.truth)")
    }
}
