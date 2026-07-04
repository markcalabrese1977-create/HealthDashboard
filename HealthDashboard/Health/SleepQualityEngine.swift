import Foundation

// MARK: - SleepQualityEngine (Phase 3)
//
// Stateless, mirrors ReadinessEngine: an `enum` with a single `static func evaluate`.
// The view-model that OWNS the result must store it (@Published) — never read
// evaluate() as a computed property from a SwiftUI body (the confirmed perf root cause).
//
// Option B topology: the composite is INTRINSIC only — architecture, duration-vs-need,
// efficiency, fragmentation, consistency. No autonomic axis (ReadinessEngine owns
// HRV/RHR/RR/temp), so this score can safely feed readiness later with no double-count.
//
// Intra-composite double-count guard (per Phase 3 amendment):
//   • Efficiency owns the MAGNITUDE of wakefulness (onset latency + total WASO, via the
//     asleep/in-bed ratio). It is the only axis that weights total awake minutes.
//   • Fragmentation owns PATTERN only — wake-bout count (≥5 min, post-smoothing) and
//     block consolidation. It must NOT re-penalize total awake minutes.
//   Proof case (Phase 4): 1×90-min wake vs 18×5-min wakes (same 90-min WASO) → identical
//   efficiency, divergent fragmentation.
//
// SpO2 desaturation is intentionally absent: Option B carries no autonomic/respiratory
// axis, and SpO2 availability on this Ultra 2 is unconfirmed. Extension point only.

enum SleepQualityEngine {

    // MARK: - Tunable constants (weights sum to 100 at full availability)

    static let wArchitecture:  Double = 30
    static let wDuration:      Double = 25
    static let wEfficiency:    Double = 20
    static let wFragmentation: Double = 12
    static let wConsistency:   Double = 13

    /// Verdict band thresholds on the 0–100 composite.
    static let verdictExcellent: Double = 85
    static let verdictGood:      Double = 70
    static let verdictFair:      Double = 55

    /// Noise floor: awake bouts shorter than this are micro-arousals, not awakenings.
    static let minBoutMinutes: Double = 5

    /// Minimum staged nights before architecture scores baseline-relative (else reference).
    static let minStagedBaselineNights = 4
    /// Minimum nights with window bounds before consistency runs at all.
    static let minConsistencyNights = 3
    static let consistencyWindowNights = 14

    /// Minimum asleep hours for a night to be scoreable at all.
    static let minScoreableAsleepHours: Double = 3

    /// Renorm floor: a composite must rest on enough of the picture. When too many axes
    /// drop at once (e.g. a thin-history unstaged night), reporting a number over 1–2
    /// axes is misleading — return `.unavailable` instead of over-weighting the survivors.
    static let minAvailableAxes = 3
    static let minAvailableWeightSum: Double = 50

    // Population reference stage proportions — fallback ONLY when the personal staged
    // baseline is too thin. Secondary to baseline, never the primary anchor.
    static let refDeepProportion: Double = 0.16
    static let refREMProportion:  Double = 0.22

    static let maxBaselineDays = 28

    // MARK: - Entry point

    /// - Parameters:
    ///   - history: oldest → newest, today is `.last`. Prior nights supply persisted
    ///     per-stage scalars + window bounds for the baseline-relative axes.
    ///   - todaySegments: RAW (unsmoothed) stage/awake segments for the night being scored.
    ///     Smoothing happens HERE, not in the extractor.
    ///   - dumpTrace: DEBUG-only. When true, prints the post-smoothing bout list the engine
    ///     actually scored (window, onset, latency, WASO/bouts, longest block) so a suspect
    ///     awake block can be seen as latency vs WASO vs fragmentation. Only the headline
    ///     night sets this; the 28-day backfill leaves it false to avoid flooding.
    static func evaluate(
        history: [DailyHealthPoint],
        todaySegments: [SleepSegment],
        dumpTrace: Bool = false
    ) -> SleepQualityResult {

        guard let today = history.last,
              let asleepHours = today.sleepHours,
              asleepHours >= minScoreableAsleepHours else {
            return .unavailable
        }

        // MARK: Helpers (local — same convention as ReadinessEngine, no shared util)

        func median(_ xs: [Double]) -> Double? {
            let s = xs.sorted()
            guard !s.isEmpty else { return nil }
            if s.count % 2 == 1 { return s[s.count / 2] }
            return (s[(s.count / 2) - 1] + s[s.count / 2]) / 2.0
        }
        func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 100) -> Double { max(lo, min(hi, x)) }

