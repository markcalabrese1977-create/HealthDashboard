import Foundation
import os

// MARK: - Verdict write trace (diagnostic, additive only)
//
// Records every write to the verdict log so we can see which evaluation ends up OWNING
// each day's record. `SharedStore.appendVerdictLog` upserts by dateISO, so a day's stored
// record is simply whatever wrote last — and five separate call sites reach evaluate(),
// one of them (the weekly summary) in a loop over up to 7 days with deliberately truncated
// history. This file makes that write sequence observable.
//
// Strictly observational: nothing here feeds the engine, the hysteresis gate, the stored
// DailyVerdictRecord, or any surface the user reads. The write path swallows every I/O
// error by design — a diagnostic must never be able to break a real write.
//
// Not gated on #if DEBUG: the interesting traces come from background HKObserverQuery
// deliveries on a real device, which a Debug-only trace would miss. Gated on
// `verdictTraceEnabled` alone, which removes the file I/O, the os_log summary, and the
// ContentView UI together.

// MARK: - Task-local write context
//
// Carried from each evaluate() call site down into appendVerdictLog without changing any
// existing signature. evaluate() is synchronous and appendVerdictLog is called from inside
// it, so a synchronous `withValue` binding at the call site is visible at the write.

// `nonisolated`: the app target builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so
// without this the trace would be main-actor-bound and unusable from the background
// HKObserverQuery delivery — which is precisely the write path worth tracing.
nonisolated enum VerdictTraceContext {
    @TaskLocal static var site: String?
    @TaskLocal static var historyLastDayISO: String?
    @TaskLocal static var historyCount: Int?
}

// MARK: - One recorded write

nonisolated struct VerdictTraceEntry: Codable, Equatable {
    let writtenAt: Date
    let dateISO: String

    // Optional: a write that somehow reaches appendVerdictLog outside a bound call site
    // still gets recorded, with the context fields simply absent.
    let site: String?
    let historyLastDayISO: String?
    let historyCount: Int?

    let rawTotal: Int
    let rawRecovery: Int?        // optional in DailyVerdictRecord (forward-only field)
    let rawTruth: ReadinessStatus
    let rawRecoveryTruth: ReadinessStatus

    // What this write replaced, captured before the upsert mutated the array.
    let overwrote: Bool
    let priorRawTotal: Int?
    let priorRawRecovery: Int?

    init(
        writtenAt: Date,
        dateISO: String,
        site: String?,
        historyLastDayISO: String?,
        historyCount: Int?,
        rawTotal: Int,
        rawRecovery: Int?,
        rawTruth: ReadinessStatus,
        rawRecoveryTruth: ReadinessStatus,
        overwrote: Bool,
        priorRawTotal: Int?,
        priorRawRecovery: Int?
    ) {
        self.writtenAt = writtenAt
        self.dateISO = dateISO
        self.site = site
        self.historyLastDayISO = historyLastDayISO
        self.historyCount = historyCount
        self.rawTotal = rawTotal
        self.rawRecovery = rawRecovery
        self.rawTruth = rawTruth
        self.rawRecoveryTruth = rawRecoveryTruth
        self.overwrote = overwrote
        self.priorRawTotal = priorRawTotal
        self.priorRawRecovery = priorRawRecovery
    }
}

// MARK: - Per-day rollup (pure output of summarize)

/// Result of reading the JSONL file: the entries that parsed, plus how many lines did not.
nonisolated struct VerdictTraceLoad: Equatable {
    let entries: [VerdictTraceEntry]
    let malformedLines: Int
}

/// Per-day rollups plus the file-level malformed-line count. Malformed lines cannot be
/// attributed to a date (they never parsed), so the count lives at the report level.
nonisolated struct VerdictTraceSummary: Equatable {
    let days: [VerdictTraceDaySummary]
    let malformedLines: Int
}

