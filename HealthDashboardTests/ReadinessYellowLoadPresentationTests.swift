import XCTest
@testable import HealthDashboard

// .yellowLoadMinorDrivers: action == .yellow AND rawRecoveryTruth == .green AND >= 1 negative driver.
// The recovery-only verdict is green, so those drivers were sub-verdict; the card uses load framing
// (same attribution as .redLoad) instead of the recovery-caution copy. Everything else is unchanged.
final class ReadinessYellowLoadPresentationTests: XCTestCase {

    // MARK: Builders

    private static let labels = ["HRV", "Sleep", "RHR"]

    private func driver(_ label: String, negative: Bool) -> ReadinessDriver {
        ReadinessDriver(label: label, impact: 1, isNegative: negative,
                        reason: "Off from baseline.", consecutiveDays: 0)
    }

    /// `negatives` of the drivers are negative (first N of HRV, Sleep, RHR), the rest positive.
    private func drivers(negatives: Int, total: Int? = nil) -> [ReadinessDriver] {
        let n = total ?? max(negatives, 0)
        return (0..<n).map { driver(Self.labels[$0], negative: $0 < negatives) }
    }

    private func card(action: ReadinessStatus,
                      recovery: ReadinessStatus?,
                      negatives: Int,
                      confidence: ReadinessConfidence = .high) -> ReadinessResult {
        var r = ReadinessResult.empty
        r.action = action
        r.truth = action        // action == truth: no gate hold in this matrix
        r.rawTruth = action
        r.rawRecoveryTruth = recovery
        r.confidence = confidence
        r.drivers = drivers(negatives: negatives)
        r.canPushKeyLift = false
        return r
    }

    private let manualOff = ManualReadinessInputs.default

    // MARK: (a) Routing matrix
    //
    // Expected table, written from the resolveMessageState precedence (sick, highPain, red/redLoad,
    // gateHold, yellow, green) and NOT from the new code. Columns are negative-driver counts 0,1,2,3.
    // Only the (yellow, green, >=1) cells differ from the behavior before this change.

    private typealias S = ReadinessMessageState
    private let table: [(action: ReadinessStatus, recovery: ReadinessStatus?, expected: [S])] = [
        // green action: recovery truth is irrelevant; canPushKeyLift is false here
        (.green,  .green,  [.greenNoPush, .greenNoPush, .greenNoPush, .greenNoPush]),
        (.green,  .yellow, [.greenNoPush, .greenNoPush, .greenNoPush, .greenNoPush]),
        (.green,  .red,    [.greenNoPush, .greenNoPush, .greenNoPush, .greenNoPush]),
        (.green,  nil,     [.greenNoPush, .greenNoPush, .greenNoPush, .greenNoPush]),
        // yellow action
        (.yellow, .green,  [.yellowLoad, .yellowLoadMinorDrivers, .yellowLoadMinorDrivers, .yellowLoadMinorDrivers]),  // CHANGED for >= 1
        (.yellow, .yellow, [.yellowLoad, .yellowIsolated, .yellowCluster, .yellowCluster]),
        (.yellow, .red,    [.yellowLoad, .yellowIsolated, .yellowCluster, .yellowCluster]),
        (.yellow, nil,     [.yellowLoad, .yellowIsolated, .yellowCluster, .yellowCluster]),
        // red action: load-origin red only when the recovery-only verdict is green
        (.red,    .green,  [.redLoad, .redLoad, .redLoad, .redLoad]),
        (.red,    .yellow, [.red, .red, .red, .red]),
        (.red,    .red,    [.red, .red, .red, .red]),
        (.red,    nil,     [.red, .red, .red, .red]),
    ]

    func testRoutingMatrix() {
        for row in table {
            for negatives in 0...3 {
                let r = card(action: row.action, recovery: row.recovery, negatives: negatives)
                XCTAssertEqual(
                    r.resolveMessageState(manual: manualOff), row.expected[negatives],
                    "action=\(row.action) recovery=\(String(describing: row.recovery)) negatives=\(negatives)"
                )
            }
        }
    }

    func testMatrixCoversEveryActionRecoveryCombination() {
        XCTAssertEqual(table.count, 12)
    }

    // MARK: (b) Precedence: sick and pain >= 7 beat the new routing

    func testSickBeatsYellowLoadMinorDrivers() {
        let r = card(action: .yellow, recovery: .green, negatives: 2)
        XCTAssertEqual(r.resolveMessageState(manual: ManualReadinessInputs(painLevel: 0, isSick: true)), .sick)
    }

    func testHighPainBeatsYellowLoadMinorDrivers() {
        let r = card(action: .yellow, recovery: .green, negatives: 2)
        XCTAssertEqual(r.resolveMessageState(manual: ManualReadinessInputs(painLevel: 7, isSick: false)), .highPain)
        XCTAssertEqual(r.resolveMessageState(manual: ManualReadinessInputs(painLevel: 6, isSick: false)),
                       .yellowLoadMinorDrivers, "pain 6 is below the override threshold")
    }

