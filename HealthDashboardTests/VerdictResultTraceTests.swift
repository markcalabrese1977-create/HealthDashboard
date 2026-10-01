import XCTest
@testable import HealthDashboard

/// Covers the post-evaluate result record: Codable round trip, suppression against a real
/// temp file (never the App Group container), and the pure entry builder.
final class VerdictResultTraceTests: XCTestCase {

    private static let base = Date(timeIntervalSince1970: 1_780_000_000)

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdict-result-trace-test-\(UUID().uuidString).jsonl")
        VerdictWriteTrace.resetResultSuppression()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        VerdictWriteTrace.resetResultSuppression()
        super.tearDown()
    }

    private func entry(
        site: String = "hkObserver",
        offset: TimeInterval = 0,
        evalDayISO: String = "2026-09-29",
        action: ReadinessStatus = .yellow,
        rawRecoveryTruth: ReadinessStatus? = .green,
        confidence: ReadinessConfidence? = .high,
        messageState: String? = "yellowLoad",
        negativeDriverCount: Int? = nil,
        drivers: [VerdictResultDriver]? = [VerdictResultDriver(label: "HRV", isNegative: true, sentiment: "calm")],
        hrvFallback: Bool? = false,
        sleepWindowEnd: Date? = Date(timeIntervalSince1970: 1_779_990_000)
    ) -> VerdictResultEntry {
        VerdictResultEntry(
            writtenAt: Self.base.addingTimeInterval(offset),
            site: site,
            evalDayISO: evalDayISO,
            action: action,
            rawRecoveryTruth: rawRecoveryTruth,
            confidence: confidence,
            messageState: messageState,
            negativeDriverCount: negativeDriverCount,
            drivers: drivers,
            hrvFallback: hrvFallback,
            sleepWindowEnd: sleepWindowEnd
        )
    }

    private func lineCount() -> Int {
        VerdictWriteTrace.loadResultEntries(from: tempURL).count
    }

    // MARK: - Round trip

    private func roundTrip(_ e: VerdictResultEntry, file: StaticString = #filePath, line: UInt = #line) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(VerdictResultEntry.self, from: enc.encode(e))
        XCTAssertEqual(back, e, file: file, line: line)
    }

    func testRoundTripWithAllOptionals() throws {
        try roundTrip(entry(negativeDriverCount: 1))
    }

    func testRoundTripWithoutOptionals() throws {
        try roundTrip(entry(
            rawRecoveryTruth: nil, confidence: nil, messageState: nil,
            negativeDriverCount: nil, drivers: nil, hrvFallback: nil, sleepWindowEnd: nil
        ))
    }

    func testSleepWindowEndEncodesAsISOString() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let json = String(decoding: try enc.encode(entry()), as: UTF8.self)
        XCTAssertTrue(json.contains("\"sleepWindowEnd\":\"20"), json)
    }

    // MARK: - Suppression

    func testIdenticalConsecutiveEntriesWriteOneLine() {
        VerdictWriteTrace.recordResult(entry(offset: 0), to: tempURL)
        VerdictWriteTrace.recordResult(entry(offset: 1), to: tempURL)
        VerdictWriteTrace.recordResult(entry(offset: 2), to: tempURL)
        XCTAssertEqual(lineCount(), 1)
    }

    func testSamePayloadDifferentSiteWritesOneLineKeepingFirstSite() {
        VerdictWriteTrace.recordResult(entry(site: "hkObserver", offset: 0), to: tempURL)
        VerdictWriteTrace.recordResult(entry(site: "onAppear", offset: 5), to: tempURL)

        let lines = VerdictWriteTrace.loadResultEntries(from: tempURL)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.site, "hkObserver")
        XCTAssertEqual(lines.first?.writtenAt.timeIntervalSince1970 ?? 0,
                       Self.base.timeIntervalSince1970, accuracy: 1)
    }

    func testAnyFieldChangeWritesASecondLine() {
        let variants: [VerdictResultEntry] = [
            entry(evalDayISO: "2026-09-30"),
            entry(action: .red),
            entry(rawRecoveryTruth: .yellow),
            entry(confidence: .low),
            entry(messageState: "yellowIsolated"),
            entry(negativeDriverCount: 2),
            entry(drivers: []),
            entry(hrvFallback: true),
            entry(sleepWindowEnd: nil),
        ]
        for (i, changed) in variants.enumerated() {
            VerdictWriteTrace.resetResultSuppression()
            try? FileManager.default.removeItem(at: tempURL)
            VerdictWriteTrace.recordResult(entry(), to: tempURL)
            VerdictWriteTrace.recordResult(changed, to: tempURL)
            XCTAssertEqual(lineCount(), 2, "variant \(i) should not be suppressed")
        }
    }

    func testChangeAndRevertWritesThreeLines() {
        // Suppression compares only to the LAST written payload, not to all history.
        VerdictWriteTrace.recordResult(entry(action: .yellow), to: tempURL)
        VerdictWriteTrace.recordResult(entry(action: .red), to: tempURL)
        VerdictWriteTrace.recordResult(entry(action: .yellow), to: tempURL)
        XCTAssertEqual(lineCount(), 3)
    }

    func testDeletedFileDoesNotSwallowNextEntry() {
        VerdictWriteTrace.recordResult(entry(), to: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        VerdictWriteTrace.recordResult(entry(), to: tempURL)
        XCTAssertEqual(lineCount(), 1)
    }

    // MARK: - Entry builder

    private func point(hrv: Double?, windowHRV: Double?, end: Date? = nil) -> DailyHealthPoint {
        DailyHealthPoint(
            dayISO: "2026-09-29",
            hrvMS: hrv,
            sleepWindowHRV: windowHRV,
            sleepWindowEnd: end
        )
    }

    func testBuilderRecordsActionMessageStateAndHRVSource() {
        var r = ReadinessResult.empty
        r.action = .yellow
        r.rawRecoveryTruth = .green
        r.confidence = .high

        let end = Date(timeIntervalSince1970: 1_779_990_000)
        let e = VerdictWriteTrace.makeResultEntry(
            result: r, site: "hkObserver",
            history: [point(hrv: 40, windowHRV: nil, end: end)],
            manual: .default
        )

        XCTAssertEqual(e.action, .yellow)
        XCTAssertEqual(e.rawRecoveryTruth, .green)
        XCTAssertEqual(e.messageState, "yellowLoad")      // no negative drivers → load copy
        XCTAssertNil(e.negativeDriverCount)
        XCTAssertEqual(e.drivers?.count, 0)
        XCTAssertEqual(e.hrvFallback, true)               // hrvMS present, sleep-window absent
        XCTAssertEqual(e.sleepWindowEnd, end)
        XCTAssertEqual(e.evalDayISO, "2026-09-29")
    }

    func testBuilderHRVFallbackNilCases() {
        let r = ReadinessResult.empty
        let noHRV = VerdictWriteTrace.makeResultEntry(
            result: r, site: "onAppear", history: [point(hrv: nil, windowHRV: nil)], manual: .default)
        XCTAssertNil(noHRV.hrvFallback)

        let empty = VerdictWriteTrace.makeResultEntry(
            result: r, site: "onAppear", history: [], manual: .default)
        XCTAssertNil(empty.hrvFallback)
        XCTAssertNil(empty.sleepWindowEnd)
        XCTAssertEqual(empty.evalDayISO, VerdictWriteTrace.resultNoEvalDay)

        let sleepWindow = VerdictWriteTrace.makeResultEntry(
            result: r, site: "onAppear", history: [point(hrv: 40, windowHRV: 41)], manual: .default)
        XCTAssertEqual(sleepWindow.hrvFallback, false)
    }

    func testBuilderCapturesDriverSentiment() {
        var r = ReadinessResult.empty
        r.action = .yellow
        r.drivers = [ReadinessDriver(label: "HRV", impact: 1, isNegative: true, reason: "", consecutiveDays: 1)]

        let e = VerdictWriteTrace.makeResultEntry(
            result: r, site: "postBackfill", history: [point(hrv: 40, windowHRV: 41)], manual: .default)

        XCTAssertEqual(e.messageState, "yellowIsolated")
        XCTAssertEqual(e.drivers?.first?.label, "HRV")
        XCTAssertEqual(e.drivers?.first?.isNegative, true)
        XCTAssertEqual(e.drivers?.first?.sentiment, "warn")   // action yellow, not load-origin red
    }

    func testWeeklySummarySiteIsNotARecordedSite() {
        XCTAssertFalse(VerdictWriteTrace.resultTraceSites.contains("weeklySummary:2026-09-29"))
        XCTAssertEqual(VerdictWriteTrace.resultTraceSites,
                       ["onAppear", "manualEdit", "postBackfill", "hkObserver"])
    }
}
