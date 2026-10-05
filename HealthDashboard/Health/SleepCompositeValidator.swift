import Foundation

// MARK: - SleepCompositeValidator (Phase 6 precondition — blocker 2)
//
// Correlates the backfilled sleep composite(D) against the LOGGED readiness(D+1) while
// readiness still runs on sleepEffScore and is independent of the composite. Restricted
// to `matured` days (production estimator only — warm-up days excluded). Pure functions
// are unit-tested; `run()` wires the SharedStore side stores.
//
// Directional only. A weak/ambiguous r must NOT promote or kill on a knife-edge — let it
// accrue and revisit. The per-axis breakdown exists to show WHICH axis drags a weak r.

enum SleepCompositeValidator {

    static let minAxisAvailabilityFraction = 0.80   // axis is decision-grade at ≥80% of matured pairs

    enum AxisNilReason {
        case insufficientPairs   // ax_.count < 2 → pearson returned nil for n-floor reason
        case zeroVariance        // ax_.count >= 2 but sxx == 0 → axis scores are constant, no signal
    }

    struct Report {
        let n: Int                              // matured composite→readiness(D+1) pairs
        let rawR: Double?                       // composite(D) vs readiness(D+1) rawTotal
        let partialR: Double?                   // ...controlling for load(D) = TRIMP + mechLoad
        let nRecovery: Int                      // pairs with a load-stripped recovery(D+1)
        let recoveryR: Double?                  // composite(D) vs recovery(D+1) — the clean target
        let perAxisR: [(axis: SleepAxis, r: Double?)]
        let perAxisAvailability: [(axis: SleepAxis, availablePairs: Int)]
        let isDecisionGrade: Bool
        let summary: String
    }

    // MARK: Pure math

    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in xs.indices {
            let dx = xs[i] - mx, dy = ys[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return nil }   // no variance ⇒ correlation undefined
        return sxy / (sxx.squareRoot() * syy.squareRoot())
    }

    /// First-order partial correlation of X,Y controlling for Z, from the three pairwise r's.
    static func partial(rXY: Double, rXZ: Double, rYZ: Double) -> Double? {
        let denom = (1 - rXZ * rXZ) * (1 - rYZ * rYZ)
        guard denom > 0 else { return nil }
        return (rXY - rXZ * rYZ) / denom.squareRoot()
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func nextDayISO(_ iso: String) -> String? {
        guard let date = dayFormatter.date(from: iso),
              let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: date)
        else { return nil }
        return dayFormatter.string(from: next)
    }

    // MARK: Pairing (matured composite(D) → readiness(D+1))

    /// composite(D) paired with readiness(D+1) rawTotal over matured days only.
    static func maturedPairs(
        axisLog: [SleepAxisLogRecord],
        readinessByDate: [String: Int]
    ) -> (x: [Double], y: [Double]) {
        var x: [Double] = [], y: [Double] = []
        for rec in axisLog where rec.matured {
            guard let next = nextDayISO(rec.dateISO), let ready = readinessByDate[next] else { continue }
            x.append(rec.composite)
            y.append(Double(ready))
        }
        return (x, y)
    }

    /// The actual (D → D+1) date pairs used, in order — for eyeballing n and spotting a
    /// spurious pair (e.g. the newest pairing into a provisional, not-yet-closed "today").
    static func maturedPairDates(
        axisLog: [SleepAxisLogRecord],
        readinessByDate: [String: Int]
    ) -> [(d: String, next: String)] {
        var out: [(String, String)] = []
        for rec in axisLog.sorted(by: { $0.dateISO < $1.dateISO }) where rec.matured {
            guard let next = nextDayISO(rec.dateISO), readinessByDate[next] != nil else { continue }
            out.append((rec.dateISO, next))
        }
        return out
    }

    /// Per-axis score(D) paired with readiness(D+1), matured days only — for weak-r diagnosis.
    static func maturedAxisPairs(
        axis: SleepAxis,
        axisLog: [SleepAxisLogRecord],
        readinessByDate: [String: Int]
    ) -> (x: [Double], y: [Double]) {
        var x: [Double] = [], y: [Double] = []
        for rec in axisLog where rec.matured {
            guard let next = nextDayISO(rec.dateISO), let ready = readinessByDate[next],
                  let sub = rec.subScores.first(where: { $0.axis == axis }), sub.available
            else { continue }
            x.append(sub.score)
            y.append(Double(ready))
        }
        return (x, y)
    }