    func testSickKeepsWarnRowsOnAYellowGreenRecoveryCard() {
        let r = card(action: .yellow, recovery: .green, negatives: 2)
        let sick = ManualReadinessInputs(painLevel: 0, isSick: true)
        XCTAssertEqual(r.driverDisplays(manual: sick).map(\.sentiment), [.warn, .warn])
    }

    // MARK: (c) Copy

    private let existingYellowLoadBody =
        "Recovery signals look fine — today’s training and activity load is what’s pulling readiness down. Run a controlled session and avoid stacking more cost on top."

    func testZeroNegativeBodyIsByteForByteTheExistingYellowLoadCopy() {
        let p = card(action: .yellow, recovery: .green, negatives: 0).presentation(manual: manualOff)
        XCTAssertEqual(p.headline, "Train with guardrails")
        XCTAssertEqual(p.subline, "Load is elevated")
        XCTAssertEqual(p.explanation, existingYellowLoadBody)
        XCTAssertEqual(p.driverLine, "Driver: Elevated training load")
    }

    private func body(_ negatives: Int, confidence: ReadinessConfidence = .high) -> String {
        card(action: .yellow, recovery: .green, negatives: negatives, confidence: confidence)
            .presentation(manual: manualOff).explanation
    }

    private func expectedBody(names: String, verb: String) -> String {
        "Today’s training and activity load is what’s pulling readiness down. Recovery is within range, though \(names) \(verb) a bit off. Run a controlled session and avoid stacking more cost on top."
    }

    func testOneNegativeNamesItWithIs() {
        XCTAssertEqual(body(1), expectedBody(names: "HRV", verb: "is"))
    }

    func testTwoNegativesNameBothWithAreInDisplayOrder() {
        XCTAssertEqual(body(2), expectedBody(names: "HRV and Sleep", verb: "are"))
    }

    func testThreeNegativesUseCommaThenAndWithAre() {
        XCTAssertEqual(body(3), expectedBody(names: "HRV, Sleep and RHR", verb: "are"))
    }

    func testNamesComeFromNegativeDriversOnlyInDisplayOrder() {
        var r = card(action: .yellow, recovery: .green, negatives: 0)
        r.drivers = [driver("RHR", negative: false), driver("Sleep", negative: true),
                     driver("HRV", negative: true)]
        XCTAssertEqual(r.presentation(manual: manualOff).explanation,
                       expectedBody(names: "Sleep and HRV", verb: "are"))
    }

    func testNewBodyDoesNotClaimRecoveryIsFineOrCompromised() {
        for n in 1...3 {
            XCTAssertFalse(body(n).contains("Recovery signals look fine"), body(n))
            XCTAssertFalse(body(n).contains("compromised"), body(n))
        }
    }

    func testHeadlineSublineAndDriverLineMatchYellowLoad() {
        for n in 1...3 {
            let p = card(action: .yellow, recovery: .green, negatives: n).presentation(manual: manualOff)
            XCTAssertEqual(p.headline, "Train with guardrails")
            XCTAssertEqual(p.subline, "Load is elevated")
            XCTAssertEqual(p.driverLine, "Driver: Elevated training load")
            XCTAssertEqual(p.guidanceButtonTitle, "View training guidance")
        }
    }

    func testConfidenceSuffixStillAppendedOnMediumAndLow() {
        let base = expectedBody(names: "HRV", verb: "is")
        XCTAssertEqual(body(1, confidence: .high), base)
        XCTAssertEqual(body(1, confidence: .medium),
                       base + " Some signals are mixed, so treat this as a directional read, not absolute.")
        XCTAssertEqual(body(1, confidence: .low),
                       base + " Data is limited or inconsistent today. Lean more on how you actually feel.")
    }

    func testUnchangedStatesKeepTheirCopy() {
        // yellow / recovery yellow with one negative: still the isolated recovery copy.
        let iso = card(action: .yellow, recovery: .yellow, negatives: 1).presentation(manual: manualOff)
        XCTAssertEqual(iso.subline, "Do not push today")
        XCTAssertEqual(iso.explanation, "HRV is down without a broader recovery collapse. Train with guardrails and avoid pushing.")
        // yellow / recovery nil with two negatives: still the cluster recovery copy.
        let cl = card(action: .yellow, recovery: nil, negatives: 2).presentation(manual: manualOff)
        XCTAssertEqual(cl.subline, "Reduce effort today")
        // red / green: unchanged redLoad copy.
        let rl = card(action: .red, recovery: .green, negatives: 2).presentation(manual: manualOff)
        XCTAssertEqual(rl.headline, "Heavy load today")
        XCTAssertEqual(rl.subline, "Recovery signals are within range")
        // red / red: unchanged recovery-red copy.
        let rr = card(action: .red, recovery: .red, negatives: 2).presentation(manual: manualOff)
        XCTAssertEqual(rr.subline, "Recovery is compromised")
    }

    // MARK: (d) Driver-row styling

