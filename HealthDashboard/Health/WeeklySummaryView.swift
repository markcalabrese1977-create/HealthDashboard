import SwiftUI

// MARK: - Weekly summary model

struct WeeklySummary {
    struct MetricWeek {
        let title: String
        let thisWeekAvg: Double?
        let priorWeekAvg: Double?
        let unit: String
        let higherIsBetter: Bool
        let formatDigits: Int

        var delta: Double? {
            guard let t = thisWeekAvg, let p = priorWeekAvg else { return nil }
            return t - p
        }

        var direction: Direction {
            guard let d = delta else { return .neutral }
            if abs(d) < 0.5 { return .neutral }
            let improved = higherIsBetter ? d > 0 : d < 0
            return improved ? .up : .down
        }

        enum Direction { case up, down, neutral }
    }

    let thisWeek: [DailyHealthPoint]
    let priorWeek: [DailyHealthPoint]
    let metrics: [MetricWeek]
    let narrative: String
    let avgReadinessScore: Double?
    let readinessColor: ReadinessStatus
    /// Training / strength load for the completed days of this week vs the same days last week.
    /// Additive: nil when there are no completed days yet or a window day is missing from history.
    var loadComparison: LoadWeekComparison? = nil

    static func build(history: [DailyHealthPoint], manual: ManualReadinessInputs, today: Date = Date()) -> WeeklySummary? {
        guard history.count >= 7 else { return nil }

        let cal = Calendar(identifier: .iso8601) // Monday-anchored
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyy-MM-dd"

                let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
                let priorWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!

                let thisWeek = history.filter {
                    guard let d = fmt.date(from: $0.dayISO) else { return false }
                    return d >= thisWeekStart
                }
                let priorWeek = history.filter {
                    guard let d = fmt.date(from: $0.dayISO) else { return false }
                    return d >= priorWeekStart && d < thisWeekStart
                }

                guard !thisWeek.isEmpty else { return nil }

        func avg(_ keyPath: KeyPath<DailyHealthPoint, Double?>, in pts: [DailyHealthPoint]) -> Double? {
            let vals = pts.compactMap { $0[keyPath: keyPath] }
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count)
        }

