import XCTest
@testable import HealthDashboard

/// Covers the pure parts of VerdictWriteTrace only — `summarize(entries:)` and the
/// retention predicate it shares with the read path. Nothing here touches the App Group
/// container, so these tests never depend on (or disturb) a real trace file.
final class VerdictWriteTraceTests: XCTestCase {

    // MARK: - Helpers

    private static let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func entry(
        _ dateISO: String,
        site: String?,
        offsetSeconds: TimeInterval,
        rawTotal: Int = 0,
        rawRecovery: Int? = nil,
        rawTruth: ReadinessStatus = .green,
        rawRecoveryTruth: ReadinessStatus = .green,
        historyLastDayISO: String? = nil,
        historyCount: Int? = nil,
        overwrote: Bool = false,
        priorRawTotal: Int? = nil,
        priorRawRecovery: Int? = nil,
        writtenAt: Date? = nil
    ) -> VerdictTraceEntry {
        VerdictTraceEntry(
            writtenAt: writtenAt ?? Self.base.addingTimeInterval(offsetSeconds),
            dateISO: dateISO,
            site: site,
            historyLastDayISO: historyLastDayISO,
            historyCount: historyCount,
            rawTotal: rawTotal,
            rawRecovery: rawRecovery,
            rawTruth: rawTruth,
            rawRecoveryTruth: rawRecoveryTruth,
            overwrote: overwrote,
            priorRawTotal: priorRawTotal,
            priorRawRecovery: priorRawRecovery
        )
    }

    // MARK: - Multiple sites on one day

    func testMultipleSitesOnOneDayAreCountedPerSite() {
        let entries = [
            entry("2026-09-28", site: "onAppear", offsetSeconds: 0, rawTotal: -2),
            entry("2026-09-28", site: "weeklySummary:2026-09-24", offsetSeconds: 10, rawTotal: -6),
            entry("2026-09-28", site: "weeklySummary:2026-09-25", offsetSeconds: 20, rawTotal: -4),
            entry("2026-09-28", site: "postBackfill", offsetSeconds: 30, rawTotal: 1),
        ]

        let summaries = VerdictWriteTrace.summarize(entries: entries)

        XCTAssertEqual(summaries.count, 1)
        let s = summaries[0]
        XCTAssertEqual(s.dateISO, "2026-09-28")
        XCTAssertEqual(s.totalWrites, 4)
        XCTAssertEqual(s.writesPerSite["onAppear"], 1)
        XCTAssertEqual(s.writesPerSite["weeklySummary:2026-09-24"], 1)
        XCTAssertEqual(s.writesPerSite["weeklySummary:2026-09-25"], 1)
        XCTAssertEqual(s.writesPerSite["postBackfill"], 1)
        XCTAssertEqual(s.writesPerSite.count, 4)

        XCTAssertEqual(s.firstWrittenAt, Self.base)
        XCTAssertEqual(s.lastWrittenAt, Self.base.addingTimeInterval(30))
        XCTAssertEqual(s.minRawTotal, -6)
        XCTAssertEqual(s.maxRawTotal, 1)
    }

    func testRepeatedSiteAccumulatesIntoOneBucket() {
        let entries = (0..<5).map {
            entry("2026-09-28", site: "manualEdit", offsetSeconds: Double($0))
        }

        let s = VerdictWriteTrace.summarize(entries: entries)[0]

        XCTAssertEqual(s.totalWrites, 5)
        XCTAssertEqual(s.writesPerSite, ["manualEdit": 5])
    }

    func testEntriesAreGroupedAndSortedByDate() {
        let entries = [
            entry("2026-09-28", site: "onAppear", offsetSeconds: 0),
            entry("2026-09-26", site: "onAppear", offsetSeconds: 1),
            entry("2026-09-27", site: "onAppear", offsetSeconds: 2),
        ]

        let dates = VerdictWriteTrace.summarize(entries: entries).map { $0.dateISO }

        XCTAssertEqual(dates, ["2026-09-26", "2026-09-27", "2026-09-28"])
    }

    func testNilSiteBucketsAsUnattributed() {
        let entries = [
            entry("2026-09-28", site: nil, offsetSeconds: 0),
            entry("2026-09-28", site: "onAppear", offsetSeconds: 1),
        ]

        let s = VerdictWriteTrace.summarize(entries: entries)[0]

        XCTAssertEqual(s.writesPerSite[VerdictWriteTrace.unattributedSite], 1)
        XCTAssertEqual(s.writesPerSite["onAppear"], 1)
    }

