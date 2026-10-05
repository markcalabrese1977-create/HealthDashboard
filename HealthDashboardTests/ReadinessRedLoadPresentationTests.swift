import XCTest
@testable import HealthDashboard

// .redLoad: action == .red AND rawRecoveryTruth == .green → copy attributes the red to load.
// Sick / high-pain keep priority; nil rawRecoveryTruth falls back to the recovery-red copy.
final class ReadinessRedLoadPresentationTests: XCTestCase {

    private func driver(_ label: String, isNegative: Bool = true) -> ReadinessDriver {
        ReadinessDriver(label: label, impact: 1, isNegative: isNegative,
                        reason: "Off from baseline.", consecutiveDays: 0)
    }

    private func redCard(recovery: ReadinessStatus?,
                         drivers: [ReadinessDriver] = []) -> ReadinessResult {
        var r = ReadinessResult.empty
        r.truth = .red
        r.rawTruth = .red
        r.action = .red
        r.rawRecoveryTruth = recovery
        r.drivers = drivers
        return r
    }

    private let recoveryRedSubline = "Recovery is compromised"

    // MARK: State selection

    func testRedWithRecoveryGreenIsRedLoad() {
        let r = redCard(recovery: .green)
        XCTAssertEqual(r.resolveMessageState(manual: .default), .redLoad)

        let p = r.presentation(manual: .default)
        XCTAssertEqual(p.headline, "Heavy load today")
        XCTAssertEqual(p.subline, "Recovery signals are within range")
        XCTAssertTrue(p.explanation.hasPrefix(
            "Today’s training pushed load well above your usual. The red reflects load, not recovery. Keep the rest of today easy."),
            p.explanation)
        XCTAssertFalse(p.subline.contains(recoveryRedSubline))
    }

    func testRedWithRecoveryRedStaysRed() {
        let r = redCard(recovery: .red)
        XCTAssertEqual(r.resolveMessageState(manual: .default), .red)

        let p = r.presentation(manual: .default)
        XCTAssertEqual(p.headline, "Reduce cost today")
        XCTAssertEqual(p.subline, recoveryRedSubline)
    }

    func testRedWithRecoveryYellowStaysRed() {
        let r = redCard(recovery: .yellow)
        XCTAssertEqual(r.resolveMessageState(manual: .default), .red)
        XCTAssertEqual(r.presentation(manual: .default).subline, recoveryRedSubline)
    }

    func testRedWithNilRecoveryTruthFallsBackToRed() {
        let r = redCard(recovery: nil)
        XCTAssertEqual(r.resolveMessageState(manual: .default), .red)

        let p = r.presentation(manual: .default)
        XCTAssertEqual(p.headline, "Reduce cost today")
        XCTAssertEqual(p.subline, recoveryRedSubline)
    }

    func testSickOverridesRedLoad() {
        let r = redCard(recovery: .green)
        let manual = ManualReadinessInputs(painLevel: 0, isSick: true)
        XCTAssertEqual(r.resolveMessageState(manual: manual), .sick)
        XCTAssertEqual(r.presentation(manual: manual).subline, "Sickness is active")
    }

    func testHighPainOverridesRedLoad() {
        let r = redCard(recovery: .green)
        let manual = ManualReadinessInputs(painLevel: 8, isSick: false)
        XCTAssertEqual(r.resolveMessageState(manual: manual), .highPain)
        XCTAssertEqual(r.presentation(manual: manual).subline, "Pain is high")
    }

    func testNonRedActionIgnoresRawRecoveryTruth() {
        var r = redCard(recovery: .green)
        r.action = .yellow
        r.truth = .yellow
        r.rawTruth = .yellow
        XCTAssertNotEqual(r.resolveMessageState(manual: .default), .redLoad)
    }

    // MARK: Driver-row tone

    func testRedLoadNegativeDriverRowsAreNeutralNotWarn() {
        let r = redCard(recovery: .green, drivers: [driver("Pain"), driver("HRV"), driver("RHR", isNegative: false)])
        let displays = r.driverDisplays(manual: .default)
        XCTAssertEqual(displays.map(\.sentiment), [.calm, .calm, .positive])
        XCTAssertFalse(displays.contains { $0.sentiment == .warn })
    }

    func testRecoveryRedDriverRowsStayWarn() {
        let r = redCard(recovery: .red, drivers: [driver("HRV"), driver("RHR")])
        XCTAssertEqual(r.driverDisplays(manual: .default).map(\.sentiment), [.warn, .warn])
    }

    func testNilRecoveryTruthDriverRowsStayWarn() {
        let r = redCard(recovery: nil, drivers: [driver("HRV")])
        XCTAssertEqual(r.driverDisplays(manual: .default).map(\.sentiment), [.warn])
    }

    func testSickKeepsWarnRowsEvenWhenRecoveryTruthGreen() {
        let r = redCard(recovery: .green, drivers: [driver("Sick"), driver("HRV")])
        let manual = ManualReadinessInputs(painLevel: 0, isSick: true)
        XCTAssertEqual(r.driverDisplays(manual: manual).map(\.sentiment), [.warn, .warn])
    }

    // MARK: End to end through the engine

    func testEngineLoadCausedRedProducesRedLoadCard() throws {
        let fixture = try XCTUnwrap(ReadinessParityTests.fixtures.first { $0.name == "red_load_recovery_green" })
        UserDefaults(suiteName: SharedStore.appGroupID)?.removeObject(forKey: SharedStore.verdictLogKey)

        let r = ReadinessEngine.evaluate(history: fixture.history, manual: fixture.manual)
        XCTAssertEqual(r.action, .red)
        XCTAssertEqual(r.rawRecoveryTruth, .green)
        XCTAssertEqual(r.presentation(manual: fixture.manual).headline, "Heavy load today")
    }

    func testEngineRecoveryCausedRedKeepsRedCopy() throws {
        let fixture = try XCTUnwrap(ReadinessParityTests.fixtures.first { $0.name == "red_recovery_cluster" })
        UserDefaults(suiteName: SharedStore.appGroupID)?.removeObject(forKey: SharedStore.verdictLogKey)

        let r = ReadinessEngine.evaluate(history: fixture.history, manual: fixture.manual)
        XCTAssertEqual(r.action, .red)
        XCTAssertEqual(r.rawRecoveryTruth, .red)
        XCTAssertEqual(r.presentation(manual: fixture.manual).subline, recoveryRedSubline)
    }

    // MARK: Codable

    func testRawRecoveryTruthSurvivesCodableRoundTrip() throws {
        let r = redCard(recovery: .green)
        let decoded = try JSONDecoder().decode(ReadinessResult.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded.rawRecoveryTruth, .green)
        XCTAssertEqual(decoded.resolveMessageState(manual: .default), .redLoad)
    }
}
