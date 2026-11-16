import XCTest
@testable import HealthDashboard

// A Reality-check edit re-evaluates the engine. Before the day's fetch lands the history still ends
// yesterday; that evaluation must not write yesterday's verdict into today's log slot.
final class ManualEditPersistenceTests: XCTestCase {

    private var suite: UserDefaults? { UserDefaults(suiteName: SharedStore.appGroupID) }
    private var savedLog: Data?

    override func setUp() {
        super.setUp()
        savedLog = suite?.data(forKey: SharedStore.verdictLogKey)
        suite?.removeObject(forKey: SharedStore.verdictLogKey)
    }

    override func tearDown() {
        if let savedLog { suite?.set(savedLog, forKey: SharedStore.verdictLogKey) }
        else { suite?.removeObject(forKey: SharedStore.verdictLogKey) }
        super.tearDown()
    }

    private var logData: Data? { suite?.data(forKey: SharedStore.verdictLogKey) }

    private func isoDay(daysFromToday offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        return LiveEvaluationPolicy.todayISO(now: d)
    }

    private func history(endingDaysFromToday endOffset: Int) -> [DailyHealthPoint] {
        (0..<28).map { i in
            DailyHealthPoint(
                dayISO: isoDay(daysFromToday: endOffset - (27 - i)),
                restingHR: i == 27 ? 71 : 65,
                hrvMS: i == 27 ? 25 : 30,
                sleepHours: 8, sleepInBedHours: 8.7, respiratoryRate: 15, spo2Pct: 98,
                wristTempDeltaC: 36.5, steps: 8000, activeEnergyKcal: 500, exerciseMinutes: 45,
                standHours: 10, workoutCount: 1, workoutMinutes: 60, workoutEnergyKcal: 400,
                dailyTrimp: nil, bodyWeightLb: nil, bodyFatPct: nil, leanMassLb: nil
            )
        }
    }

    private let edit = ManualReadinessInputs(painLevel: 6, isSick: false)

    func testManualEditOnYesterdayHistoryLeavesLogUnchanged() {
        SharedStore.appendVerdictLog(
            DailyVerdictRecord(dateISO: isoDay(daysFromToday: -1), rawTotal: -5, rawRecovery: -5,
                               rawTruth: .yellow, rawRecoveryTruth: .yellow)
        )
        let before = logData
        XCTAssertNotNil(before)

        let r = LiveEvaluationPolicy.evaluateForManualEdit(history: history(endingDaysFromToday: -1), manual: edit)

        XCTAssertEqual(logData, before, "no record may be written or replaced")
        XCTAssertTrue(r.flags.contains("Pain ↑"), "the card still reflects the manual edit")
    }

    func testManualEditOnYesterdayHistoryWithEmptyLogCreatesNoKey() {
        _ = LiveEvaluationPolicy.evaluateForManualEdit(history: history(endingDaysFromToday: -1), manual: edit)
        XCTAssertNil(logData)
    }

    func testManualEditOnTodayHistoryStillPersists() {
        let before = LiveEvaluationPolicy.todayISO()
        _ = LiveEvaluationPolicy.evaluateForManualEdit(history: history(endingDaysFromToday: 0), manual: edit)
        let after = LiveEvaluationPolicy.todayISO()

        let keys = Set(SharedStore.loadVerdictLog().map { $0.dateISO })
        XCTAssertTrue(keys.contains(before) || keys.contains(after), "\(keys)")
    }
}