    // MARK: - Overwrite tracking / final surviving entry

    func testFinalEntryIsTheLastWriteAndOwnsTheDay() {
        let entries = [
            entry("2026-09-28", site: "onAppear", offsetSeconds: 0, rawTotal: -2, overwrote: false),
            entry("2026-09-28", site: "weeklySummary:2026-09-28", offsetSeconds: 10,
                  rawTotal: -6, overwrote: true, priorRawTotal: -2),
            entry("2026-09-28", site: "postBackfill", offsetSeconds: 20,
                  rawTotal: 1, overwrote: true, priorRawTotal: -6),
        ]

        let s = VerdictWriteTrace.summarize(entries: entries)[0]

        XCTAssertEqual(s.finalEntry.site, "postBackfill")
        XCTAssertEqual(s.finalEntry.rawTotal, 1)
        XCTAssertTrue(s.finalEntry.overwrote)
        XCTAssertEqual(s.finalEntry.priorRawTotal, -6)
    }

    func testFinalEntryUsesWrittenAtNotInputOrder() {
        // Handed in out of chronological order — the newest write still owns the day.
        let entries = [
            entry("2026-09-28", site: "postBackfill", offsetSeconds: 30, rawTotal: 1),
            entry("2026-09-28", site: "onAppear", offsetSeconds: 0, rawTotal: -2),
        ]

        let s = VerdictWriteTrace.summarize(entries: entries)[0]

        XCTAssertEqual(s.finalEntry.site, "postBackfill")
        XCTAssertEqual(s.firstWrittenAt, Self.base)
        XCTAssertEqual(s.lastWrittenAt, Self.base.addingTimeInterval(30))
    }

    func testTiedTimestampsBreakByInputOrderSoOwnerIsDeterministic() {
        let sameInstant = Self.base
        let entries = [
            entry("2026-09-28", site: "first", offsetSeconds: 0, rawTotal: 1, writtenAt: sameInstant),
            entry("2026-09-28", site: "second", offsetSeconds: 0, rawTotal: 2, writtenAt: sameInstant),
            entry("2026-09-28", site: "third", offsetSeconds: 0, rawTotal: 3, writtenAt: sameInstant),
        ]

        let s = VerdictWriteTrace.summarize(entries: entries)[0]

        XCTAssertEqual(s.finalEntry.site, "third")
        XCTAssertEqual(s.finalEntry.rawTotal, 3)
    }

    func testRawRecoveryRangeIgnoresNilsAndIsNilWhenNonePresent() {
        let withSome = [
            entry("2026-09-28", site: "a", offsetSeconds: 0, rawRecovery: nil),
            entry("2026-09-28", site: "b", offsetSeconds: 1, rawRecovery: -5),
            entry("2026-09-28", site: "c", offsetSeconds: 2, rawRecovery: 3),
        ]
        let s1 = VerdictWriteTrace.summarize(entries: withSome)[0]
        XCTAssertEqual(s1.minRawRecovery, -5)
        XCTAssertEqual(s1.maxRawRecovery, 3)

        let withNone = [
            entry("2026-09-27", site: "a", offsetSeconds: 0, rawRecovery: nil),
            entry("2026-09-27", site: "b", offsetSeconds: 1, rawRecovery: nil),
        ]
        let s2 = VerdictWriteTrace.summarize(entries: withNone)[0]
        XCTAssertNil(s2.minRawRecovery)
        XCTAssertNil(s2.maxRawRecovery)
    }

    // MARK: - First full-history detection

    func testFirstFullHistoryEntryIsEarliestWriteWhoseHistoryReachesTheDay() {
        // The weekly-summary loop evaluates on truncated history: its historyLastDayISO
        // lags the record's dateISO. Only the real refresh reaches the day itself.
        let entries = [
            entry("2026-09-28", site: "weeklySummary:2026-09-24", offsetSeconds: 0,
                  historyLastDayISO: "2026-09-24", historyCount: 24),
            entry("2026-09-28", site: "weeklySummary:2026-09-26", offsetSeconds: 10,
                  historyLastDayISO: "2026-09-26", historyCount: 26),
            entry("2026-09-28", site: "postBackfill", offsetSeconds: 20,
                  historyLastDayISO: "2026-09-28", historyCount: 28),
            entry("2026-09-28", site: "manualEdit", offsetSeconds: 30,
                  historyLastDayISO: "2026-09-28", historyCount: 28),
        ]

        let s = VerdictWriteTrace.summarize(entries: entries)[0]

        XCTAssertEqual(s.firstFullHistoryEntry?.site, "postBackfill")
        XCTAssertEqual(s.firstFullHistoryEntry?.historyCount, 28)
    }