nonisolated struct VerdictTraceDaySummary: Equatable {
    let dateISO: String
    let totalWrites: Int
    let writesPerSite: [String: Int]
    let firstWrittenAt: Date
    let lastWrittenAt: Date
    let minRawTotal: Int
    let maxRawTotal: Int
    let minRawRecovery: Int?     // nil when no write that day carried a rawRecovery
    let maxRawRecovery: Int?

    /// First write whose history actually reached this day — i.e. the earliest evaluation
    /// that was NOT running on truncated history. Nil when no write that day qualified.
    let firstFullHistoryEntry: VerdictTraceEntry?

    /// The write that owns the stored record for this day (last one wins in the upsert).
    let finalEntry: VerdictTraceEntry
}

// nonisolated for the same reason as VerdictTraceContext above: this is file I/O and pure
// math, reachable from any isolation context, and must not be pinned to the main actor.
nonisolated enum VerdictWriteTrace {

    // MARK: Named constants

    static let verdictTraceEnabled = true
    static let verdictTraceRetentionDays = 14

    /// Bucket key used when a write arrives with no bound site.
    static let unattributedSite = "(unattributed)"

    private static let fileName = "verdict-write-trace.jsonl"

    /// Every filesystem touch in this file goes through this one serial queue: appends from
    /// the main actor (onAppear / manualEdit / postBackfill / weeklySummary) and from
    /// Task.detached (hkObserver) genuinely race, and the retention rewrite is an ATOMIC
    /// REPLACE — an append landing mid-rewrite would be erased outright, not just torn.
    ///
    /// Entry points take the queue with `sync` and the `...OnQueue` helpers assume they are
    /// already on it, so nothing ever re-enters (a nested sync on a serial queue deadlocks).
    private static let ioQueue = DispatchQueue(
        label: "com.calabrese.HealthDashboard.verdictWriteTrace.io"
    )

    private static let logger = Logger(
        subsystem: "com.calabrese.HealthDashboard",
        category: "VerdictWriteTrace"
    )

    // MARK: Codable configuration
    //
    // .iso8601 on both sides so the raw JSONL is readable once exported, and so a file
    // written by one build decodes in another.

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: File location

    /// Nil when the App Group container is unavailable (never true in the app, but the
    /// trace must degrade silently rather than assume).
    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// True only when there is something worth exporting — drives the ShareLink's presence
    /// so we never hand the share sheet a URL with no file behind it.
    static var hasTraceFile: Bool {
        guard verdictTraceEnabled, let url = fileURL else { return false }
        return ioQueue.sync {
            guard let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? NSNumber else { return false }
            return size.intValue > 0
        }
    }

    // MARK: - Write path
    //
    // Append-only, one JSON object per line. No retention work here by design: trimming
    // reads and rewrites the whole file, which is not something a verdict write should ever
    // pay for or be blocked by. Retention is applied when the file is opened for summary.

    static func record(_ entry: VerdictTraceEntry) {
        guard verdictTraceEnabled else { return }
        guard let url = fileURL else { return }
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)   // newline — JSONL
        // `sync`, not `async`: a dropped diagnostic write at app termination is worse than a
        // few hundred microseconds of file append, and it keeps a write ordered before any
        // load the same caller performs next.
        ioQueue.sync { appendOnQueue(line, to: url) }
    }

    /// Convenience used by `SharedStore.appendVerdictLog`: assembles the entry from the
    /// record being written, the task-local context, and the record being replaced.
    static func record(
        writing record: DailyVerdictRecord,
        replacing prior: DailyVerdictRecord?,
        at writtenAt: Date = Date()
    ) {
        guard verdictTraceEnabled else { return }
        self.record(
            VerdictTraceEntry(
                writtenAt: writtenAt,
                dateISO: record.dateISO,
                site: VerdictTraceContext.site,
                historyLastDayISO: VerdictTraceContext.historyLastDayISO,
                historyCount: VerdictTraceContext.historyCount,
                rawTotal: record.rawTotal,
                rawRecovery: record.rawRecovery,
                rawTruth: record.rawTruth,
                rawRecoveryTruth: record.rawRecoveryTruth,
                overwrote: prior != nil,
                priorRawTotal: prior?.rawTotal,
                priorRawRecovery: prior?.rawRecovery
            )
        )
    }

    /// Every failure mode here is swallowed: a missing container, a permissions failure, a
    /// handle that won't open, a write that throws mid-flight.
    ///
    /// MUST be called on `ioQueue` — the file-exists check below is check-then-act, and the
    /// seek/write pair is only atomic with respect to other writers because the queue
    /// serializes them.
    private static func appendOnQueue(_ data: Data, to url: URL) {
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Intentionally swallowed — see the file header.
        }
    }

    // MARK: - Read path (retention applied here, not on the write path)

    /// Pure: splits raw JSONL into entries, counting the lines that failed to decode rather
    /// than discarding them silently. One corrupt line costs exactly that line.
    static func parse(_ raw: String) -> VerdictTraceLoad {
        var entries: [VerdictTraceEntry] = []
        var malformed = 0

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(VerdictTraceEntry.self, from: data)
            else {
                malformed += 1
                continue
            }
            entries.append(entry)
        }

        return VerdictTraceLoad(entries: entries, malformedLines: malformed)
    }

    /// Reads the trace file, drops entries outside the retention window, and rewrites the
    /// file when retention removed anything. Read + retention + rewrite happen inside ONE
    /// `ioQueue.sync`, so an append can never land between the read and the atomic replace.
    ///
    /// `url` is injectable so tests can exercise the real file path against a temp file
    /// instead of the App Group container.
    ///
    /// Note: malformed lines are counted and left on disk, so persistent corruption keeps
    /// reporting itself. A retention-triggered rewrite does purge them as a side effect,
    /// since it writes back only what parsed.
    static func loadEntries(from url: URL?, now: Date = Date()) -> VerdictTraceLoad {
        guard verdictTraceEnabled, let url else {
            return VerdictTraceLoad(entries: [], malformedLines: 0)
        }

        return ioQueue.sync {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                return VerdictTraceLoad(entries: [], malformedLines: 0)
            }

            let loaded = parse(raw)
            let kept = applyRetention(to: loaded.entries, now: now)

            if kept.count != loaded.entries.count {
                rewriteOnQueue(kept, to: url)
            }

            return VerdictTraceLoad(entries: kept, malformedLines: loaded.malformedLines)
        }
    }

    static func loadEntries(now: Date = Date()) -> VerdictTraceLoad {
        loadEntries(from: fileURL, now: now)
    }

    /// Pure: keeps entries written within the retention window, counting back from `now`.
    static func applyRetention(
        to entries: [VerdictTraceEntry],
        now: Date = Date(),
        retentionDays: Int = verdictTraceRetentionDays
    ) -> [VerdictTraceEntry] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        return entries.filter { $0.writtenAt >= cutoff }
    }

    /// MUST be called on `ioQueue` — this is an atomic replace, so a concurrent append
    /// would be erased rather than merged.
    private static func rewriteOnQueue(_ entries: [VerdictTraceEntry], to url: URL) {
        var out = Data()
        for e in entries {
            guard var line = try? encoder.encode(e) else { continue }
            line.append(0x0A)
            out.append(line)
        }
        try? out.write(to: url, options: .atomic)
    }

    // MARK: - Summary (pure)

    /// Rolls the flat write log up per dateISO. Pure — takes entries, touches no storage —
    /// so it is the part worth unit-testing.
    ///
    /// Ordering within a day is by writtenAt, ties broken by the order entries were handed
    /// in (the order they were appended), so "final surviving entry" is deterministic even
    /// when several writes share a timestamp.
    static func summarize(entries: [VerdictTraceEntry]) -> [VerdictTraceDaySummary] {
        let grouped = Dictionary(grouping: entries.enumerated(), by: { $0.element.dateISO })

        return grouped.keys.sorted().compactMap { dateISO -> VerdictTraceDaySummary? in
            guard let indexed = grouped[dateISO], !indexed.isEmpty else { return nil }

            let ordered = indexed
                .sorted {
                    $0.element.writtenAt == $1.element.writtenAt
                        ? $0.offset < $1.offset
                        : $0.element.writtenAt < $1.element.writtenAt
                }
                .map { $0.element }

            var writesPerSite: [String: Int] = [:]
            for e in ordered {
                writesPerSite[e.site ?? unattributedSite, default: 0] += 1
            }

            let totals = ordered.map { $0.rawTotal }
            let recoveries = ordered.compactMap { $0.rawRecovery }

            return VerdictTraceDaySummary(
                dateISO: dateISO,
                totalWrites: ordered.count,
                writesPerSite: writesPerSite,
                firstWrittenAt: ordered[0].writtenAt,
                lastWrittenAt: ordered[ordered.count - 1].writtenAt,
                minRawTotal: totals.min() ?? 0,
                maxRawTotal: totals.max() ?? 0,
                minRawRecovery: recoveries.min(),
                maxRawRecovery: recoveries.max(),
                firstFullHistoryEntry: ordered.first { $0.historyLastDayISO == dateISO },
                finalEntry: ordered[ordered.count - 1]
            )
        }
    }

    /// Wraps the per-day rollup with the file-level malformed-line count.
    static func summarize(entries: [VerdictTraceEntry], malformedLines: Int) -> VerdictTraceSummary {
        VerdictTraceSummary(
            days: summarize(entries: entries),
            malformedLines: malformedLines
        )
    }

    // MARK: - Call-site context binding
    //
    // Synchronous `withValue` form, nested once per task-local. Used to wrap each
    // evaluate() call without altering evaluate()'s signature or behavior.

    static func withContext<T>(
        site: String,
        history: [DailyHealthPoint],
        _ body: () throws -> T
    ) rethrows -> T {
        try VerdictTraceContext.$site.withValue(site) {
            try VerdictTraceContext.$historyLastDayISO.withValue(history.last?.dayISO) {
                try VerdictTraceContext.$historyCount.withValue(history.count) {
                    try body()
                }
            }
        }
    }

    // MARK: - Surfacing
    //
    // Same mechanism as SharedStore.dumpVerdictLog: os_log, read in Console.app or the
    // Xcode console. Own category so the trace can be filtered apart from SharedStore's
    // own chatter.

    static func dumpSummary() {
        guard verdictTraceEnabled else { return }

        let loaded = loadEntries()
        let summary = summarize(entries: loaded.entries, malformedLines: loaded.malformedLines)

        logger.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logger.log("🖊️ VERDICT WRITE TRACE — entries=\(loaded.entries.count, privacy: .public) days=\(summary.days.count, privacy: .public) retention=\(verdictTraceRetentionDays, privacy: .public)d")

        if summary.malformedLines > 0 {
            logger.log("  ⚠️ malformed lines skipped: \(summary.malformedLines, privacy: .public) — the rest of the trace is intact")
        }

        if summary.days.isEmpty {
            logger.log("  (no writes recorded yet)")
        }

        for s in summary.days {
            let sites = s.writesPerSite
                .sorted { $0.key < $1.key }
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: ", ")

            let recoveryRange = (s.minRawRecovery == nil || s.maxRawRecovery == nil)
                ? "nil"
                : "\(s.minRawRecovery!)…\(s.maxRawRecovery!)"

            let firstFull = s.firstFullHistoryEntry
                .map { "\($0.site ?? unattributedSite) @ \($0.writtenAt)" } ?? "none"

            logger.log("  \(s.dateISO, privacy: .public) | writes=\(s.totalWrites, privacy: .public) | rawTotal \(s.minRawTotal, privacy: .public)…\(s.maxRawTotal, privacy: .public) | rawRecovery \(recoveryRange, privacy: .public)")
            logger.log("      sites: \(sites, privacy: .public)")
            logger.log("      first full-history write: \(firstFull, privacy: .public)")
            logger.log("      OWNER (last write): site=\(s.finalEntry.site ?? unattributedSite, privacy: .public) rawTotal=\(s.finalEntry.rawTotal, privacy: .public) rawTruth=\(s.finalEntry.rawTruth.rawValue, privacy: .public) historyCount=\(s.finalEntry.historyCount ?? -1, privacy: .public) historyLast=\(s.finalEntry.historyLastDayISO ?? "nil", privacy: .public)")
        }

        logger.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
}