    /// Aligned triples composite(D), readiness(D+1), control(D) — only days where ALL three
    /// exist, so the three pairwise correlations share one sample (required for a valid
    /// partial). `controlByDate` is keyed by D (the composite day), e.g. load(D).
    static func maturedTriples(
        axisLog: [SleepAxisLogRecord],
        readinessByDate: [String: Int],
        controlByDate: [String: Double]
    ) -> (x: [Double], y: [Double], z: [Double]) {
        var x: [Double] = [], y: [Double] = [], z: [Double] = []
        for rec in axisLog where rec.matured {
            guard let next = nextDayISO(rec.dateISO),
                  let ready = readinessByDate[next],
                  let ctrl = controlByDate[rec.dateISO]
            else { continue }
            x.append(rec.composite)
            y.append(Double(ready))
            z.append(ctrl)
        }
        return (x, y, z)
    }

    // MARK: Report builder (pure — takes the stores as inputs so it's testable)

    static func buildReport(
        axisLog: [SleepAxisLogRecord],
        readinessByDate rawReadinessByDate: [String: Int],
        loadByDate: [String: Double] = [:],
        recoveryByDate rawRecoveryByDate: [String: Int] = [:],
        excludeNextDayISO: String? = nil   // drop pairs whose D+1 == this date (in-progress "today")
    ) -> Report {
        // Scoped off-by-one guard: a pair into an in-progress "today" uses provisional
        // readiness. Exclude ONLY that exact date — a completed today is a valid pair, and
        // once tomorrow arrives this date is no longer excluded (self-healing).
        let readinessByDate = excludeNextDayISO.map { ex in rawReadinessByDate.filter { $0.key != ex } } ?? rawReadinessByDate
        let recoveryByDate = excludeNextDayISO.map { ex in rawRecoveryByDate.filter { $0.key != ex } } ?? rawRecoveryByDate

        // Raw: composite(D) vs readiness(D+1).
        let (x, y) = maturedPairs(axisLog: axisLog, readinessByDate: readinessByDate)
        let rawR = pearson(x, y)

        // Partial: same, controlling for load(D). The real test — readiness(D+1)'s own load
        // term and sleep(D)'s strain-adjusted need share load(D), inflating the raw r.
        let (tx, ty, tz) = maturedTriples(axisLog: axisLog, readinessByDate: readinessByDate, controlByDate: loadByDate)
        let partialR: Double? = {
            guard let rXY = pearson(tx, ty), let rXZ = pearson(tx, tz), let rYZ = pearson(ty, tz) else { return nil }
            return partial(rXY: rXY, rXZ: rXZ, rYZ: rYZ)
        }()

        // Load-stripped target: composite(D) vs recovery(D+1). Forward-only (nil until pairs accrue).
        let (rx, ry) = maturedPairs(axisLog: axisLog, readinessByDate: recoveryByDate)
        let recoveryR = pearson(rx, ry)

        let axes: [SleepAxis] = [.architecture, .duration, .efficiency, .fragmentation, .consistency]
        let totalMatured = x.count
        // Parallel pass: correlation + availability count + nil-cause, without changing maturedAxisPairs.
        // nilReason distinguishes "too few available pairs" from "axis scores are constant" — both
        // collapse to pearson nil but require different banner copy and decision-grade treatment.
        let perAxisResults: [(axis: SleepAxis, r: Double?, availablePairs: Int, nilReason: AxisNilReason?)] = axes.map { ax in
            let (ax_, ay_) = maturedAxisPairs(axis: ax, axisLog: axisLog, readinessByDate: readinessByDate)
            let r = pearson(ax_, ay_)
            let nilReason: AxisNilReason? = r == nil
                ? (ax_.count >= 2 ? .zeroVariance : .insufficientPairs)
                : nil
            return (axis: ax, r: r, availablePairs: ax_.count, nilReason: nilReason)
        }

        let minAvailPairs = Int((minAxisAvailabilityFraction * Double(totalMatured)).rounded(.up))
        // An axis is decision-grade iff it has enough available pairs AND its correlation is a real
        // number. available-but-constant (zeroVariance) carries no signal and is NOT decision-grade.
        let isDecisionGrade = totalMatured >= 15
            && perAxisResults.allSatisfy { $0.availablePairs >= minAvailPairs && $0.r != nil }

        // Off-by-one audit aid: the exact pairs, in order. n should equal this list length.
        let pairDates = maturedPairDates(axisLog: axisLog, readinessByDate: readinessByDate)

        func fmt(_ v: Double?) -> String { v.map { String(format: "%+.2f", $0) } ?? "n/a" }
        var lines: [String] = []

        // Run status banner — first thing a reader sees.
        let pct = Int(minAxisAvailabilityFraction * 100)
        if isDecisionGrade {
            lines.append("✅ DECISION-GRADE RUN — all axes available ≥\(pct)% of \(totalMatured) pairs.")
        } else {
            // An axis is degraded either because it had too few available pairs OR because it was
            // available on enough pairs but its scores were constant (zero variance, r=n/a).
            let degraded = perAxisResults.filter { $0.availablePairs < minAvailPairs || $0.r == nil }
            lines.append("⚠️ DEGRADED RUN — NOT decision-grade. The following axes fell below the availability floor or had no signal and their correlations (and the composite that includes them) are unreliable this run:")
            for d in degraded {
                if d.nilReason == .zeroVariance {
                    lines.append("     \(d.axis.title): available but constant (zero variance) — contributes no signal")
                } else {
                    lines.append("     \(d.axis.title): \(d.availablePairs)/\(totalMatured) available")
                }
            }
            lines.append("  Composite partial-r and per-axis numbers below are computed on a reduced/degraded axis set. Do NOT use this run to decide the composite driver-swap or rework.")
        }

        lines.append("🛌📈 SleepComposite validation — matured pairs n=\(x.count)")
        lines.append("  pairs (D→D+1): " + pairDates.map { "\($0.d)→\($0.next)" }.joined(separator: ", "))
        if let last = pairDates.last {
            lines.append("  ⚠️ audit: newest pair D+1=\(last.next) — if that's TODAY, its readiness is still provisional; drop it until the day closes (this is the likely 'n one high').")
        }
        lines.append("  raw   composite(D) vs readiness(D+1): r=\(fmt(rawR))")
        if isDecisionGrade {
            lines.append("  partial (control load(D), n=\(tx.count)): r=\(fmt(partialR))  ← the real test")
        } else {
            lines.append("  DIAGNOSTIC ONLY (degraded run — not for decisions):")
            lines.append("  partial (control load(D), n=\(tx.count)): r=\(fmt(partialR))")
        }
        lines.append("  recovery-stripped composite(D) vs recovery(D+1) (n=\(rx.count)): r=\(fmt(recoveryR))")
        if x.count < 15 {
            lines.append("  ⚠️ n<15 — directional only, let it accrue before acting.")
        }
        for r in perAxisResults {
            let detail: String
            if let rv = r.r {
                detail = "r=\(fmt(rv))   (available \(r.availablePairs)/\(totalMatured))"
            } else if r.nilReason == .zeroVariance {
                detail = "r=n/a  (available \(r.availablePairs)/\(totalMatured) — ZERO VARIANCE, axis is constant, no signal)"
            } else {
                detail = "r=n/a  (available \(r.availablePairs)/\(totalMatured) — INSUFFICIENT, axis unavailable on most pairs)"
            }
            lines.append("  · \(r.axis.title): \(detail)")
        }

        return Report(
            n: x.count,
            rawR: rawR,
            partialR: partialR,
            nRecovery: rx.count,
            recoveryR: recoveryR,
            perAxisR: perAxisResults.map { (axis: $0.axis, r: $0.r) },
            perAxisAvailability: perAxisResults.map { (axis: $0.axis, availablePairs: $0.availablePairs) },
            isDecisionGrade: isDecisionGrade,
            summary: lines.joined(separator: "\n")
        )
    }