    func testFirstFullHistoryEntryIsNilWhenEveryWriteRanOnTruncatedHistory() {
        let entries = [
            entry("2026-09-28", site: "weeklySummary:2026-09-24", offsetSeconds: 0,
                  historyLastDayISO: "2026-09-24"),
            entry("2026-09-28", site: "weeklySummary:2026-09-25", offsetSeconds: 10,
                  historyLastDayISO: "2026-09-25"),
        ]

        let s = VerdictWriteTrace.summarize(entries: entries)[0]

        XCTAssertNil(s.firstFullHistoryEntry)
    }

    func testFirstFullHistoryEntryIsNilWhenHistoryContextIsAbsent() {
        let entries = [
            entry("2026-09-28", site: "onAppear", offsetSeconds: 0, historyLastDayISO: nil),
        ]

        let s = VerdictWriteTrace.summarize(entries: entries)[0]

        XCTAssertNil(s.firstFullHistoryEntry)
    }

    // MARK: - Retention trim

    func testRetentionKeepsEntriesInsideTheWindowAndDropsOlderOnes() {
        let now = Self.base
        let day = 24.0 * 60 * 60

        let entries = [
            entry("2026-09-01", site: "old", offsetSeconds: 0, writtenAt: now.addingTimeInterval(-20 * day)),
            entry("2026-09-10", site: "edge-outside", offsetSeconds: 0, writtenAt: now.addingTimeInterval(-15 * day)),
            entry("2026-09-20", site: "inside", offsetSeconds: 0, writtenAt: now.addingTimeInterval(-3 * day)),
            entry("2026-09-28", site: "today", offsetSeconds: 0, writtenAt: now),
        ]

        let kept = VerdictWriteTrace.applyRetention(to: entries, now: now)

        XCTAssertEqual(kept.map { $0.site }, ["inside", "today"])
    }

    func testRetentionBoundaryIsInclusive() {
        let now = Self.base
        let day = 24.0 * 60 * 60
        let exactlyAtCutoff = now.addingTimeInterval(-Double(VerdictWriteTrace.verdictTraceRetentionDays) * day)

        let entries = [entry("2026-09-14", site: "boundary", offsetSeconds: 0, writtenAt: exactlyAtCutoff)]

        XCTAssertEqual(VerdictWriteTrace.applyRetention(to: entries, now: now).count, 1)
    }

    func testRetentionHonoursAnExplicitWindow() {
        let now = Self.base
        let day = 24.0 * 60 * 60
        let entries = [
            entry("2026-09-25", site: "three-days-ago", offsetSeconds: 0, writtenAt: now.addingTimeInterval(-3 * day)),
            entry("2026-09-27", site: "one-day-ago", offsetSeconds: 0, writtenAt: now.addingTimeInterval(-1 * day)),
        ]

        let kept = VerdictWriteTrace.applyRetention(to: entries, now: now, retentionDays: 2)

        XCTAssertEqual(kept.map { $0.site }, ["one-day-ago"])
    }

    func testSummarizeOfEmptyInputIsEmpty() {
        XCTAssertTrue(VerdictWriteTrace.summarize(entries: []).isEmpty)
    }

    // MARK: - Malformed-line tolerance (pure parse)

    private func jsonl(_ entries: [VerdictTraceEntry]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try entries
            .map { String(data: try encoder.encode($0), encoding: .utf8)! }
            .joined(separator: "\n") + "\n"
    }

    func testParseSkipsCorruptLineAndCountsIt() throws {
        let good = [
            entry("2026-09-26", site: "onAppear", offsetSeconds: 0, rawTotal: 1),
            entry("2026-09-27", site: "postBackfill", offsetSeconds: 10, rawTotal: 2),
        ]
        var raw = try jsonl(good)
        raw += "{ this is not valid json at all\n"
        raw += try jsonl([entry("2026-09-28", site: "manualEdit", offsetSeconds: 20, rawTotal: 3)])

        let loaded = VerdictWriteTrace.parse(raw)

        XCTAssertEqual(loaded.malformedLines, 1)
        XCTAssertEqual(loaded.entries.count, 3)
        XCTAssertEqual(loaded.entries.map { $0.rawTotal }, [1, 2, 3])
    }