        func effAvg(_ pts: [DailyHealthPoint]) -> Double? {
            let vals: [Double] = pts.compactMap { pt in
                guard let a = pt.sleepHours, let b = pt.sleepInBedHours,
                      b > 0, b >= a + 0.08 else { return nil }
                return (a / b) * 100
            }
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count)
        }

        let metrics: [MetricWeek] = [
            MetricWeek(
                title: "HRV",
                thisWeekAvg: avg(\.hrvMS, in: thisWeek),
                priorWeekAvg: avg(\.hrvMS, in: priorWeek),
                unit: "ms", higherIsBetter: true, formatDigits: 0
            ),
            MetricWeek(
                title: "Resting HR",
                thisWeekAvg: avg(\.restingHR, in: thisWeek),
                priorWeekAvg: avg(\.restingHR, in: priorWeek),
                unit: "bpm", higherIsBetter: false, formatDigits: 0
            ),
            MetricWeek(
                title: "Sleep",
                thisWeekAvg: avg(\.sleepHours, in: thisWeek),
                priorWeekAvg: avg(\.sleepHours, in: priorWeek),
                unit: "h", higherIsBetter: true, formatDigits: 1
            ),
            MetricWeek(
                title: "Sleep Eff",
                thisWeekAvg: effAvg(thisWeek),
                priorWeekAvg: effAvg(priorWeek),
                unit: "%", higherIsBetter: true, formatDigits: 0
            ),
            MetricWeek(
                title: "Resp Rate",
                thisWeekAvg: avg(\.respiratoryRate, in: thisWeek),
                priorWeekAvg: avg(\.respiratoryRate, in: priorWeek),
                unit: "br/min", higherIsBetter: false, formatDigits: 1
            ),
        ]

        // Weekly readiness scores
        let scores: [Int] = thisWeek.map { pt in
            let r = VerdictPersistence.withSuppressedPersistence {
                ReadinessEngine.evaluate(
                    history: history.filter { $0.dayISO <= pt.dayISO },
                    manual: manual
                )
            }
            switch r.truth {
            case .green: return 2
            case .yellow: return 1
            case .red: return 0
            }
        }
        let avgScore = scores.isEmpty ? nil : Double(scores.reduce(0, +)) / Double(scores.count)
        let readinessColor: ReadinessStatus = {
            guard let a = avgScore else { return .green }
            if a >= 1.5 { return .green }
            if a >= 0.8 { return .yellow }
            return .red
        }()

        let narrative = buildNarrative(metrics: metrics, thisWeek: thisWeek, priorWeek: priorWeek)

        return WeeklySummary(
            thisWeek: thisWeek,
            priorWeek: priorWeek,
            metrics: metrics,
            narrative: narrative,
            avgReadinessScore: avgScore,
            readinessColor: readinessColor,
            loadComparison: LoadWeekComparison.compute(history: history, today: today)
        )
    }

    private static func buildNarrative(
        metrics: [MetricWeek],
        thisWeek: [DailyHealthPoint],
        priorWeek: [DailyHealthPoint]
    ) -> String {
        var sentences: [String] = []

        // HRV
        if let m = metrics.first(where: { $0.title == "HRV" }),
           let avg = m.thisWeekAvg {
            let avgStr = "\(Int(avg.rounded())) ms"
            switch m.direction {
            case .up:
                if let d = m.delta {
                    sentences.append("HRV averaged \(avgStr) this week, up \(Int(d.rounded())) ms from last week — a positive recovery trend.")
                } else {
                    sentences.append("HRV averaged \(avgStr) this week.")
                }
            case .down:
                if let d = m.delta {
                    sentences.append("HRV averaged \(avgStr) this week, down \(Int(abs(d).rounded())) ms from last week.")
                } else {
                    sentences.append("HRV averaged \(avgStr) this week.")
                }
            case .neutral:
                sentences.append("HRV was stable this week, averaging \(avgStr).")
            }
        }

        // Sleep
        if let m = metrics.first(where: { $0.title == "Sleep" }),
           let avg = m.thisWeekAvg {
            let h = Int(avg)
            let min = Int((avg - Double(h)) * 60)
            let avgStr = "\(h)h \(min)m"
            switch m.direction {
            case .up:
                sentences.append("Sleep duration improved to \(avgStr) average.")
            case .down:
                sentences.append("Sleep averaged \(avgStr), below last week's level.")
            case .neutral:
                sentences.append("Sleep was consistent at \(avgStr) average.")
            }
        }

        // RHR
        if let m = metrics.first(where: { $0.title == "Resting HR" }),
           let avg = m.thisWeekAvg {
            let avgStr = "\(Int(avg.rounded())) bpm"
            switch m.direction {
            case .up:
                sentences.append("Resting HR elevated to \(avgStr) average — watch for accumulated fatigue.")
            case .down:
                sentences.append("Resting HR dropped to \(avgStr) average, consistent with good recovery.")
            case .neutral:
                sentences.append("Resting HR held steady at \(avgStr).")
            }
        }

        // Resp Rate anomaly only
                if let m = metrics.first(where: { $0.title == "Resp Rate" }),
                   m.direction == .down,
                   let avg = m.thisWeekAvg,
                   let d = m.delta {
                    let magnitude = abs(d) >= 1.5 ? "notably elevated" : "slightly elevated"
                    sentences.append("Respiratory rate averaged \(String(format: "%.1f", avg)) br/min — \(magnitude) from prior week.")
                }

        // Workouts
        let workoutDays = thisWeek.filter { ($0.workoutCount ?? 0) >= 1 }.count
        if workoutDays > 0 {
            sentences.append("You trained \(workoutDays) day\(workoutDays == 1 ? "" : "s") this week.")
        }

        return sentences.joined(separator: " ")
    }
}

// MARK: - Load comparison (completed days vs the same days last week)
//
// Pure: depends only on DailyHealthPoint, a reference date and a calendar. No readiness engine, no
// stored verdicts. TRIMP and mechanical load come straight from the history points, with nil days
// counted as 0 (a rest day and "no data" are indistinguishable in the history).

struct LoadWeekComparison: Equatable {
    /// Completed days compared (Monday through yesterday).
    let completedDays: Int
    /// Inclusive first and last day of each window, for the caption.
    let thisWindowStart: Date
    let thisWindowEnd: Date
    let priorWindowStart: Date
    let priorWindowEnd: Date

    let trimpThis: Double
    let trimpPrior: Double
    let strengthThis: Double
    let strengthPrior: Double

    /// A row shows only if some point anywhere in the history has a positive value for it, so a user
    /// with no EP data (or no HR-backed workouts) never sees a permanent zero row.
    let showsTrimp: Bool
    let showsStrength: Bool

    var trimpDelta: Double { trimpThis - trimpPrior }
    var strengthDelta: Double { strengthThis - strengthPrior }

    enum DeltaDisplay: Equatable {
        case dash
        case up(Double)
        case down(Double)
    }

