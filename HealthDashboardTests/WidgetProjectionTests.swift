import XCTest
@testable import HealthDashboard

// MARK: - WidgetProjection round-trip

final class WidgetProjectionTests: XCTestCase {

    func testWidgetProjectionRoundTripsThroughSaveAndLoad() {
        let projection = WidgetProjection(
            truth: .yellow,
            flagCount: 3,
            rhr: 64,
            hrv: 41,
            sleepHours: 7.2,
            rhrSeries: [65, 64, nil, 63],   // nil preserved — Sparkline gap, not a zero
            hrvSeries: [40, 41, 42, nil],
            sleepSeries: [7.5, nil, 7.0, 7.2],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        SharedStore.saveWidgetProjection(projection)
        let decoded = SharedStore.loadWidgetProjection()

        XCTAssertEqual(decoded, projection)
    }

    func testLoadWidgetProjectionReturnsNilWhenNothingWritten() {
        // Clear the key so this test doesn't depend on ordering/state left by other tests.
        let d = UserDefaults(suiteName: SharedStore.appGroupID)
        d?.removeObject(forKey: SharedStore.widgetProjectionKey)

        XCTAssertNil(SharedStore.loadWidgetProjection())
    }

    // MARK: - appendVerdictLog main-app guard
    //
    // HealthDashboardTests is host-app-hosted (TEST_HOST = HealthDashboard.app in
    // project.pbxproj), so Bundle.main inside this test process resolves to the MAIN
    // APP's bundle identifier, not the test bundle's own id — there is no way, from
    // this unit test host, to make Bundle.main report the widget extension's id
    // (com.calabrese.HealthDashboard.HealthDashboardWidget) and exercise the blocked
    // branch of appendVerdictLog. That branch is device/extension-verified only: run
    // the widget extension on a simulator/device and confirm (a) no new row appears in
    // health.readiness.verdictLog.v1 attributable to a widget-triggered evaluate(), and
    // (b) the "⛔️ appendVerdictLog blocked" log line appears in the widget extension's
    // os_log stream (subsystem "com.calabrese.HealthDashboard", category "SharedStore").
    //
    // What IS testable here is the non-blocking path: confirm the guard does not
    // regress the main-app write behavior it already had.
    func testAppendVerdictLogWritesWhenCalledFromMainAppHost() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.calabrese.HealthDashboard",
                       "sanity check: this test host's Bundle.main is the app, not the test bundle")

        let record = DailyVerdictRecord(
            dateISO: "2026-09-07",
            rawTotal: 5,
            rawRecovery: 5,
            rawTruth: .green,
            rawRecoveryTruth: .green
        )

        SharedStore.appendVerdictLog(record)

        let log = SharedStore.loadVerdictLog()
        XCTAssertTrue(log.contains(where: { $0.dateISO == "2026-09-07" && $0.rawTruth == .green }))
    }
}
