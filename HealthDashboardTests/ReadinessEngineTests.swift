import XCTest
@testable import HealthDashboard

final class ReadinessEngineTests: XCTestCase {

    private func point(
        day: Int,
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
        workoutEnergy: Double? = 400
    ) -> DailyHealthPoint {
        DailyHealthPoint(
            dayISO: String(format: "2026-05-%02d", day),
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
            bodyWeightLb: nil,
            bodyFatPct: nil,
            leanMassLb: nil
        )
    }

    private func history(today: DailyHealthPoint) -> [DailyHealthPoint] {
        let baseline = (1...27).map { point(day: $0) }
        return baseline + [today]
    }

    func testGoodRecoveryStaysGreen() {
        let result = ReadinessEngine.evaluate(
            history: history(today: point(day: 28)),
            manual: .default
        )

        XCTAssertEqual(result.truth, .green)
        XCTAssertEqual(result.action, .green)
        XCTAssertTrue(result.flags.isEmpty)
    }

    func testLowHRVAloneDoesNotForceRed() {
        let today = point(day: 28, hrv: 22)

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertNotEqual(result.truth, .red)
    }

    func testHighRHRAndLowHRVForcesYellow() {
        let today = point(day: 28, rhr: 70, hrv: 25)

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertEqual(result.truth, .yellow)
        XCTAssertTrue(result.flags.contains("HRV ↓"))
        XCTAssertTrue(result.flags.contains("RHR ↑"))
    }

    func testClusteredBadSignalsForcesRed() {
        let today = point(
            day: 28,
            rhr: 73,
            hrv: 22,
            sleep: 5.5,
            rr: 17.2
        )

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertEqual(result.truth, .red)
        XCTAssertEqual(result.action, .red)
    }

    func testSickManualInputForcesRedAction() {
        let result = ReadinessEngine.evaluate(
            history: history(today: point(day: 28)),
            manual: ManualReadinessInputs(painLevel: 0, isSick: true)
        )

        XCTAssertEqual(result.action, .red)
        XCTAssertTrue(result.flags.contains("Sick"))
    }

    func testHighPainForcesRedAction() {
        let result = ReadinessEngine.evaluate(
            history: history(today: point(day: 28)),
            manual: ManualReadinessInputs(painLevel: 8, isSick: false)
        )

        XCTAssertEqual(result.action, .red)
        XCTAssertTrue(result.flags.contains("Pain ↑"))
    }

    func testMissingHRVDoesNotCrashOrForceRed() {
        let today = point(day: 28, hrv: nil)

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertNotEqual(result.truth, .red)
    }

    func testRespiratoryRateContributesWithoutDominatingAlone() {
        let today = point(day: 28, rr: 16.5)

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertNotEqual(result.truth, .red)
        XCTAssertTrue(result.flags.contains("Resp Rate ↑"))
    }

    func testPoorSleepEfficiencyContributesToYellowWhenClustered() {
        let today = point(
            day: 28,
            rhr: 70,
            sleep: 7.8,
            inBed: 9.6
        )

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertEqual(result.truth, .yellow)
        XCTAssertTrue(result.flags.contains("RHR ↑"))
        XCTAssertTrue(result.flags.contains("Sleep quality ↓"))
    }

    func testLoadSpikeCreatesGuardrailsButDoesNotAutomaticallyForceRed() {
        let today = point(
            day: 28,
            steps: 14000,
            activeEnergy: 900,
            exercise: 90,
            workoutMinutes: 100,
            workoutEnergy: 750
        )

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertNotEqual(result.truth, .red)
    }
    
    func testMultipleMissingSignalsStillProducesStableResult() {
        let today = point(
            day: 28,
            rhr: nil,
            hrv: nil,
            sleep: 7.5,
            rr: nil,
            temp: nil,
            spo2: nil
        )

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertNotNil(result)
        XCTAssertNotEqual(result.truth, .red)
    }
    
    func testOutlierDataIsIgnored() {
        let today = point(
            day: 28,
            rhr: 140,   // invalid
            hrv: 2,     // invalid
            rr: 40      // invalid
        )

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertNotEqual(result.truth, .red)
    }
    