    /// Same dayISO construction the engine and HealthKit use (Calendar.current components, %04d-%02d-%02d).
    static func dayISO(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// nil when there are no completed days yet (Monday), or when ANY of the 2n window days has no
    /// point in `history`. Today's own (partial) point is never part of either window.
    static func compute(
        history: [DailyHealthPoint],
        today: Date,
        calendar: Calendar = Calendar(identifier: .iso8601)   // Monday-anchored, same as build
    ) -> LoadWeekComparison? {
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let priorWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart),
              let n = calendar.dateComponents([.day], from: thisWeekStart, to: calendar.startOfDay(for: today)).day,
              n > 0
        else { return nil }

        let byDay = Dictionary(history.map { ($0.dayISO, $0) }, uniquingKeysWith: { _, last in last })

        var thisPoints: [DailyHealthPoint] = []
        var priorPoints: [DailyHealthPoint] = []
        for k in 0..<n {
            guard let thisDay = calendar.date(byAdding: .day, value: k, to: thisWeekStart),
                  let priorDay = calendar.date(byAdding: .day, value: k, to: priorWeekStart),
                  let t = byDay[dayISO(thisDay)],
                  let p = byDay[dayISO(priorDay)]
            else { return nil }
            thisPoints.append(t)
            priorPoints.append(p)
        }

        guard let thisEnd = calendar.date(byAdding: .day, value: n - 1, to: thisWeekStart),
              let priorEnd = calendar.date(byAdding: .day, value: n - 1, to: priorWeekStart)
        else { return nil }

        func sum(_ pts: [DailyHealthPoint], _ kp: KeyPath<DailyHealthPoint, Double?>) -> Double {
            pts.reduce(0) { $0 + ($1[keyPath: kp] ?? 0) }
        }

        return LoadWeekComparison(
            completedDays: n,
            thisWindowStart: thisWeekStart,
            thisWindowEnd: thisEnd,
            priorWindowStart: priorWeekStart,
            priorWindowEnd: priorEnd,
            trimpThis: sum(thisPoints, \.dailyTrimp),
            trimpPrior: sum(priorPoints, \.dailyTrimp),
            strengthThis: sum(thisPoints, \.mechanicalLoad),
            strengthPrior: sum(priorPoints, \.mechanicalLoad),
            showsTrimp: history.contains { ($0.dailyTrimp ?? 0) > 0 },
            showsStrength: history.contains { ($0.mechanicalLoad ?? 0) > 0 }
        )
    }

    /// Neutral by design (no better/worse judgement). A dash when the change is within 5% of the prior
    /// total, inclusive, or both are zero; otherwise an arrow by sign. A zero prior with a non-zero
    /// current is a real change. Compared as |delta| * 20 <= |prior| to avoid float fuzz at exactly 5%.
    static func deltaDisplay(this: Double, prior: Double) -> DeltaDisplay {
        let delta = this - prior
        if abs(delta) * 20.0 <= abs(prior) { return .dash }
        return delta > 0 ? .up(delta) : .down(-delta)
    }

    /// "Load (completed days): Oct 12 – Oct 13 vs Oct 5 – Oct 6"; a single day collapses to
    /// "Oct 12 vs Oct 5". Formatted like the card's date-range label ("MMM d", " – " between ends),
    /// but built here from the four dates so it can be tested with fixed ones.
    static func caption(
        thisStart: Date, thisEnd: Date, priorStart: Date, priorEnd: Date,
        calendar: Calendar = Calendar(identifier: .iso8601),
        locale: Locale = .current
    ) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "MMM d"

        func window(_ a: Date, _ b: Date) -> String {
            let first = f.string(from: a), last = f.string(from: b)
            return first == last ? first : "\(first) – \(last)"
        }
        return "Load (completed days): \(window(thisStart, thisEnd)) vs \(window(priorStart, priorEnd))"
    }

    var caption: String {
        Self.caption(thisStart: thisWindowStart, thisEnd: thisWindowEnd,
                     priorStart: priorWindowStart, priorEnd: priorWindowEnd)
    }

    /// Whole number with grouping separators, e.g. "15,853".
    static func formatTotal(_ value: Double, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }
}

// MARK: - Weekly summary card view

struct WeeklySummaryCard: View {
    let summary: WeeklySummary

    private var dateRangeLabel: String {
            let cal = Calendar(identifier: .iso8601)
            let today = Date()
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            let outFmt = DateFormatter()
            outFmt.dateFormat = "MMM d"

            guard let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start else {
                return "This week"
            }

            let todayStr = outFmt.string(from: today)
            let weekStartStr = outFmt.string(from: thisWeekStart)

            // Prior week Mon–Sun
            let priorWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!
            let priorWeekEnd = cal.date(byAdding: .day, value: -1, to: thisWeekStart)!
            let priorStartStr = outFmt.string(from: priorWeekStart)
            let priorEndStr = outFmt.string(from: priorWeekEnd)

            return "\(weekStartStr) – \(todayStr)  ·  vs \(priorStartStr) – \(priorEndStr)"
        }