    func testNewStateNegativeRowsAreCalmAndPositivesUnchanged() {
        var r = card(action: .yellow, recovery: .green, negatives: 0)
        r.drivers = [driver("HRV", negative: true), driver("Sleep", negative: true),
                     driver("RHR", negative: false)]
        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .yellowLoadMinorDrivers)
        XCTAssertEqual(r.driverDisplays(manual: manualOff).map(\.sentiment), [.calm, .calm, .positive])
    }

    func testRecoveryYellowNegativeRowsAreStillWarn() {
        for state in [(1, ReadinessMessageState.yellowIsolated), (2, .yellowCluster)] {
            let r = card(action: .yellow, recovery: .yellow, negatives: state.0)
            XCTAssertEqual(r.resolveMessageState(manual: manualOff), state.1)
            XCTAssertTrue(r.driverDisplays(manual: manualOff).allSatisfy { $0.sentiment == .warn },
                          "\(state.1)")
        }
        // recovery nil behaves the same
        XCTAssertTrue(card(action: .yellow, recovery: nil, negatives: 2)
            .driverDisplays(manual: manualOff).allSatisfy { $0.sentiment == .warn })
    }

    func testYellowLoadHasNoNegativeRows() {
        var r = card(action: .yellow, recovery: .green, negatives: 0)
        r.drivers = drivers(negatives: 0, total: 2)     // two positive rows, no negative rows
        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .yellowLoad)
        XCTAssertEqual(r.driverDisplays(manual: manualOff).map(\.sentiment), [.positive, .positive])
    }

    func testRedLoadStylingUnchanged() {
        let r = card(action: .red, recovery: .green, negatives: 2)
        XCTAssertEqual(r.driverDisplays(manual: manualOff).map(\.sentiment), [.calm, .calm])
    }

    func testGreenAndRedRecoveryStylingUnchanged() {
        XCTAssertTrue(card(action: .green, recovery: .green, negatives: 2)
            .driverDisplays(manual: manualOff).allSatisfy { $0.sentiment == .calm })
        XCTAssertTrue(card(action: .red, recovery: .red, negatives: 2)
            .driverDisplays(manual: manualOff).allSatisfy { $0.sentiment == .warn })
    }

    // MARK: (e) Fixtures mirroring real device output

    func testFixture_2026_09_28_YellowGreenRecoverySleepNegativeRHRPositive() {
        var r = ReadinessResult.empty
        r.truth = .yellow
        r.rawTruth = .yellow
        r.action = .yellow
        r.rawRecoveryTruth = .green
        r.confidence = .high
        r.drivers = [driver("Sleep", negative: true), driver("RHR", negative: false)]

        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .yellowLoadMinorDrivers)
        let p = r.presentation(manual: manualOff)
        XCTAssertEqual(p.headline, "Train with guardrails")
        XCTAssertEqual(p.subline, "Load is elevated")
        XCTAssertTrue(p.explanation.contains("though Sleep is a bit off."), p.explanation)
        XCTAssertEqual(r.driverDisplays(manual: manualOff).map(\.sentiment), [.calm, .positive])
    }

    func testFixture_2026_09_29_RedGreenRecoveryHRVAndRespiratoryRateNegativeIsUnchangedRedLoad() {
        var r = ReadinessResult.empty
        r.truth = .red
        r.rawTruth = .red
        r.action = .red
        r.rawRecoveryTruth = .green
        r.confidence = .high
        r.drivers = [driver("HRV", negative: true), driver("Respiratory Rate", negative: true)]

        XCTAssertEqual(r.resolveMessageState(manual: manualOff), .redLoad)
        let p = r.presentation(manual: manualOff)
        XCTAssertEqual(p.headline, "Heavy load today")
        XCTAssertEqual(p.subline, "Recovery signals are within range")
        XCTAssertEqual(r.driverDisplays(manual: manualOff).map(\.sentiment), [.calm, .calm])
    }

    // MARK: (f) The logged state string

    // VerdictResultCapture (diagnostic branch) logs `String(describing: resolveMessageState(...))`, so the
    // string is the case name. This branch predates that file, so the string is asserted directly.
    func testMessageStateStringIsTheCaseName() {
        let r = card(action: .yellow, recovery: .green, negatives: 1)
        XCTAssertEqual(String(describing: r.resolveMessageState(manual: manualOff)), "yellowLoadMinorDrivers")
        XCTAssertEqual(String(describing: ReadinessMessageState.yellowLoad), "yellowLoad")
    }

    // MARK: Copy helper

    func testJoinedNames() {
        XCTAssertEqual(ReadinessLoadMinorDriversCopy.joinedNames([]), "")
        XCTAssertEqual(ReadinessLoadMinorDriversCopy.joinedNames(["Sleep"]), "Sleep")
        XCTAssertEqual(ReadinessLoadMinorDriversCopy.joinedNames(["HRV", "Sleep"]), "HRV and Sleep")
        XCTAssertEqual(ReadinessLoadMinorDriversCopy.joinedNames(["HRV", "Sleep", "RHR"]), "HRV, Sleep and RHR")
    }

    // MARK: Codable round trip keeps the routing

    func testRoutingSurvivesCodableRoundTrip() throws {
        let r = card(action: .yellow, recovery: .green, negatives: 1)
        let decoded = try JSONDecoder().decode(ReadinessResult.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded.resolveMessageState(manual: manualOff), .yellowLoadMinorDrivers)
    }
}