    func testParseCountsSeveralCorruptLinesIndependently() throws {
        var raw = "not json\n"
        raw += try jsonl([entry("2026-09-28", site: "onAppear", offsetSeconds: 0)])
        raw += "{\"partial\": \n"
        raw += "[]\n"

        let loaded = VerdictWriteTrace.parse(raw)

        XCTAssertEqual(loaded.malformedLines, 3)
        XCTAssertEqual(loaded.entries.count, 1)
    }

    func testParseOfEmptyStringIsEmptyAndClean() {
        let loaded = VerdictWriteTrace.parse("")
        XCTAssertTrue(loaded.entries.isEmpty)
        XCTAssertEqual(loaded.malformedLines, 0)
    }

    // MARK: - Malformed-line tolerance (real file, via the injectable URL)

    func testFileWithOneCorruptLineStillLoadsTheRest() throws {
        let now = Self.base
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdict-trace-corrupt-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        // Written recently enough that retention keeps all three.
        var raw = try jsonl([
            entry("2026-09-26", site: "onAppear", offsetSeconds: 0, rawTotal: 1, writtenAt: now),
            entry("2026-09-27", site: "weeklySummary:2026-09-27", offsetSeconds: 0, rawTotal: -4, writtenAt: now),
        ])
        raw += "}{ truncated mid-write\n"
        raw += try jsonl([
            entry("2026-09-28", site: "postBackfill", offsetSeconds: 0, rawTotal: 5, writtenAt: now),
        ])
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let loaded = VerdictWriteTrace.loadEntries(from: url, now: now)

        XCTAssertEqual(loaded.malformedLines, 1)
        XCTAssertEqual(loaded.entries.count, 3)
        XCTAssertEqual(loaded.entries.map { $0.site },
                       ["onAppear", "weeklySummary:2026-09-27", "postBackfill"])

        // And the summary carries the count through to the reader.
        let summary = VerdictWriteTrace.summarize(
            entries: loaded.entries,
            malformedLines: loaded.malformedLines
        )
        XCTAssertEqual(summary.malformedLines, 1)
        XCTAssertEqual(summary.days.count, 3)
    }

    func testLoadFromMissingFileIsEmptyNotACrash() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdict-trace-absent-\(UUID().uuidString).jsonl")

        let loaded = VerdictWriteTrace.loadEntries(from: url, now: Self.base)

        XCTAssertTrue(loaded.entries.isEmpty)
        XCTAssertEqual(loaded.malformedLines, 0)
    }

    func testRetentionRewriteOnDiskKeepsOnlyEntriesInsideTheWindow() throws {
        let now = Self.base
        let day = 24.0 * 60 * 60
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdict-trace-retention-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let raw = try jsonl([
            entry("2026-09-01", site: "stale", offsetSeconds: 0, writtenAt: now.addingTimeInterval(-30 * day)),
            entry("2026-09-28", site: "fresh", offsetSeconds: 0, writtenAt: now),
        ])
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let first = VerdictWriteTrace.loadEntries(from: url, now: now)
        XCTAssertEqual(first.entries.map { $0.site }, ["fresh"])

        // The stale entry is gone from disk, not merely filtered in memory.
        let second = VerdictWriteTrace.loadEntries(from: url, now: now)
        XCTAssertEqual(second.entries.map { $0.site }, ["fresh"])
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("stale"))
    }

    // MARK: - Concurrent appends are serialized

    func testConcurrentLoadsDoNotDeadlockOrLoseEntries() throws {
        let now = Self.base
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdict-trace-concurrent-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let raw = try jsonl((0..<20).map {
            entry("2026-09-28", site: "site-\($0)", offsetSeconds: Double($0), writtenAt: now)
        })
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let done = expectation(description: "concurrent loads")
        done.expectedFulfillmentCount = 8

        for _ in 0..<8 {
            DispatchQueue.global().async {
                let loaded = VerdictWriteTrace.loadEntries(from: url, now: now)
                XCTAssertEqual(loaded.entries.count, 20)
                XCTAssertEqual(loaded.malformedLines, 0)
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 10)
    }

    // MARK: - Round-trip, so the JSONL the write path emits is the JSONL summarize reads

    func testEntryRoundTripsThroughJSON() throws {
        let original = entry(
            "2026-09-28",
            site: "postBackfill",
            offsetSeconds: 0,
            rawTotal: -3,
            rawRecovery: -2,
            rawTruth: .yellow,
            rawRecoveryTruth: .green,
            historyLastDayISO: "2026-09-28",
            historyCount: 28,
            overwrote: true,
            priorRawTotal: -6,
            priorRawRecovery: -4
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(VerdictTraceEntry.self, from: encoder.encode(original))

        XCTAssertEqual(decoded, original)
    }
}