    var body: some View {
        DashboardCard(title: "This Week", collapsible: true) {
            VStack(alignment: .leading, spacing: 14) {

                // Date range + readiness pill
                HStack {
                    Text(dateRangeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    WeekReadinessPill(status: summary.readinessColor)
                }

                // Narrative
                if !summary.narrative.isEmpty {
                    Text(summary.narrative)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.5)

                // Week-over-week metric rows
                VStack(spacing: 0) {
                    ForEach(Array(summary.metrics.enumerated()), id: \.offset) { idx, metric in
                        WeekMetricRow(metric: metric)
                        if idx < summary.metrics.count - 1 {
                            Divider().opacity(0.4).padding(.leading, 4)
                        }
                    }
                }

                // Training Load / Strength Load: completed days vs the same days last week.
                if let load = summary.loadComparison, load.showsTrimp || load.showsStrength {
                    LoadWeekRows(load: load)
                }
            }
        }
    }
}

// MARK: - Readiness pill

private struct WeekReadinessPill: View {
    let status: ReadinessStatus

    private var label: String {
        switch status {
        case .green: return "Strong week"
        case .yellow: return "Mixed week"
        case .red: return "Recovery week"
        }
    }

    private var bg: Color {
        switch status {
        case .green: return Color(.systemGreen).opacity(0.18)
        case .yellow: return Color(.systemOrange).opacity(0.18)
        case .red: return Color(.systemRed).opacity(0.18)
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(bg)
            .clipShape(Capsule())
    }
}

// MARK: - Week metric row

private struct WeekMetricRow: View {
    let metric: WeeklySummary.MetricWeek

    private func fmtVal(_ v: Double?) -> String {
        guard let v else { return "--" }
        if metric.title == "Sleep" {
            let h = Int(v)
            let m = Int((v - Double(h)) * 60)
            return "\(h)h \(m)m"
        }
        let unitStr = metric.unit.isEmpty ? "" : (metric.unit == "%" ? "%" : " \(metric.unit)")
                return String(format: "%.\(metric.formatDigits)f", v) + unitStr
    }

    private var arrowColor: Color {
        switch metric.direction {
        case .up: return .green
        case .down: return .orange
        case .neutral: return .secondary
        }
    }

    private var arrowIcon: String {
            guard let d = metric.delta else { return "minus" }
            switch metric.direction {
            case .neutral: return "minus"
            case .up, .down:
                // Arrow shows the direction the value moved, not whether it improved
                return d > 0 ? "arrow.up" : "arrow.down"
            }
        }

    private var deltaStr: String {
            guard let d = metric.delta else { return "" }
            let absd = abs(d)
            if metric.title == "Sleep" {
                let h = Int(absd)
                let m = Int((absd - Double(h)) * 60)
                return m > 0 ? "\(h)h \(m)m" : "\(h)h"
            }
            let unitStr = metric.unit == "%" ? "%" : " \(metric.unit)"
            return String(format: "%.\(metric.formatDigits)f", absd) + unitStr
        }

    var body: some View {
        HStack(spacing: 8) {
            Text(metric.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(fmtVal(metric.thisWeekAvg))
                .font(.caption.weight(.semibold))
                .monospacedDigit()

            Spacer()

            if metric.delta != nil {
                HStack(spacing: 3) {
                    Image(systemName: arrowIcon)
                        .font(.caption2.weight(.semibold))
                    Text(deltaStr)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
                .foregroundStyle(arrowColor)
            }

            Text("vs prior week")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Load rows (neutral styling)

private struct LoadWeekRows: View {
    let load: LoadWeekComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.4).padding(.leading, 4)

            if load.showsTrimp {
                LoadWeekRow(title: "Training Load", this: load.trimpThis, prior: load.trimpPrior)
            }
            if load.showsTrimp && load.showsStrength {
                Divider().opacity(0.4).padding(.leading, 4)
            }
            if load.showsStrength {
                LoadWeekRow(title: "Strength Load", this: load.strengthThis, prior: load.strengthPrior)
            }

            Text(load.caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }
}

private struct LoadWeekRow: View {
    let title: String
    let this: Double
    let prior: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 72, alignment: .leading)

            Text(LoadWeekComparison.formatTotal(this))
                .font(.caption.weight(.semibold))
                .monospacedDigit()

            Spacer()

            switch LoadWeekComparison.deltaDisplay(this: this, prior: prior) {
            case .dash:
                Text("–")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            case .up(let d):
                deltaLabel(icon: "arrow.up", amount: d)
            case .down(let d):
                deltaLabel(icon: "arrow.down", amount: d)
            }

            Text("vs same days last week")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }

    private func deltaLabel(icon: String, amount: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(LoadWeekComparison.formatTotal(amount))
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)   // neutral: more or less load is not judged good or bad
    }
}