    // MARK: Live entry point (reads the persisted stores)

    static func run() -> Report {
        let axisLog = SharedStore.loadSleepAxisLog()
        let verdict = SharedStore.loadVerdictLog()
        let history = SharedStore.loadHistory()

        // Pair with the LOGGED readiness — never re-derive readiness for past days.
        let readinessByDate = Dictionary(verdict.map { ($0.dateISO, $0.rawTotal) },
                                         uniquingKeysWith: { _, new in new })
        // Load-stripped recovery target, where logged (forward-only).
        let recoveryByDate = Dictionary(verdict.compactMap { r in r.rawRecovery.map { (r.dateISO, $0) } },
                                        uniquingKeysWith: { _, new in new })
        // Control variable: load(D) = TRIMP(D) + mechanicalLoad(D), keyed by composite day.
        let loadByDate = Dictionary(history.map { ($0.dayISO, ($0.dailyTrimp ?? 0) + ($0.mechanicalLoad ?? 0)) },
                                    uniquingKeysWith: { _, new in new })

        // Today (LOCAL calendar, run time) — matches how verdict/sleep dates are stored
        // (Calendar.current components), not the UTC dayFormatter. Its readiness is still
        // provisional, so any pair into it is dropped until the day closes.
        let todayISO: String = {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        }()

        return buildReport(axisLog: axisLog,
                           readinessByDate: readinessByDate,
                           loadByDate: loadByDate,
                           recoveryByDate: recoveryByDate,
                           excludeNextDayISO: todayISO)
    }
}