        // Baseline window: prior nights only (exclude today), up to 28.
        let baselineSlice: [DailyHealthPoint] = {
            guard history.count >= 2 else { return [] }
            let prior = Array(history.dropLast())
            return prior.count <= maxBaselineDays ? prior : Array(prior.suffix(maxBaselineDays))
        }()

        // MARK: Segment-derived scalars for the scored night

        func stageMinutes(_ segs: [SleepSegment], _ stage: SleepStage) -> Double {
            segs.filter { $0.stage == stage }
                .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) } / 60.0
        }

        let deepMin  = stageMinutes(todaySegments, .deep)
        let remMin   = stageMinutes(todaySegments, .rem)
        let coreMin  = stageMinutes(todaySegments, .core)
        let unspecMin = stageMinutes(todaySegments, .unspecified)

        let stagedTonight = (deepMin + remMin + coreMin) > 0
        let coreOnlyTonight = stagedTonight && deepMin == 0 && remMin == 0 && coreMin > 0
        let segmentAsleepMin = deepMin + remMin + coreMin + unspecMin

        // Window bounds: prefer persisted scalars, else derive from raw segments.
        let windowStart = today.sleepWindowStart ?? todaySegments.map { $0.start }.min()
        let windowEnd   = today.sleepWindowEnd ?? todaySegments.map { $0.end }.max()

        // Smoothing (5-min min-bout + adjacent same-stage merge) → drives efficiency &
        // fragmentation. Architecture uses RAW stage minutes (matches how baselines stored).
        let smoothed = Self.smooth(todaySegments, minBoutMinutes: minBoutMinutes)
        let coalescedRaw = Self.coalesceAdjacent(todaySegments.sorted { $0.start < $1.start })

        // Onset = first asleep segment (smoothed); latency = window start → onset.
        let firstAsleep = smoothed.first { $0.stage != .awake }
        let onset = firstAsleep?.start
        let onsetLatencyMin: Double = {
            guard let onset, let ws = windowStart, onset > ws else { return 0 }
            return onset.timeIntervalSince(ws) / 60.0
        }()

        // WASO + bouts: awake segments AFTER onset (smoothed → all remaining ≥ min-bout).
        let postOnsetAwakeSmoothed: [SleepSegment] = {
            guard let onset else { return [] }
            return smoothed.filter { $0.stage == .awake && $0.start >= onset }
        }()
        let wasoMinutes = postOnsetAwakeSmoothed.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) / 60.0 }
        let wakeBoutCount = postOnsetAwakeSmoothed.count

        // All awakenings pre-min-bout (coalesced but unfiltered) — stored, not scored.
        let awakeningCount: Int = {
            guard let onset else { return 0 }
            return coalescedRaw.filter { $0.stage == .awake && $0.start >= onset }.count
        }()

        // Longest consolidated sleep block (minutes) — fragmentation consolidation metric.
        let longestBlockMin: Double = smoothed
            .filter { $0.stage != .awake }
            .map { $0.end.timeIntervalSince($0.start) / 60.0 }
            .max() ?? (asleepHours * 60.0)

        // Efficiency denominator = SLEEP-PERIOD TIME (first asleep → last asleep), NOT
        // time-in-bed. Pre-onset latency and post-final-wake in-bed awake are excluded here
        // (latency is scored as its own input below), so couch-sleep/re-bed no longer
        // double-penalizes efficiency. WASO between first and last asleep stays inside SPT
        // and still counts. Computed from RAW segments to match the persisted baseline.
        let inBedHours = today.sleepInBedHours ?? {           // kept for fallback + trace only
            guard let ws = windowStart, let we = windowEnd, we > ws else { return asleepHours }
            return we.timeIntervalSince(ws) / 3600.0
        }()
        let sptHours: Double = {
            let asleepSegs = todaySegments.filter { $0.stage != .awake }
            guard let f = asleepSegs.map({ $0.start }).min(),
                  let l = asleepSegs.map({ $0.end }).max(), l > f else { return inBedHours }
            return l.timeIntervalSince(f) / 3600.0
        }()
        let efficiency = sptHours > 0 ? min(1.2, max(0, asleepHours / sptHours)) : 0

        #if DEBUG
        if dumpTrace {
            let hm: (Date?) -> String = { d in
                guard let d else { return "--:--" }
                let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
            }
            func mins(_ a: Date, _ b: Date) -> Int { Int((b.timeIntervalSince(a) / 60).rounded()) }
            print("🛌🔬 SleepQuality trace — scored night (\(today.dayISO))")
            print("   window \(hm(windowStart))→\(hm(windowEnd))  inBed=\(String(format: "%.2f", inBedHours))h SPT=\(String(format: "%.2f", sptHours))h asleep=\(String(format: "%.2f", asleepHours))h")
            print("   eff=\(String(format: "%.3f", efficiency)) (asleep/SPT)  vs old inBed-based=\(String(format: "%.3f", inBedHours > 0 ? asleepHours / inBedHours : 0)) — gap = the couch-sleep double-penalty removed")
            print("   onset=\(hm(onset)) latency=\(Int(onsetLatencyMin.rounded()))min  ⟵ any awake BEFORE onset is latency, not WASO/bout")
            print("   post-onset: bouts=\(wakeBoutCount) WASO=\(Int(wasoMinutes.rounded()))min longestBlock=\(Int(longestBlockMin.rounded()))min")
            print("   smoothed segments (\(smoothed.count)):")
            for s in smoothed {
                let tag = (onset != nil && s.stage == .awake && s.start >= onset!) ? "  ← WASO bout" : (s.stage == .awake ? "  ← pre-onset (latency)" : "")
                print("     \(hm(s.start))-\(hm(s.end))  \(s.stage.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(mins(s.start, s.end))m\(tag)")
            }
        }
        #endif

        // MARK: - Strain / debt inputs for duration need

        let baselineNeedHours = max(7.0, median(baselineSlice.compactMap { $0.sleepHours }) ?? 7.0)

        // Prior-day strain add-on (TRIMP + mechanical load elevated vs baseline).
        let prior = baselineSlice.last
        let trimpBase = median(baselineSlice.compactMap { $0.dailyTrimp }.filter { $0 > 0 })
        let mechBase  = median(baselineSlice.compactMap { $0.mechanicalLoad }.filter { $0 > 0 })
        let strainAdjustHours: Double = {
            var add = 0.0
            if let t = prior?.dailyTrimp, let b = trimpBase, b > 0 {
                if t > b * 2.0 { add += 0.5 } else if t > b * 1.5 { add += 0.25 }
            }
            if let m = prior?.mechanicalLoad, let b = mechBase, b > 0, m > b * 1.5 { add += 0.25 }
            return min(add, 1.0)
        }()

        // Sleep debt: trailing shortfall over the prior 3 nights (each vs baseline need).
        let debtNights = Array(baselineSlice.suffix(3)).compactMap { $0.sleepHours }
        let sleepDebtHours = min(2.0, debtNights.reduce(0.0) { $0 + max(0, baselineNeedHours - $1) })

        // Nap credit — daytime naps aren't isolated by the noon→noon extractor yet.
        // Extension point: subtract nap hours here once naps are windowed separately.
        let napCreditHours: Double = 0

        let sleepNeedHours = baselineNeedHours + strainAdjustHours + min(sleepDebtHours, 1.5) - napCreditHours

        // MARK: - Axis scoring

        var flags: [String] = []
        // Set true only when architecture scored against the PERSONAL staged baseline —
        // not reference proportions, not the core-only neutral. Feeds `matured`.
        var archUsedPersonalBaseline = false

        // Architecture (30) — RAW stage minutes vs staged-night baseline; reference fallback.
        func architectureScore() -> (score: Double, available: Bool) {
            guard stagedTonight, segmentAsleepMin > 0 else { return (0, false) }

            // Core-only night (Apple sometimes emits core with zero deep AND zero REM).
            // Degrade gracefully — do NOT emit a "no deep sleep" verdict.
            if coreOnlyTonight {
                flags.append("Limited stage detail")
                return (65, true)
            }

            let stagedBaseline = baselineSlice.filter {
                ((($0.sleepDeepMinutes ?? 0) + ($0.sleepREMMinutes ?? 0) + ($0.sleepCoreMinutes ?? 0)) > 0)
            }
            let enoughBaseline = stagedBaseline.count >= minStagedBaselineNights
            // Personal-baseline architecture is the production estimator; reference fallback
            // is a warm-up substitute. Only the former counts toward `matured`.
            archUsedPersonalBaseline = enoughBaseline

            let deepTarget = enoughBaseline
                ? (median(stagedBaseline.compactMap { $0.sleepDeepMinutes }) ?? refDeepProportion * segmentAsleepMin)
                : refDeepProportion * segmentAsleepMin
            let remTarget = enoughBaseline
                ? (median(stagedBaseline.compactMap { $0.sleepREMMinutes }) ?? refREMProportion * segmentAsleepMin)
                : refREMProportion * segmentAsleepMin

            func stageScore(_ actual: Double, _ target: Double, label: String) -> Double {
                guard target > 0 else { return 100 }
                let ratio = actual / target
                let s: Double
                switch ratio {
                case 0.90...:      s = 100
                case 0.75..<0.90:  s = 85
                case 0.50..<0.75:  s = 65
                default:           s = 40
                }
                if s < 65 { flags.append("Low \(label)") }
                return s
            }

            let deepScore = stageScore(deepMin, deepTarget, label: "deep sleep")
            let remScore  = stageScore(remMin, remTarget, label: "REM")
            // Core is scored only for gross adequacy (secondary weight).
            let coreScore: Double = coreMin >= (0.35 * segmentAsleepMin) ? 100 : 75

            let score = deepScore * 0.4 + remScore * 0.4 + coreScore * 0.2
            return (clamp(score), true)
        }

        // Duration (25) — asleep vs dynamic need.
        func durationScore() -> Double {
            let shortfall = sleepNeedHours - asleepHours
            let s: Double
            switch shortfall {
            case ..<0.25:      s = 100
            case 0.25..<0.75:  s = 88
            case 0.75..<1.5:   s = 70
            case 1.5..<2.5:    s = 50
            default:           s = 30
            }
            if s < 70 { flags.append("Short vs need") }
            return s
        }

        // Efficiency (20) — magnitude of wakefulness via asleep/in-bed, absolute anchor +
        // baseline modifier. Owns total awake minutes.
        func efficiencyScore() -> Double {
            var s: Double
            switch efficiency {
            case 0.90...:      s = 100
            case 0.85..<0.90:  s = 90
            case 0.80..<0.85:  s = 75
            case 0.75..<0.80:  s = 60
            default:           s = 40
            }
            // Baseline uses the SAME SPT denominator as today (persisted sleepPeriodMinutes),
            // so the modifier isn't biased by the in-bed→SPT change.
            let effBase = median(baselineSlice.compactMap { p -> Double? in
                guard let a = p.sleepHours, let spt = p.sleepPeriodMinutes, spt > 0, a >= 3 else { return nil }
                return min(1.2, a / (spt / 60.0))
            })
            if let base = effBase {
                let d = efficiency - base
                if d <= -0.05 { s -= 10 } else if d >= 0.02 { s += 5 }
            }
            if onsetLatencyMin > 30 { flags.append("Long sleep latency") }
            if clamp(s) < 70 { flags.append("Low efficiency") }
            return clamp(s)
        }

        // Fragmentation (12) — PATTERN only: bout count + consolidation. No awake magnitude.
        func fragmentationScore() -> (score: Double, available: Bool) {
            guard stagedTonight else { return (0, false) }
            var s: Double
            switch wakeBoutCount {
            case 0...1: s = 100
            case 2:     s = 88
            case 3:     s = 75
            case 4...5: s = 60
            case 6...8: s = 45
            default:    s = 30
            }
            if longestBlockMin < 60 { s -= 15 } else if longestBlockMin >= 120 { s += 5 }
            if clamp(s) < 70 { flags.append("Fragmented") }
            return (clamp(s), true)
        }

        // Consistency (13) — SD of sleep midpoint over a rolling window (bed/wake SD stored).
        func consistencyScore() -> (score: Double, available: Bool, mid: Double?, bed: Double?, wake: Double?) {
            // Shift by 12h so evening bedtimes don't wrap across midnight.
            func shiftedMinutes(_ date: Date) -> Double {
                let cal = Calendar.current
                let comps = cal.dateComponents([.hour, .minute], from: date)
                let tod = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
                return (tod + 720).truncatingRemainder(dividingBy: 1440)
            }
            func sd(_ xs: [Double]) -> Double? {
                guard xs.count >= minConsistencyNights else { return nil }
                let mean = xs.reduce(0, +) / Double(xs.count)
                let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
                return variance.squareRoot()
            }

            let recent = Array(history.suffix(consistencyWindowNights))
            let pairs: [(start: Date, end: Date)] = recent.compactMap {
                guard let s = $0.sleepWindowStart, let e = $0.sleepWindowEnd, e > s else { return nil }
                return (s, e)
            }
            let midpoints = pairs.map { shiftedMinutes(Date(timeIntervalSince1970: ($0.start.timeIntervalSince1970 + $0.end.timeIntervalSince1970) / 2)) }
            let bedtimes  = pairs.map { shiftedMinutes($0.start) }
            let waketimes = pairs.map { shiftedMinutes($0.end) }

            guard let midSD = sd(midpoints) else {
                return (0, false, nil, nil, nil)
            }
            var s: Double
            switch midSD {
            case ..<20:   s = 100
            case 20..<40: s = 85
            case 40..<60: s = 70
            case 60..<90: s = 50
            default:      s = 30
            }
            if s < 70 { flags.append("Inconsistent schedule") }
            return (clamp(s), true, midSD, sd(bedtimes), sd(waketimes))
        }

        let arch = architectureScore()
        let dur  = durationScore()
        let eff  = efficiencyScore()
        let frag = fragmentationScore()
        let cons = consistencyScore()

        // MARK: - Assemble sub-scores + general renormalization

        struct RawAxis { let axis: SleepAxis; let score: Double; let full: Double; let available: Bool }
        let rawAxes: [RawAxis] = [
            RawAxis(axis: .architecture,  score: arch.score, full: wArchitecture,  available: arch.available),
            RawAxis(axis: .duration,      score: dur,        full: wDuration,      available: true),
            RawAxis(axis: .efficiency,    score: eff,        full: wEfficiency,    available: true),
            RawAxis(axis: .fragmentation, score: frag.score, full: wFragmentation, available: frag.available),
            RawAxis(axis: .consistency,   score: cons.score, full: wConsistency,   available: cons.available)
        ]

        let availableCount = rawAxes.filter { $0.available }.count
        let availableFullSum = rawAxes.filter { $0.available }.reduce(0.0) { $0 + $1.full }

        // Renorm floor: don't report a composite resting on too little.
        guard availableCount >= minAvailableAxes, availableFullSum >= minAvailableWeightSum else {
            return .unavailable
        }

        let subScores: [SleepSubScore] = rawAxes.map { ax in
            let eff = (ax.available && availableFullSum > 0) ? ax.full / availableFullSum * 100 : 0
            return SleepSubScore(axis: ax.axis, score: ax.score, effectiveWeight: eff, available: ax.available)
        }
        let availableAxes = rawAxes.filter { $0.available }.map { $0.axis }

        // Matured = production estimator: every axis ran AND architecture used the personal
        // staged baseline. Warm-up days (thin baseline → reference/core-only, or a dropped
        // axis) are NOT matured and are excluded from validation.
        let matured = (availableAxes.count == rawAxes.count) && archUsedPersonalBaseline

        let composite = subScores.reduce(0.0) { $0 + $1.score * $1.effectiveWeight / 100.0 }

        let verdict: SleepQualityVerdict = {
            switch composite {
            case verdictExcellent...: return .excellent
            case verdictGood...:      return .good
            case verdictFair...:      return .fair
            default:                  return .poor
            }
        }()

        let inputs = SleepQualityInputs(
            deepMinutes: deepMin,
            remMinutes: remMin,
            coreMinutes: coreMin,
            unspecifiedMinutes: unspecMin,
            awakeMinutes: stageMinutes(todaySegments, .awake),
            totalAsleepMinutes: segmentAsleepMin,
            sleepHours: asleepHours,
            sleepNeedHours: sleepNeedHours,
            baselineNeedHours: baselineNeedHours,
            strainAdjustHours: strainAdjustHours,
            sleepDebtHours: sleepDebtHours,
            napCreditHours: napCreditHours,
            efficiency: efficiency,
            onsetLatencyMinutes: onsetLatencyMin,
            wasoMinutes: wasoMinutes,
            awakeningCount: awakeningCount,
            wakeBoutCount: wakeBoutCount,
            interspersedAwakeMinutes: wasoMinutes,
            midpointSDMinutes: cons.mid,
            bedtimeSDMinutes: cons.bed,
            wakeSDMinutes: cons.wake
        )

        let uniqueFlags = Array(NSOrderedSet(array: flags).array as? [String] ?? flags).prefix(5)

        let message = Self.buildMessage(
            verdict: verdict,
            subScores: subScores,
            availableAxes: availableAxes,
            hasStagedData: stagedTonight,
            coreOnly: coreOnlyTonight
        )

        return SleepQualityResult(
            composite: composite,
            verdict: verdict,
            subScores: subScores,
            inputs: inputs,
            flags: Array(uniqueFlags),
            hasStagedData: stagedTonight,
            availableAxes: availableAxes,
            matured: matured,
            message: message
        )
    }

    // MARK: - Smoothing (noise floor lives here, not the extractor)

    /// Coalesce adjacent same-stage segments (contiguous or overlapping).
    static func coalesceAdjacent(_ segs: [SleepSegment]) -> [SleepSegment] {
        guard !segs.isEmpty else { return [] }
        var out: [SleepSegment] = []
        for s in segs {
            if let last = out.last, last.stage == s.stage, s.start <= last.end.addingTimeInterval(1) {
                out[out.count - 1] = SleepSegment(stage: last.stage, start: last.start, end: max(last.end, s.end))
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Full smoothing: coalesce → drop sub-min-bout awake micro-arousals → re-coalesce.
    static func smooth(_ raw: [SleepSegment], minBoutMinutes: Double) -> [SleepSegment] {
        guard !raw.isEmpty else { return [] }
        let sorted = raw.sorted { $0.start < $1.start }
        let coalesced = coalesceAdjacent(sorted)
        let minSec = minBoutMinutes * 60
        let filtered = coalesced.filter { seg in
            !(seg.stage == .awake && seg.end.timeIntervalSince(seg.start) < minSec)
        }
        return coalesceAdjacent(filtered)
    }

    // MARK: - Messaging (derives ONLY from computed sub-scores / availability)

    static func buildMessage(
        verdict: SleepQualityVerdict,
        subScores: [SleepSubScore],
        availableAxes: [SleepAxis],
        hasStagedData: Bool,
        coreOnly: Bool
    ) -> String {
        // Only ever name AVAILABLE axes — never assert a verdict on an axis that didn't run.
        let weak = subScores
            .filter { $0.available && $0.score < 70 }
            .sorted { $0.score < $1.score }
            .map { $0.axis.title }

        var parts: [String] = ["\(verdict.title) sleep."]

        if weak.isEmpty {
            parts.append("All measured axes are near your norm.")
        } else if weak.count == 1 {
            parts.append("Held back by \(weak[0].lowercased()).")
        } else {
            parts.append("Held back by \(weak.prefix(2).map { $0.lowercased() }.joined(separator: " and ")).")
        }

        if !hasStagedData {
            parts.append("Stage detail unavailable — architecture and fragmentation weren't scored.")
        } else if coreOnly {
            parts.append("Only core sleep was staged tonight, so deep/REM detail is limited.")
        }

        return parts.joined(separator: " ")
    }
}
