import XCTest
@testable import HealthDashboard

// .greenNoPushLoad: a green day where push is not allowed ONLY because of the load term
// (canPushKeyLift false, canPushKeyLiftWithoutLoad true). Everything else keeps its current routing.
final class ReadinessGreenNoPushLoadTests: XCTestCase {

    private let manualOff = ManualReadinessInputs.default

    private func driver(_ label: String, negative: Bool = false) -> ReadinessDriver {
        ReadinessDriver(label: label, impact: 1, isNegative: negative, reason: "", consecutiveDays: 0)
    }

    private func card(action: ReadinessStatus,
                      canPush: Bool,
                      stripped: Bool?,
                      confidence: ReadinessConfidence = .high,
                      drivers: [ReadinessDriver] = []) -> ReadinessResult {
        var r = ReadinessResult.empty
        r.action = action
        r.truth = action           // action == truth == rawTruth: no gate hold in this matrix
        r.rawTruth = action
        r.rawRecoveryTruth = nil   // the routing under test does not read it for green
        r.canPushKeyLift = canPush
        r.canPushKeyLiftWithoutLoad = stripped
        r.confidence = confidence
        r.drivers = drivers
        return r
    }

    private let loadBody =
        "Recovery signals are within range. Today’s training and activity load is already high, so there’s no case for pushing. Run the plan cleanly."

    // MARK: Routing table (cells other than green / canPush false / stripped true equal CURRENT behavior)
    //
    // Written from the pre-change routing: red -> .red (rawRecoveryTruth nil), yellow with no drivers ->
    // .yellowLoad, green -> greenPush if canPush else greenNoPush. The stripped flag was not read.

    private typealias S = ReadinessMessageState

    func testRoutingTable() {
        let strippedValues: [Bool?] = [nil, true, false]

        // action green
        for stripped in strippedValues {
            XCTAssertEqual(card(action: .green, canPush: true, stripped: stripped).resolveMessageState(manual: manualOff),
                           .greenPush, "green / canPush true / stripped \(String(describing: stripped))")
        }
        XCTAssertEqual(card(action: .green, canPush: false, stripped: nil).resolveMessageState(manual: manualOff), .greenNoPush)
        XCTAssertEqual(card(action: .green, canPush: false, stripped: false).resolveMessageState(manual: manualOff), .greenNoPush)
        XCTAssertEqual(card(action: .green, canPush: false, stripped: true).resolveMessageState(manual: manualOff), .greenNoPushLoad)  // CHANGED

        // action yellow: unchanged whatever the push flags say
        for canPush in [true, false] {
            for stripped in strippedValues {
                XCTAssertEqual(card(action: .yellow, canPush: canPush, stripped: stripped).resolveMessageState(manual: manualOff),
                               .yellowLoad, "yellow / \(canPush) / \(String(describing: stripped))")
            }
        }

        // action red: unchanged whatever the push flags say
        for canPush in [true, false] {
            for stripped in strippedValues {
                XCTAssertEqual(card(action: .red, canPush: canPush, stripped: stripped).resolveMessageState(manual: manualOff),
                               .red, "red / \(canPush) / \(String(describing: stripped))")
            }
        }
    }

    func testSickAndHighPainStillBeatTheNewState() {
        let r = card(action: .green, canPush: false, stripped: true)
        XCTAssertEqual(r.resolveMessageState(manual: ManualReadinessInputs(painLevel: 0, isSick: true)), .sick)
        XCTAssertEqual(r.resolveMessageState(manual: ManualReadinessInputs(painLevel: 7, isSick: false)), .highPain)
    }

