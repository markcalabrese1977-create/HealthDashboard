import XCTest
@testable import HealthDashboard

// Parity harness for the "hold exception" commit: adding ReadinessResult.rawRecoveryTruth and
// moving the delta declarations out of #if DEBUG must be behavior-neutral. Goldens in
// ReadinessParityGolden.swift were captured on main (9fd10da) BEFORE any engine edit; every
// pre-existing ReadinessResult field and every DailyVerdictRecord field must still match
// exactly. The new field must equal the value the engine already logs.

final class ReadinessParityTests: XCTestCase {

    struct Fixture {
        let name: String
        let history: [DailyHealthPoint]
        let manual: ManualReadinessInputs
    }

    static func point(
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
        workoutEnergy: Double? = 400,
        trimp: Double? = nil
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
            dailyTrimp: trimp,
            bodyWeightLb: nil,
            bodyFatPct: nil,
            leanMassLb: nil
        )
    }

    /// 27 baseline days (optionally with a TRIMP baseline) + a custom today.
    static func history(today: DailyHealthPoint, baselineTrimp: Double? = nil) -> [DailyHealthPoint] {
        (1...27).map { point(day: $0, trimp: baselineTrimp) } + [today]
    }

    static let fixtures: [Fixture] = [
        Fixture(name: "green_neutral",
                history: history(today: point(day: 28)),
                manual: .default),
        Fixture(name: "green_missing_signals",
                history: history(today: point(day: 28, rhr: nil, hrv: nil, sleep: 7.5, rr: nil, temp: nil, spo2: nil)),
                manual: .default),
        Fixture(name: "yellow_cluster",
                history: history(today: point(day: 28, rhr: 70, hrv: 25)),
                manual: .default),
        Fixture(name: "yellow_isolated_rr",
                history: history(today: point(day: 28, rr: 16.5)),
                manual: .default),
        Fixture(name: "yellow_load_only",
                history: history(today: point(day: 28, steps: 14000, activeEnergy: 900, exercise: 90,
                                              trimp: 90),
                                 baselineTrimp: 50),
                manual: .default),
        Fixture(name: "red_recovery_cluster",
                history: history(today: point(day: 28, rhr: 73, hrv: 22, sleep: 5.5, rr: 17.2)),
                manual: .default),
        Fixture(name: "red_load_recovery_green",
                history: history(today: point(day: 28, steps: 14000,
                                              activeEnergy: 900, exercise: 90, trimp: 130),
                                 baselineTrimp: 50),
                manual: ManualReadinessInputs(painLevel: 5, isSick: false)),
        // Out-of-range inputs: the engine ignores them for scoring but the returned deltas
        // still read the raw values — the moved delta declarations must preserve that.
        Fixture(name: "out_of_range_hrv_rhr",
                history: history(today: point(day: 28, rhr: 20, hrv: 300)),
                manual: .default),
        Fixture(name: "red_sick",
                history: history(today: point(day: 28)),
                manual: ManualReadinessInputs(painLevel: 0, isSick: true)),
        Fixture(name: "red_high_pain",
                history: history(today: point(day: 28)),
                manual: ManualReadinessInputs(painLevel: 8, isSick: false)),
    ]

    private static var appGroupDefaults: UserDefaults? {
        UserDefaults(suiteName: SharedStore.appGroupID)
    }

    /// Runs the engine on a clean verdict log and returns
    /// {"result": ReadinessResult JSON, "record": DailyVerdictRecord JSON}.
    /// `dateISO` is dropped from the record (it is the wall-clock date of the run).
    static func run(_ f: Fixture) throws -> [String: Any] {
        appGroupDefaults?.removeObject(forKey: SharedStore.verdictLogKey)

        let result = ReadinessEngine.evaluate(history: f.history, manual: f.manual)

        let todayISO: String = {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        }()
        let logged = SharedStore.loadVerdictLog()
        guard let record = logged.first(where: { $0.dateISO == todayISO }) else {
            throw NSError(domain: "ReadinessParity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no verdict record appended for \(f.name)"])
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var recordJSON = try JSONSerialization.jsonObject(with: enc.encode(record)) as! [String: Any]
        recordJSON.removeValue(forKey: "dateISO")
        var resultJSON = try JSONSerialization.jsonObject(with: enc.encode(result)) as! [String: Any]
        // Engine emits flags in Dictionary-hash order (varies per process); compare as a sorted set.
        resultJSON["flags"] = (resultJSON["flags"] as? [String] ?? []).sorted()
        return ["result": resultJSON, "record": recordJSON]
    }

    // MARK: - Parity

    private func golden() throws -> [String: [String: Any]] {
        let data = Data(ReadinessParityGolden.json.utf8)
        return try JSONSerialization.jsonObject(with: data) as! [String: [String: Any]]
    }

    func testFixturesCoverRequiredVerdictShapes() throws {
        let g = try golden()
        func result(_ n: String, _ k: String) -> String? { (g[n]?["result"] as? [String: Any])?[k] as? String }
        func record(_ n: String, _ k: String) -> String? { (g[n]?["record"] as? [String: Any])?[k] as? String }
        XCTAssertEqual(record("green_neutral", "rawTruth"), "green")
        XCTAssertEqual(record("yellow_cluster", "rawTruth"), "yellow")
        XCTAssertEqual(record("red_recovery_cluster", "rawTruth"), "red")
        // The load-caused red: red verdict, recovery-only verdict green.
        XCTAssertEqual(record("red_load_recovery_green", "rawTruth"), "red")
        XCTAssertEqual(record("red_load_recovery_green", "rawRecoveryTruth"), "green")
        XCTAssertEqual(result("red_load_recovery_green", "action"), "red")
        XCTAssertGreaterThanOrEqual(Self.fixtures.count, 6)
    }

    func testEveryPreExistingFieldMatchesMainGolden() throws {
        let g = try golden()
        XCTAssertEqual(Set(g.keys), Set(Self.fixtures.map(\.name)))

        for f in Self.fixtures {
            let out = try Self.run(f)
            let want = try XCTUnwrap(g[f.name], f.name)

            // DailyVerdictRecord: every field, exact.
            XCTAssertEqual(try XCTUnwrap(out["record"] as? NSDictionary),
                           try XCTUnwrap(want["record"] as? NSDictionary),
                           "\(f.name): DailyVerdictRecord drifted from main golden")

            // ReadinessResult: every pre-existing field, exact (new field excluded here).
            var got = try XCTUnwrap(out["result"] as? [String: Any])
            got.removeValue(forKey: "rawRecoveryTruth")
            XCTAssertEqual(got as NSDictionary, try XCTUnwrap(want["result"] as? NSDictionary),
                           "\(f.name): ReadinessResult drifted from main golden")
        }
    }

    func testRawRecoveryTruthMatchesLoggedVerdictRecord() throws {
        for f in Self.fixtures {
            let out = try Self.run(f)
            let result = try XCTUnwrap(out["result"] as? [String: Any])
            let record = try XCTUnwrap(out["record"] as? [String: Any])
            let fromResult = try XCTUnwrap(result["rawRecoveryTruth"] as? String,
                                           "\(f.name): result.rawRecoveryTruth missing")
            XCTAssertEqual(fromResult, record["rawRecoveryTruth"] as? String, f.name)
        }
    }

    func testRawRecoveryTruthIsNilOnEmptyAndOnLegacyJSON() throws {
        XCTAssertNil(ReadinessResult.empty.rawRecoveryTruth)

        // Snapshots/payloads encoded before the field existed must still decode.
        let enc = JSONEncoder()
        var legacy = try JSONSerialization.jsonObject(with: enc.encode(ReadinessResult.empty)) as! [String: Any]
        legacy.removeValue(forKey: "rawRecoveryTruth")
        let decoded = try JSONDecoder().decode(ReadinessResult.self,
                                               from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.rawRecoveryTruth)
        XCTAssertEqual(decoded, ReadinessResult.empty)
    }
}