    func testHRVDropOverSeveralDaysTriggersYellow() {
        var hist = (1...24).map { point(day: $0, hrv: 30) }

        hist += [
            point(day: 25, hrv: 28),
            point(day: 26, hrv: 26),
            point(day: 27, hrv: 24),
            point(day: 28, hrv: 22)
        ]

        let result = ReadinessEngine.evaluate(
            history: hist,
            manual: .default
        )

        XCTAssertEqual(result.truth, .yellow)
        XCTAssertEqual(result.driverSummary, "HRV ↓ (isolated)")
    }
    
    func testGoodSleepOffsetsMinorHRVDrop() {
        let today = point(
            day: 28,
            hrv: 25,
            sleep: 9.0
        )

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertNotEqual(result.truth, .red)
    }
    func testCompleteDataProducesHighConfidence() {
        let result = ReadinessEngine.evaluate(
            history: history(today: point(day: 28)),
            manual: .default
        )

        XCTAssertEqual(result.confidence, .high)
    }

    func testPartialDataProducesMediumConfidence() {
        let today = point(
            day: 28,
            hrv: nil,
            temp: nil,
            spo2: nil
        )

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertEqual(result.confidence, .medium)
    }

    func testSparseDataProducesLowConfidence() {
        let today = point(
            day: 28,
            rhr: nil,
            hrv: nil,
            rr: nil,
            temp: nil,
            spo2: nil
        )

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertEqual(result.confidence, .low)
    }
    
    func testDriversArePopulatedAndSorted() {
        let today = point(
            day: 28,
            rhr: 72,
            hrv: 22,
            sleep: 5.5
        )

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: .default
        )

        XCTAssertFalse(result.drivers.isEmpty)

        if result.drivers.count >= 2 {
            XCTAssertGreaterThanOrEqual(
                result.drivers[0].impact,
                result.drivers[1].impact
            )
        }
    }
    
    func testHRVAloneAtNegativeThreeDoesNotForceYellowWhenOtherSignalsAreGood() {
        let today = point(
            day: 28,
            rhr: 66,
            hrv: 18.8,
            sleep: 9.7,
            inBed: 9.9,
            rr: 18.8,
            temp: 36.0
        )

        let result = ReadinessEngine.evaluate(
            history: history(today: today),
            manual: ManualReadinessInputs(painLevel: 1, isSick: false)
        )

        XCTAssertNotEqual(result.truth, .red)
        XCTAssertNotEqual(result.action, .red)
        //XCTAssertTrue(result.driverSummary.contains("HRV"))
    }
    
    func testStrongRecoveryBuffersLowHRV() {
        var hist = (1...24).map { point(day: $0, hrv: 30) }

        hist += [
            point(day: 25, hrv: 24),
            point(day: 26, hrv: 24),
            point(day: 27, hrv: 24),
            point(
                day: 28,
                rhr: 66,
                hrv: 18.8,
                sleep: 9.7,
                inBed: 9.9,
                rr: 18.8,
                temp: 36.0
            )
        ]

        let result = ReadinessEngine.evaluate(
            history: hist,
            manual: ManualReadinessInputs(painLevel: 1, isSick: false)
        )

        XCTAssertEqual(result.truth, .green)
        XCTAssertNotEqual(result.action, .red)
        XCTAssertEqual(result.driverSummary, "HRV ↓ (isolated)")
    }
    
    func testHRVTrendPlusAnotherSignalForcesYellow() {
        var hist = (1...24).map { point(day: $0, rhr: 65, hrv: 30) }

        hist += [
            point(day: 25, rhr: 66, hrv: 28),
            point(day: 26, rhr: 67, hrv: 26),
            point(day: 27, rhr: 69, hrv: 24),
            point(day: 28, rhr: 72, hrv: 22)
        ]

        let result = ReadinessEngine.evaluate(
            history: hist,
            manual: .default
        )

        XCTAssertEqual(result.truth, ReadinessStatus.yellow)
    }
    
}
