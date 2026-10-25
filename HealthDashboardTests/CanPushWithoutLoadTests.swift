import XCTest
@testable import HealthDashboard

/// `canPushKeyLiftWithoutLoad`: canPushKeyLift recomputed with the load term removed.
/// It is the same clause list, except the verdict clause uses the load-stripped recovery verdict
/// (and is not held by the confirmation gate) and the `loadMod >= -1` clause is not read.
final class CanPushWithoutLoadTests: XCTestCase {

    // MARK: Fixture builder
    //
    // 27 neutral baseline days then a custom "today". Baseline: RHR 65, HRV 30, sleep 8h in bed 8.7h,
    // RR 15, wrist-temp delta 0.0, SpO2 98, steps 8000, active 500 kcal, exercise 45 min, workout 60 min /
    // 400 kcal. Medians of those are the engine's baselines.

    private struct Today {
        var rhr = 65.0, hrv = 30.0, sleep = 8.0, inBed = 8.7, rr = 15.0, temp = 0.0, spo2 = 98.0
        var steps = 8000.0, active = 500.0, exercise = 45.0
        var trimp: Double? = nil
        var yesterdayRR: Double? = nil
        var baselineTrimp: Double? = nil
        var manual = ManualReadinessInputs.default
    }

    private func point(day: Int, rhr: Double, hrv: Double, sleep: Double, inBed: Double, rr: Double,
                       temp: Double, spo2: Double, steps: Double, active: Double, exercise: Double,
                       trimp: Double?) -> DailyHealthPoint {
        DailyHealthPoint(
            dayISO: String(format: "2026-05-%02d", day),
            restingHR: rhr, hrvMS: hrv, sleepHours: sleep, sleepInBedHours: inBed,
            respiratoryRate: rr, spo2Pct: spo2, wristTempDeltaC: temp,
            steps: steps, activeEnergyKcal: active, exerciseMinutes: exercise,
            standHours: 10, workoutCount: 1, workoutMinutes: 60, workoutEnergyKcal: 400,
            dailyTrimp: trimp, bodyWeightLb: nil, bodyFatPct: nil, leanMassLb: nil
        )
    }

    private func history(_ t: Today) -> [DailyHealthPoint] {
        var pts = (1...27).map { d in
            point(day: d, rhr: 65, hrv: 30, sleep: 8, inBed: 8.7,
                  rr: (d == 27 ? (t.yesterdayRR ?? 15) : 15),
                  temp: 0.0, spo2: 98, steps: 8000, active: 500, exercise: 45, trimp: t.baselineTrimp)
        }
        pts.append(point(day: 28, rhr: t.rhr, hrv: t.hrv, sleep: t.sleep, inBed: t.inBed, rr: t.rr,
                         temp: t.temp, spo2: t.spo2, steps: t.steps, active: t.active,
                         exercise: t.exercise, trimp: t.trimp))
        return pts
    }

    // MARK: Verdict-log state (the gate reads wall-clock yesterday's record)

    private func clearLog() {
        UserDefaults(suiteName: SharedStore.appGroupID)?.removeObject(forKey: SharedStore.verdictLogKey)
    }

    private func yesterdayISO() -> String {
        let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: y)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    private func todayISO() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Green yesterday: the gate does not hold a raw-green day.
    private func seedGreenYesterday() {
        clearLog()
        SharedStore.appendVerdictLog(
            DailyVerdictRecord(dateISO: yesterdayISO(), rawTotal: 4, rawRecovery: 4,
                               rawTruth: .green, rawRecoveryTruth: .green)
        )
    }

    override func setUp() { super.setUp(); clearLog() }
    override func tearDown() { clearLog(); super.tearDown() }

    private func run(_ t: Today, seedGreen: Bool = true) -> (result: ReadinessResult, loadMod: Int, recovery: Int) {
        if seedGreen { seedGreenYesterday() } else { clearLog() }
        let r = ReadinessEngine.evaluate(history: history(t), manual: t.manual)
        // The persisted record carries rawTotal (recovery + load) and rawRecovery, so the load term is
        // observable: loadMod = rawTotal - rawRecovery.
        let rec = SharedStore.loadVerdictLog().first { $0.dateISO == todayISO() }
        let recovery = rec?.rawRecovery ?? .min
        return (r, (rec?.rawTotal ?? 0) - (rec?.rawRecovery ?? 0), recovery)
    }

    // The recovery of the real 10-24 shape: HRV +10% (+1), RHR -3 bpm (+1), sleep above baseline (+1).
    private var recoveryPlus3: Today {
        var t = Today(); t.hrv = 33; t.rhr = 62; t.sleep = 9.0; t.inBed = 9.7; return t
    }