    func testGateHoldStillBeatsTheNewState() {
        var r = card(action: .green, canPush: false, stripped: true)
        r.truth = .yellow; r.rawTruth = .green      // display held amber for confirmation
        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .gateHold)
    }

    // MARK: Copy

    func testCopyForTheNewState() {
        let p = card(action: .green, canPush: false, stripped: true).presentation(manual: manualOff)
        XCTAssertEqual(p.headline, "Train normally")
        XCTAssertEqual(p.subline, "Not a push day")
        XCTAssertEqual(p.driverLine, "Driver: Elevated training load")
        XCTAssertEqual(p.explanation, loadBody)
        XCTAssertEqual(p.guidanceButtonTitle, "View training guidance")
    }

    func testBodyNeverSaysNotStrongEnough() {
        for conf in [ReadinessConfidence.high, .medium, .low] {
            let p = card(action: .green, canPush: false, stripped: true, confidence: conf).presentation(manual: manualOff)
            XCTAssertFalse(p.explanation.contains("not strong enough"), p.explanation)
            XCTAssertFalse(p.explanation.contains("compromised"), p.explanation)
        }
    }

    func testConfidenceSuffixIsAppended() {
        func body(_ c: ReadinessConfidence) -> String {
            card(action: .green, canPush: false, stripped: true, confidence: c).presentation(manual: manualOff).explanation
        }
        XCTAssertEqual(body(.high), loadBody)
        XCTAssertEqual(body(.medium), loadBody + " Some signals are mixed, so treat this as a directional read, not absolute.")
        XCTAssertEqual(body(.low), loadBody + " Data is limited or inconsistent today. Lean more on how you actually feel.")
    }

    func testLoggedStateStringIsTheCaseName() {
        let r = card(action: .green, canPush: false, stripped: true)
        XCTAssertEqual(String(describing: r.resolveMessageState(manual: manualOff)), "greenNoPushLoad")
        XCTAssertEqual(String(describing: ReadinessMessageState.greenNoPush), "greenNoPush")
    }

    // MARK: Fixtures

    /// A load-blocked card: green, canPush false, stripped true, High confidence, two positive drivers.
    func testLoadBlockedFixtureResolvesToTheNewState() {
        let r = card(action: .green, canPush: false, stripped: true, confidence: .high,
                     drivers: [driver("HRV"), driver("Sleep")])
        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .greenNoPushLoad)
        XCTAssertEqual(r.presentation(manual: manualOff).subline, "Not a push day")
        XCTAssertEqual(r.driverDisplays(manual: manualOff).map(\.sentiment), [.positive, .positive], "rows unchanged")
    }

    /// A flag-blocked card (canPush false, stripped false) keeps the old state and the old copy.
    func testFlagBlockedFixtureStaysOnTheOldState() {
        let r = card(action: .green, canPush: false, stripped: false, confidence: .high,
                     drivers: [driver("HRV"), driver("Sleep")])
        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .greenNoPush)
        let p = r.presentation(manual: manualOff)
        XCTAssertEqual(p.explanation, "Recovery is stable, but not strong enough to justify pushing. Run the plan cleanly.")
        XCTAssertEqual(p.driverLine, "Driver: Stable, not elevated")
    }

    /// Legacy payloads (stripped nil) keep the old state.
    func testNilStrippedKeepsTheOldState() {
        let r = card(action: .green, canPush: false, stripped: nil)
        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .greenNoPush)
    }

    // Driver rows are unchanged: a negative driver on a green card is still calm; the driver LINE is the
    // new state's, independent of negatives.
    func testNegativeDriversStayCalmAndTheDriverLineIsLoad() {
        let r = card(action: .green, canPush: false, stripped: true, drivers: [driver("HRV", negative: true), driver("Sleep")])
        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .greenNoPushLoad)
        XCTAssertEqual(r.driverDisplays(manual: manualOff).map(\.sentiment), [.calm, .positive])
        XCTAssertEqual(r.presentation(manual: manualOff).driverLine, "Driver: Elevated training load")
    }

    // MARK: End to end through the engine (real shapes)

    private func history(hrv: Double, rhr: Double, sleep: Double, inBed: Double,
                         trimp: Double?, baselineTrimp: Double?, yesterdayRR: Double = 15) -> [DailyHealthPoint] {
        func pt(_ d: Int, _ rhr: Double, _ hrv: Double, _ sleep: Double, _ inBed: Double, _ rr: Double, _ trimp: Double?) -> DailyHealthPoint {
            DailyHealthPoint(dayISO: String(format: "2026-05-%02d", d), restingHR: rhr, hrvMS: hrv,
                             sleepHours: sleep, sleepInBedHours: inBed, respiratoryRate: rr, spo2Pct: 98,
                             wristTempDeltaC: 0.0, steps: 8000, activeEnergyKcal: 500, exerciseMinutes: 45,
                             standHours: 10, workoutCount: 1, workoutMinutes: 60, workoutEnergyKcal: 400,
                             dailyTrimp: trimp, bodyWeightLb: nil, bodyFatPct: nil, leanMassLb: nil)
        }
        var pts = (1...27).map { pt($0, 65, 30, 8, 8.7, $0 == 27 ? yesterdayRR : 15, baselineTrimp) }
        pts.append(pt(28, rhr, hrv, sleep, inBed, 15, trimp))
        return pts
    }

    private func seedGreenYesterday() {
        UserDefaults(suiteName: SharedStore.appGroupID)?.removeObject(forKey: SharedStore.verdictLogKey)
        let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: y)
        SharedStore.appendVerdictLog(
            DailyVerdictRecord(dateISO: String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1),
                               rawTotal: 4, rawRecovery: 4, rawTruth: .green, rawRecoveryTruth: .green))
    }

    override func tearDown() {
        UserDefaults(suiteName: SharedStore.appGroupID)?.removeObject(forKey: SharedStore.verdictLogKey)
        super.tearDown()
    }

    /// Real 10-24 shape: recovery +3 (HRV, RHR, sleep), load -3. The engine produces it; the card says load.
    func testEngineLoadBlockedShapeResolvesToTheNewState() {
        seedGreenYesterday()
        let r = ReadinessEngine.evaluate(
            history: history(hrv: 33, rhr: 62, sleep: 9.0, inBed: 9.7, trimp: 70, baselineTrimp: 30),
            manual: manualOff)
        XCTAssertFalse(r.canPushKeyLift)
        XCTAssertEqual(r.canPushKeyLiftWithoutLoad, true)
        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .greenNoPushLoad)
        XCTAssertFalse(r.presentation(manual: manualOff).explanation.contains("not strong enough"))
    }

    /// rrUp10 only (no negative driver, no load): the old state and copy.
    func testEngineFlagBlockedShapeStaysOnTheOldState() {
        seedGreenYesterday()
        let r = ReadinessEngine.evaluate(
            history: history(hrv: 30, rhr: 65, sleep: 8.0, inBed: 8.7, trimp: nil, baselineTrimp: nil, yesterdayRR: 17.2),
            manual: manualOff)
        XCTAssertFalse(r.canPushKeyLift)
        XCTAssertEqual(r.canPushKeyLiftWithoutLoad, false)
        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .greenNoPush)
    }

    func testEngineAllClearIsStillPush() {
        seedGreenYesterday()
        let r = ReadinessEngine.evaluate(
            history: history(hrv: 33, rhr: 62, sleep: 9.0, inBed: 9.7, trimp: nil, baselineTrimp: nil),
            manual: manualOff)
        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .greenPush)
    }
}