    private func assertPush(_ r: ReadinessResult, _ full: Bool, _ stripped: Bool,
                            _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.canPushKeyLift, full, "\(label): canPushKeyLift", file: file, line: line)
        XCTAssertEqual(r.canPushKeyLiftWithoutLoad, stripped, "\(label): canPushKeyLiftWithoutLoad", file: file, line: line)
    }

    // MARK: 2. Fixtures

    func testAllClear_trueTrue() {
        let o = run(recoveryPlus3)
        XCTAssertEqual(o.recovery, 3)
        XCTAssertEqual(o.loadMod, 0)
        XCTAssertEqual(o.result.truth, .green)
        assertPush(o.result, true, true, "all clear")
    }

    /// The real 10-24 shape: recovery +3, load -3, no flags. Green recovery, load alone blocks Push.
    func testLoadBlocked_recoveryPlus3_loadMinus3_falseTrue() {
        var t = recoveryPlus3
        t.baselineTrimp = 30; t.trimp = 70            // ratio 2.33 -> -3
        let o = run(t)
        XCTAssertEqual(o.recovery, 3)
        XCTAssertEqual(o.loadMod, -3)
        XCTAssertEqual(o.result.truth, .green, "total 0 is still green: only the load clause blocks")
        assertPush(o.result, false, true, "load-blocked 10-24 shape")
    }

    func testLoadAtMinusTwoAlsoBlocks_andMinusOneDoesNot() {
        var two = recoveryPlus3; two.baselineTrimp = 30; two.trimp = 50   // ratio 1.67 -> -2
        let o2 = run(two)
        XCTAssertEqual(o2.loadMod, -2)
        assertPush(o2.result, false, true, "load -2")

        var one = recoveryPlus3; one.baselineTrimp = 30; one.trimp = 40   // ratio 1.33 -> -1
        let o1 = run(one)
        XCTAssertEqual(o1.loadMod, -1)
        assertPush(o1.result, true, true, "load -1 still pushes")
    }

    /// Load pushes the TOTAL into yellow although recovery alone is green.
    func testLoadPushesTotalIntoYellow_falseTrue() {
        var t = Today()
        t.baselineTrimp = 30; t.trimp = 70                 // -3
        t.steps = 12000; t.active = 700                    // two activity highs -> -2
        let o = run(t)
        XCTAssertEqual(o.recovery, 0)
        XCTAssertEqual(o.loadMod, -5)
        XCTAssertEqual(o.result.truth, .yellow)
        XCTAssertEqual(o.result.rawTruth, .yellow)
        XCTAssertEqual(o.result.rawRecoveryTruth, .green)
        assertPush(o.result, false, true, "load pushes total into yellow")
    }

    /// rrUp10 uses the 2-day mean RR, so it can fire with NO negative driver (today's own RR is fine).
    func testFlagBlocked_rrUp10Only_noNegativeDrivers_falseFalse() {
        var t = Today(); t.yesterdayRR = 17.2; t.rr = 15.0
        let o = run(t)
        XCTAssertTrue(o.result.drivers.isEmpty, "no drivers at all: the flag is invisible on the card")
        XCTAssertEqual(o.result.truth, .green)
        assertPush(o.result, false, false, "rrUp10 only")
    }

    /// The real 10-25 shape: recovery -2 (wrist temp +, SpO2 -), load -1, tempUp03 only.
    func testFlagBlocked_tempUp03_recoveryMinus2_loadMinus1_falseFalse() {
        var t = Today()
        t.temp = 0.4; t.spo2 = 96.5
        t.baselineTrimp = 30; t.trimp = 40                 // ratio 1.33 -> -1
        let o = run(t)
        XCTAssertEqual(o.recovery, -2)
        XCTAssertEqual(o.loadMod, -1)
        XCTAssertEqual(o.result.truth, .green)
        assertPush(o.result, false, false, "tempUp03 (10-25 shape)")
    }

    func testFlagBlocked_hrvDown10_falseFalse() {
        var t = Today(); t.hrv = 26
        let o = run(t)
        XCTAssertEqual(o.result.truth, .green)
        assertPush(o.result, false, false, "hrvDown10")
    }

    func testFlagBlocked_rhrUp3_falseFalse() {
        var t = Today(); t.rhr = 68
        let o = run(t)
        XCTAssertEqual(o.result.truth, .green)
        assertPush(o.result, false, false, "rhrUp3")
    }

    func testFlagBlocked_sleepEffLow_falseFalse() {
        var t = Today(); t.inBed = 9.9                     // efficiency 0.808 vs baseline 0.9195
        let o = run(t)
        XCTAssertEqual(o.result.truth, .green)
        assertPush(o.result, false, false, "sleepEffLow")
    }

    /// A gate hold (raw green, display held yellow) is not a load effect: both are false.
    func testGateHeld_falseFalse() {
        let o = run(recoveryPlus3, seedGreen: false)       // no record for yesterday -> first-run hold
        XCTAssertEqual(o.result.rawTruth, .green)
        XCTAssertEqual(o.result.truth, .yellow)
        assertPush(o.result, false, false, "gate-held")
    }

    func testSick_falseFalse() {
        var t = recoveryPlus3; t.manual = ManualReadinessInputs(painLevel: 0, isSick: true)
        assertPush(run(t).result, false, false, "sick")
    }

    func testPain3_falseFalse() {
        var t = recoveryPlus3; t.manual = ManualReadinessInputs(painLevel: 3, isSick: false)
        assertPush(run(t).result, false, false, "pain 3")
    }

    func testPain2StillPushes() {
        var t = recoveryPlus3; t.manual = ManualReadinessInputs(painLevel: 2, isSick: false)
        assertPush(run(t).result, true, true, "pain 2")
    }

    // MARK: 1. Nothing else changed

    /// The new field is display-only: it is not stored in the verdict log.
    func testVerdictLogRecordCarriesNoNewField() throws {
        _ = run(recoveryPlus3)
        let data = try XCTUnwrap(UserDefaults(suiteName: SharedStore.appGroupID)?.data(forKey: SharedStore.verdictLogKey))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("canPush"), "DailyVerdictRecord must be unchanged")
    }

    // MARK: 3. Invariant over a generated grid: canPushKeyLift implies canPushKeyLiftWithoutLoad

    func testInvariant_canPushImpliesCanPushWithoutLoad_overAGrid() {
        var evaluated = 0, bothTrue = 0, strippedOnly = 0, violations: [String] = []

        for seedGreen in [true, false] {
            if seedGreen { seedGreenYesterday() } else { clearLog() }

            for rhr in [65.0, 68.0] {
              for hrv in [26.0, 33.0] {
                for temp in [0.0, 0.4] {
                  for (yRR, rr) in [(15.0, 15.0), (17.2, 15.0)] {
                    for inBed in [8.7, 9.9] {
                      for pain in [0, 3] {
                        for trimp in [nil, 40.0, 50.0, 70.0] as [Double?] {
                          for (steps, active) in [(8000.0, 500.0), (12000.0, 700.0)] {
                            var t = Today()
                            t.rhr = rhr; t.hrv = hrv; t.temp = temp; t.yesterdayRR = yRR; t.rr = rr
                            t.inBed = inBed; t.steps = steps; t.active = active
                            t.baselineTrimp = (trimp == nil) ? nil : 30
                            t.trimp = trimp
                            t.manual = ManualReadinessInputs(painLevel: pain, isSick: false)

                            let r = VerdictPersistence.withSuppressedPersistence {
                                ReadinessEngine.evaluate(history: history(t), manual: t.manual)
                            }
                            evaluated += 1
                            let stripped = r.canPushKeyLiftWithoutLoad
                            if stripped == nil { violations.append("nil stripped: \(t)") }
                            if r.canPushKeyLift && stripped != true {
                                violations.append("canPush true but stripped \(String(describing: stripped)): \(t) seedGreen=\(seedGreen)")
                            }
                            if r.canPushKeyLift && stripped == true { bothTrue += 1 }
                            if !r.canPushKeyLift && stripped == true { strippedOnly += 1 }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
        }

        XCTAssertTrue(violations.isEmpty, violations.prefix(5).joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(evaluated, 1024)
        XCTAssertGreaterThan(bothTrue, 0, "grid must contain push-allowed cases (not vacuous)")
        XCTAssertGreaterThan(strippedOnly, 0, "grid must contain load-blocked cases (not vacuous)")
    }

    // MARK: 4. Codable

    func testLegacyDecodeWithoutTheFieldGivesNil() throws {
        XCTAssertNil(ReadinessResult.empty.canPushKeyLiftWithoutLoad)

        var legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ReadinessResult.empty)) as! [String: Any]
        legacy.removeValue(forKey: "canPushKeyLiftWithoutLoad")
        let decoded = try JSONDecoder().decode(ReadinessResult.self,
                                               from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.canPushKeyLiftWithoutLoad)
        XCTAssertEqual(decoded, ReadinessResult.empty)
    }

    func testFieldRoundTripsWhenPresent() throws {
        for value in [true, false] {
            var r = ReadinessResult.empty
            r.canPushKeyLiftWithoutLoad = value
            let back = try JSONDecoder().decode(ReadinessResult.self, from: JSONEncoder().encode(r))
            XCTAssertEqual(back.canPushKeyLiftWithoutLoad, value)
        }
    }
}
