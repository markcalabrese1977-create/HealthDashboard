import Foundation

enum ReadinessEngine {

    #if DEBUG
    private static var engineRunCount = 0
    #endif

    static func evaluate(history: [DailyHealthPoint], manual: ManualReadinessInputs) -> ReadinessResult {

        #if DEBUG
        engineRunCount += 1
        print("🔢 Engine run #\(engineRunCount)")
        print("🔬 ReadinessEngine v2: signal-weighted scoring (HRV cap -1, Eff cap -1, Sleep +1 above base, convergence bonus at count≥3)")
        #endif

        // We keep UI at 7 days, but engine can use more history for baselines/trends.
        // Expect history oldest -> newest.
        let full = history
        let today = full.last
        
        #if DEBUG
        func fmtOpt(_ x: Double?) -> String {
            guard let x else { return "nil" }
            return String(format: "%.2f", x)
        }

        let last7 = Array(full.suffix(7))

        let rhrSeries7 = last7.map { "\($0.dayISO):\(fmtOpt($0.restingHR))" }.joined(separator: " | ")
        let hrvSeries7 = last7.map { "\($0.dayISO):\(fmtOpt($0.hrvMS))" }.joined(separator: " | ")
        let sleepSeries7 = last7.map { "\($0.dayISO):\(fmtOpt($0.sleepHours))/\(fmtOpt($0.sleepInBedHours))" }.joined(separator: " | ")

        print("🧾 Engine history count=\(full.count) (showing last7)")
        print("🧾 RHR last7  -> \(rhrSeries7)")
        print("🧾 HRV last7  -> \(hrvSeries7)")
        print("🧾 Sleep last7 (asleep/inbed) -> \(sleepSeries7)")
        #endif

        // MARK: - Helpers
        func median(_ xs: [Double]) -> Double? {
            let s = xs.sorted()
            guard !s.isEmpty else { return nil }
            if s.count % 2 == 1 { return s[s.count / 2] }
            return (s[(s.count / 2) - 1] + s[s.count / 2]) / 2.0
        }

        func pctDelta(current: Double, base: Double) -> Double {
            (current - base) / base
        }

        func clamp(_ x: Int, _ lo: Int, _ hi: Int) -> Int {
            max(lo, min(hi, x))
        }

        // MARK: - Baseline window (prefer up to 28 days, exclude today)
        // If you only have 7, it behaves like before.
        let maxBaselineDays = 28
        let baselineSlice: [DailyHealthPoint] = {
            guard full.count >= 2 else { return full }
            let withoutToday = Array(full.dropLast())
            if withoutToday.count <= maxBaselineDays { return withoutToday }
            return Array(withoutToday.suffix(maxBaselineDays))
        }()

        // MARK: - Baselines (median)
        let rhrBase = median(
            baselineSlice
                .compactMap { $0.restingHR }
                .filter { $0 >= 35 && $0 <= 110 }
        )
        let hrvBase = median(
            baselineSlice
                .compactMap { $0.hrvMS }
                .filter { $0 >= 5 && $0 <= 250 }
        )
        let sleepBase = median(baselineSlice.compactMap { $0.sleepHours })
        let spo2Base  = median(baselineSlice.compactMap { $0.spo2Pct })

        // Wrist temp: stored as absolute °C in history, so compute delta vs baseline median.
        let tempSeries = baselineSlice.compactMap { $0.wristTempDeltaC }
        let tempBase = tempSeries.count >= 3 ? median(tempSeries) : nil

        // Respiratory rate baseline (sleep RR)
        let rrBase = median(baselineSlice.compactMap { $0.respiratoryRate })

        // Sleep target: simple and stable
        let sleepTarget = max(7.0, sleepBase ?? 7.0)

        // Sleep efficiency baseline (proxy for fragmentation)
        // Only consider nights with meaningful in-bed time.
        func efficiency(asleep: Double?, inBed: Double?) -> Double? {
            guard let a = asleep, let b = inBed else { return nil }
            guard a >= 3.0, b >= 4.0 else { return nil }

            let minGapHours = 0.08   // ~5 minutes
            guard b >= a + minGapHours else { return nil }

            let maxGapHours = 2.0
            guard (b - a) <= maxGapHours else { return nil }

            let e = a / b
            return max(0.0, min(1.2, e))
        }

        let effBase = median(
            baselineSlice.compactMap { efficiency(asleep: $0.sleepHours, inBed: $0.sleepInBedHours) }
        )


        // MARK: - Recovery scoring
        var flags: [String] = []

        var hrvScore = 0
        var rhrScore = 0
        var sleepScore = 0
        var sleepEffScore = 0
        var tempScore = 0
        var spo2Score = 0
        var rrScore = 0

        // TIER 3: Lower confidence — optical PPG, single-day noise significant
        // HRV earns authority through multi-day trend (hrvConcern), not single reading
        // Single-day negative score capped at -1
        // HRV score (vs baseline median; cap upside)
        if let cur = today?.hrvMS,
           cur >= 5, cur <= 250,
           let base = hrvBase, base > 0 {
            let d = pctDelta(current: cur, base: base)
            switch d {
            case (-0.05)...(0.08):
                hrvScore = 0
            case (-0.12)...(-0.05):
                hrvScore = -1
            case (-0.30)...(-0.12):
                hrvScore = -2
            case ..<(-0.30):
                hrvScore = -3
            case (0.08)...(0.20):
                hrvScore = +1
            default:
                hrvScore = +2
            }

            // Tier 3 demotion: cap single-day negative contribution at -1.
            if hrvScore < -1 { hrvScore = -1 }

            if hrvScore < 0 { flags.append("HRV ↓") }
        }

        // RHR score (absolute bpm deviation; cap upside)
        // RHR score (only if plausible)
        if let cur = today?.restingHR,
           cur >= 35, cur <= 110,
           let base = rhrBase {

            let d = cur - base
            // Tightened now that RHR is sleep-window-derived (observed range: 3 bpm over
            // 4 nights) rather than Apple's all-day signal (could swing 14 bpm/day from noise).
            if abs(d) <= 2 { rhrScore = 0 }
            else if d > 2 && d <= 4 { rhrScore = -1 }
            else if d > 4 && d <= 6 { rhrScore = -2 }
            else if d > 6 { rhrScore = -3 }
            else if d < -2 && d >= -4 { rhrScore = +1 }
            else if d < -4 { rhrScore = +2 }

            if rhrScore < 0 { flags.append("RHR ↑") }
        }

        // TIER 1: High confidence — best-validated signal in the engine
        // PSG-calibrated; duration reliable even when staging is uncertain
        // Positive scoring active: >0.5h above baseline earns +1
        // Sleep duration score (asleep hours vs target)
        if let cur = today?.sleepHours {
            let short = sleepTarget - cur
            if short <= 0.5 { sleepScore = 0 }
            else if short <= 1.5 { sleepScore = -1 }
            else if short <= 2.5 { sleepScore = -2 }
            else { sleepScore = -3 }

            // Tier 1 promotion: meaningfully above-average recovery night.
            if let base = sleepBase, cur > base + 0.5 {
                sleepScore = 1
            }

            if sleepScore < 0 { flags.append("Sleep ↓") }
        }

        // TIER 3: Lower confidence — Apple algorithm produces implausible values
        // (e.g. 98% efficiency over 10h). Demoted to -1 max, no positive scoring.
        // Retained as cluster flag input only.
        // Sleep efficiency score (quality proxy)
        // Goal: catch fragmented nights even when duration looks ok.
        if let effCur = efficiency(asleep: today?.sleepHours, inBed: today?.sleepInBedHours),
           let base = effBase {
            let d = effCur - base
            // Keep this conservative: we only penalize obvious deterioration.
            // Example baseline 0.92 -> 0.84 is meaningful.
            // Sleep efficiency is useful, but it is noisy.
            // Treat it as a supporting signal unless the drop is clearly large.
            if d >= -0.04 {
                sleepEffScore = 0
            } else {
                sleepEffScore = -1
            }

            if sleepEffScore < 0 { flags.append("Sleep quality ↓") }
        }

        // Wrist temp score (delta vs baseline)
        if let cur = today?.wristTempDeltaC, let base = tempBase {
            let d = cur - base
            if abs(d) <= 0.2 { tempScore = 0 }
            else if d > 0.2 && d <= 0.4 { tempScore = -1 }
            else if d > 0.4 && d <= 0.7 { tempScore = -2 }
            else if d > 0.7 { tempScore = -3 }
            if tempScore < 0 { flags.append("Wrist Temp ↑") }
        }

        // SpO2 score (only if abnormal vs personal median)
        if let cur = today?.spo2Pct, let base = spo2Base {
            let delta = base - cur
            if delta <= 1.0 { spo2Score = 0 }
            else if delta <= 2.0 { spo2Score = -1 }
            else { spo2Score = -2 }
            if spo2Score < 0 { flags.append("SpO2 ↓") }
        }

        // Respiratory rate score (early illness/strain)
        if let cur = today?.respiratoryRate, let base = rrBase {
            let d = cur - base
            if d < 1.0 { rrScore = 0 }
            else if d < 2.0 { rrScore = -1 }
            else { rrScore = -2 }
            if rrScore < 0 { flags.append("Resp Rate ↑") }
        }

        // MARK: - Manual reality inputs (minimal)
        let pain = clamp(manual.painLevel, 0, 10)
        let painScore: Int = (pain <= 2) ? 0 : (pain <= 4) ? -1 : (pain <= 6) ? -2 : -3
        if painScore < 0 { flags.append("Pain ↑") }

        let sickScore: Int = manual.isSick ? -4 : 0
        if manual.isSick { flags.append("Sick") }

        let hrvBufferedByStrongRecovery: Bool = {
            guard hrvScore == -2 else { return false }

            let rhrStableOrGood = rhrScore >= 0
            let sleepStrong = sleepScore >= 0
            let sleepQualityGood = sleepEffScore >= 0
            let rrStable = rrScore >= 0
            let tempStable = tempScore >= 0
            let noManualProblem = painScore == 0 && sickScore == 0

            return rhrStableOrGood &&
                   sleepStrong &&
                   sleepQualityGood &&
                   rrStable &&
                   tempStable &&
                   noManualProblem
        }()

        let adjustedHRVScore: Int = {
            if hrvScore == -2 && hrvBufferedByStrongRecovery {
                return -1
            }

            return hrvScore
        }()

        // var: convergenceBonus (below, after clusterCount is known) mutates this
        // before `total` is assembled.
        var recoveryScore =
            adjustedHRVScore + rhrScore + sleepScore + sleepEffScore + tempScore + spo2Score + rrScore
            + painScore + sickScore

        // MARK: - Load / Stress modifier (separate from recovery)
        // Still simple spike detector vs baseline medians.
        var loadMod = 0
                if let t = today {

                    // MARK: Workout load — TRIMP-based when HR data available, energy fallback otherwise
                    var workoutLoadScore = 0
                    let trimpBase = median(
                        baselineSlice.compactMap { $0.dailyTrimp }.filter { $0 > 0 }
                    )

                    if let trimp = t.dailyTrimp, trimp > 0, let base = trimpBase, base > 0 {
                        let ratio = trimp / base
                        if ratio > 2.0      { workoutLoadScore = -3 }
                        else if ratio > 1.5 { workoutLoadScore = -2 }
                        else if ratio > 1.2 { workoutLoadScore = -1 }
                    } else {
                        // Fallback: spike detector on energy or minutes
                        let workoutEnergyBase = median(baselineSlice.compactMap { $0.workoutEnergyKcal })
                        let workoutMinBase    = median(baselineSlice.compactMap { $0.workoutMinutes })
                        if let base = workoutEnergyBase, let v = t.workoutEnergyKcal, base > 0 {
                            if v > base * 1.5      { workoutLoadScore = -2 }
                            else if v > base * 1.2 { workoutLoadScore = -1 }
                        } else if let base = workoutMinBase, let v = t.workoutMinutes, base > 0 {
                            if v > max(base * 1.5, base + 30)  { workoutLoadScore = -2 }
                            else if v > max(base * 1.2, base + 15) { workoutLoadScore = -1 }
                        }
                    }

                    // Activity load (steps, movement — non-workout)
                    let stepsBase = median(baselineSlice.compactMap { $0.steps })
                    let moveBase  = median(baselineSlice.compactMap { $0.activeEnergyKcal })
                    let exBase    = median(baselineSlice.compactMap { $0.exerciseMinutes })

                    var highs = 0
                    if let base = stepsBase, let v = t.steps, base > 0, v > base * 1.25 { highs += 1 }
                    if let base = moveBase, let v = t.activeEnergyKcal, base > 0, v > base * 1.25 { highs += 1 }
                    if let base = exBase, let v = t.exerciseMinutes, base > 0, v > base * 1.25 { highs += 1 }

                    let activityScore = (highs == 0) ? 0 : (highs == 1) ? -1 : -2

                    loadMod = workoutLoadScore + activityScore
                }

        // MARK: - Clustering overrides (coach logic)
        let hrvDown10: Bool = {
            guard let cur = today?.hrvMS,
                  cur >= 5, cur <= 250,
                  let base = hrvBase, base > 0 else { return false }
            return pctDelta(current: cur, base: base) <= -0.10
        }()
        
        let hrvDownTrend: Bool = {
            let last4 = Array(full.suffix(4))
                .compactMap { $0.hrvMS }
                .filter { $0 >= 5 && $0 <= 250 }

            guard last4.count == 4 else { return false }

            let strictlyDescending =
                last4[0] > last4[1] &&
                last4[1] > last4[2] &&
                last4[2] > last4[3]

            guard strictlyDescending else { return false }

            let totalDrop = last4[0] - last4[3]
            let totalDropPct = totalDrop / last4[0]

            return totalDropPct >= 0.15
        }()

        // Tightened from 4.0 to 3.0 bpm now that RHR is sleep-window-derived — the cleaner
        // signal makes smaller deviations meaningful. NOTE: stored in DailyVerdictRecord
        // under the unchanged field name `rhrUp4` (verdict log schema is not being touched).
        let rhrUp3: Bool = {
            guard let cur = today?.restingHR,
                  cur >= 35, cur <= 110,
                  let base = rhrBase else { return false }
            return (cur - base) >= 3.0
        }()

        let sleepShort1: Bool = {
            guard let cur = today?.sleepHours else { return false }
            return cur <= (sleepTarget - 1.0)
        }()

        let tempUp03: Bool = {
            guard let cur = today?.wristTempDeltaC, let base = tempBase else { return false }
            return (cur - base) >= 0.3
        }()

        // 2-day trailing average prevents a single noisy night from firing the cluster flag.
        // Nightly RR jitters ±0.5 br/min; a one-day spike at threshold is indistinguishable
        // from noise. rrScore (aggregate) still reads today's single sample — only this binary
        // cluster flag uses the smoothed input.
        let rrUp10: Bool = {
            guard let base = rrBase else { return false }
            let recentRR = Array(full.suffix(2)).compactMap { $0.respiratoryRate }
            guard !recentRR.isEmpty else { return false }
            let avg = recentRR.reduce(0, +) / Double(recentRR.count)
            return (avg - base) >= 1.0
        }()

        let sleepEffLow: Bool = {
            guard let effCur = efficiency(asleep: today?.sleepHours, inBed: today?.sleepInBedHours),
                  let base = effBase else { return false }

            // Sleep efficiency is noisy. Only treat it as a cluster/push-blocking signal
            // when the drop is clearly large.
            return (effCur - base) <= -0.10
        }()

        let sickFlag = manual.isSick

        let hrvConcern = hrvDown10 || hrvDownTrend

        let clusterCount = [
            hrvConcern,
            rhrUp3,
            sleepShort1,
            tempUp03,
            rrUp10,
            sleepEffLow,
            sickFlag
        ].filter { $0 }.count

        // CHANGE 4: Multi-signal convergence bonus. Three independent noisy sensors
        // converging on the same direction carries more evidential weight than any single
        // signal at full magnitude. A single optical reading crossing a threshold should
        // not drive a Red verdict; convergence of three+ independent cluster flags should.
        // Applied to recoveryScore (not just total) so it also participates in the
        // pain-based forceRed condition below.
        let convergenceBonus = (clusterCount >= 3) ? -1 : 0
        recoveryScore += convergenceBonus

        let forceYellow = clusterCount >= 2
        let forceRed = clusterCount >= 3
            || (manual.isSick && (hrvDown10 || rhrUp3 || tempUp03 || sleepShort1 || rrUp10))
            || (pain >= 5 && recoveryScore <= -4)

        // MARK: - Truth color (based on recovery + load + overrides)
        let total = recoveryScore + loadMod

        // Keep your preference: do not Yellow from one moderate negative.
        let yellowTotalCutoff = -4
        let redTotalCutoff = -7 

        var truth: ReadinessStatus
        if total <= redTotalCutoff {
            truth = .red
        } else if clusterCount >= 2 || total <= yellowTotalCutoff {
            truth = .yellow
        } else {
            truth = .green
        }

        // Overrides stay authoritative
        if forceRed { truth = .red }
        else if forceYellow, truth != .red { truth = .yellow }

        // MARK: - Hysteresis gate (Option A: consecutive-day confirmation for Yellow→Green)
        // Raw computed verdict is stored to the log unconditionally every run.
        // The displayed truth is held at Yellow for one extra day if today's raw
        // verdict is Green but yesterday's stored rawTruth was not Green.

        let rawTruth = truth   // snapshot before any gating

        let todayISO: String = {
            let c = Calendar.current
            let comps = c.dateComponents([.year, .month, .day], from: Date())
            return String(format: "%04d-%02d-%02d",
                          comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        }()

        // Persist today's raw verdict (always, before the gate modifies truth).
        // Cluster flag values are captured as-is from the clustering block above —
        // this does not change how those flags are computed.
        SharedStore.appendVerdictLog(
            DailyVerdictRecord(
                dateISO: todayISO,
                rawTotal: total,
                rawRecovery: recoveryScore,   // load-stripped target for sleep-composite validation
                rawTruth: rawTruth,
                hrvDown10: hrvDown10,
                hrvDownTrend: hrvDownTrend,
                hrvConcern: hrvConcern,
                rhrUp4: rhrUp3,
                sleepShort1: sleepShort1,
                tempUp03: tempUp03,
                rrUp10: rrUp10,
                sleepEffLow: sleepEffLow,
                sick: sickFlag
            )
        )

        if rawTruth == .green {
            let log_ = SharedStore.loadVerdictLog()
            // Find yesterday's record.
            let cal = Calendar.current
            let yesterdayISO: String = {
                let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                let comps = cal.dateComponents([.year, .month, .day], from: yesterday)
                return String(format: "%04d-%02d-%02d",
                              comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
            }()

            let yesterdayRecord = log_.first(where: { $0.dateISO == yesterdayISO })

            if yesterdayRecord?.rawTruth != .green {
                // Yesterday was Yellow or Red (or absent — first-run, treat as unconfirmed).
                // Hold at Yellow for one more day.
                truth = .yellow
                #if DEBUG
                print("🔒 Hysteresis gate: raw=green, yesterday=\(yesterdayRecord?.rawTruth.rawValue ?? "nil") → displayed=yellow (unconfirmed)")
                #endif
            } else {
                #if DEBUG
                print("✅ Hysteresis gate: raw=green, yesterday=green → displayed=green (confirmed)")
                #endif
            }
        }

        // Action derives from the RAW verdict, not the hysteresis-gated display truth.
        // A pure display-hold (rawTruth green, truth held amber for one-day confirmation)
        // must not issue a behavioral "reduce effort" recommendation — only genuine caution
        // (load- or recovery-driven yellow/red, where rawTruth itself is not green) stays
        // authoritative. Sick/high-pain still hard-bias to reduce cost.
        var action = rawTruth
        if manual.isSick || pain >= 7 { action = .red }

        // “Push permission” (general)
        let canPushKeyLift: Bool =
            (truth == .green)
            && !hrvDown10
            && !rhrUp3
            && !tempUp03
            && !rrUp10
            && !sleepEffLow
            && pain <= 2
            && !manual.isSick
            && loadMod >= -1

        // Output strings. Single source of truth: the card (ReadinessPresentation) and the
        // Watch (WatchRootView reads actionTitle/actionMessage directly off the result) both
        // inherit these — so the gate-hold narration is authored HERE, not in presentation().
        let actionTitle: String
        let actionMessage: String

        // Gate hold: raw verdict is green but the display is held amber for one-day
        // confirmation. action is green here (see above) while truth is amber — narrate the
        // split rather than emitting a bare-green "train normally" with no reason for the amber.
        let gateHoldGreen = (action == .green && truth == .yellow)

        if gateHoldGreen {
            actionTitle = ReadinessHoldCopy.title
            actionMessage = ReadinessHoldCopy.message
        } else {
            switch action {
            case .green:
                actionTitle = canPushKeyLift ? "Train normally (push allowed)" : "Train normally"
                actionMessage = canPushKeyLift
                    ? "Run plan as written. You may push one key lift if form stays clean and effort is honest."
                    : "Run plan as written. Keep it clean—no extra cost or hero sets today."
            case .yellow:
                actionTitle = "Train with guardrails"
                actionMessage = """
                Run the plan, but avoid top-end effort. Stay honest with RIR and skip any push or intensifier work. If something feels off early, adjust instead of forcing it.
                """
            case .red:
                actionTitle = "Reduce cost today"
                actionMessage = "Reduce: choose the lowest-cost version of training (lighter loads and/or fewer sets). No intensifiers, no grinders."
            }
        }

        // Keep flags short and useful
        let uniqueFlags = Array(Dictionary(grouping: flags, by: { $0 }).keys).prefix(6)

        // DEBUG: explain readiness inputs + scoring
        #if DEBUG
        func fmt(_ x: Double?) -> String { x == nil ? "nil" : String(format: "%.2f", x!) }
        func fmtPct(_ x: Double?) -> String { x == nil ? "nil" : String(format: "%.1f%%", x! * 100) }

        let hrvCur = today?.hrvMS
        let rhrCur = today?.restingHR
        let sleepCur = today?.sleepHours
        let inBedCur = today?.sleepInBedHours
        let effCur = efficiency(asleep: sleepCur, inBed: inBedCur)
        let tempCur = today?.wristTempDeltaC
        let spo2Cur = today?.spo2Pct
        let rrCur = today?.respiratoryRate

        let hrvDeltaPct: Double? = (hrvCur != nil && hrvBase != nil && hrvBase! > 0) ? ((hrvCur! - hrvBase!) / hrvBase!) : nil
        let rhrDeltaAbs: Double? = (rhrCur != nil && rhrBase != nil) ? (rhrCur! - rhrBase!) : nil
        let sleepDeltaAbs: Double? = (sleepCur != nil) ? (sleepCur! - sleepTarget) : nil
        let tempDeltaAbs: Double? = (tempCur != nil && tempBase != nil) ? (tempCur! - tempBase!) : nil
        let spo2DeltaAbs: Double? = (spo2Cur != nil && spo2Base != nil) ? (spo2Cur! - spo2Base!) : nil
        let rrDeltaAbs: Double? = (rrCur != nil && rrBase != nil) ? (rrCur! - rrBase!) : nil
        let effDeltaAbs: Double? = (effCur != nil && effBase != nil) ? (effCur! - effBase!) : nil

        #if DEBUG
        if let r = today?.restingHR, !(r >= 35 && r <= 110) {
            print("🧾 RHR ignored as implausible: \(r)")
        }
        if let h = today?.hrvMS, !(h >= 5 && h <= 250) {
            print("🧾 HRV ignored as implausible: \(h)")
        }
        #endif
        
        print("🧠 Readiness Debug")
        print("  Today:   HRV=\(fmt(hrvCur)) RHR=\(fmt(rhrCur)) Sleep=\(fmt(sleepCur)) InBed=\(fmt(inBedCur)) Eff=\(fmt(effCur)) RR=\(fmt(rrCur)) Temp=\(fmt(tempCur)) SpO2=\(fmt(spo2Cur))")
        print("  Base:    HRV=\(fmt(hrvBase)) RHR=\(fmt(rhrBase)) SleepBase=\(fmt(sleepBase)) SleepTarget=\(String(format: "%.2f", sleepTarget)) EffBase=\(fmt(effBase)) RRBase=\(fmt(rrBase)) TempBase=\(fmt(tempBase)) SpO2=\(fmt(spo2Base))")
        print("  Δ:       HRV=\(fmtPct(hrvDeltaPct)) RHR=\(fmt(rhrDeltaAbs)) Sleep=\(fmt(sleepDeltaAbs)) Eff=\(fmt(effDeltaAbs)) RR=\(fmt(rrDeltaAbs)) Temp=\(fmt(tempDeltaAbs)) SpO2=\(fmt(spo2DeltaAbs))")
        print("  Scores:  HRV(raw)=\(hrvScore) HRV(adj)=\(adjustedHRVScore) buffered=\(hrvBufferedByStrongRecovery) RHR=\(rhrScore) Sleep=\(sleepScore) Eff=\(sleepEffScore) RR=\(rrScore) Temp=\(tempScore) SpO2=\(spo2Score) pain=\(painScore) sick=\(sickScore) recovery=\(recoveryScore) load=\(loadMod) total=\(total)")
        print("  Cluster: hrvDown10=\(hrvDown10) hrvTrend=\(hrvDownTrend) hrvConcern=\(hrvConcern) rhrUp3=\(rhrUp3) sleepShort1=\(sleepShort1) sleepEffLow=\(sleepEffLow) rrUp10=\(rrUp10) tempUp03=\(tempUp03) sick=\(sickFlag) count=\(clusterCount) forceY=\(forceYellow) forceR=\(forceRed)")
        print("  Convergence: bonus=\(convergenceBonus) clusterCount=\(clusterCount)")
        print("  Output:  truth=\(truth.title) action=\(action.title) canPush=\(canPushKeyLift)")
        #endif

        
        
        let hrvDeltaMS: Double? = {
                    guard let pct = hrvDeltaPct, let base = hrvBase else { return nil }
                    return pct * base
                }()

        let effDeltaForResult: Double? = {
                            guard let cur = efficiency(asleep: today?.sleepHours, inBed: today?.sleepInBedHours),
                                  let base = effBase else { return nil }
                            return cur - base
                        }()

        let availableCoreSignals = [
            today?.restingHR != nil,
            today?.hrvMS != nil,
            today?.sleepHours != nil,
            today?.respiratoryRate != nil,
            today?.wristTempDeltaC != nil,
            today?.spo2Pct != nil
        ].filter { $0 }.count

        let availableHighTrustSignals = [
            today?.restingHR != nil,
            today?.sleepHours != nil,
            today?.respiratoryRate != nil
        ].filter { $0 }.count

        let conflictingSignals = (
            hrvScore < 0 &&
            rhrScore >= 0 &&
            sleepScore >= 0 &&
            sleepEffScore >= 0 &&
            rrScore >= 0 &&
            tempScore >= 0
        )

        let signalAgreementCount = [
            hrvScore < 0,
            rhrScore < 0,
            sleepScore < 0,
            sleepEffScore < 0,
            rrScore < 0,
            tempScore < 0,
            spo2Score < 0,
            painScore < 0,
            sickScore < 0
        ].filter { $0 }.count

        let confidence: ReadinessConfidence = {
            if availableHighTrustSignals < 2 || availableCoreSignals < 3 {
                return .low
            }

            if conflictingSignals {
                return .medium
            }

            if availableHighTrustSignals >= 3 && availableCoreSignals >= 5 && signalAgreementCount >= 2 {
                return .high
            }

            if availableHighTrustSignals >= 3 && availableCoreSignals >= 5 && signalAgreementCount == 0 {
                return .high
            }

            return .medium
        }()
        
        var drivers: [ReadinessDriver] = []

        // Short, signal-naming reason text — distinct from MetricDetailView's
        // longer "X% above/below baseline" interpretation text.
        func driverReason(_ label: String, isNegative: Bool) -> String {
            switch (label, isNegative) {
            case ("HRV", true):              return "Below baseline — often an early stress or recovery signal."
            case ("HRV", false):              return "Above baseline — a positive recovery signal."
            case ("RHR", true):               return "Elevated vs baseline — may reflect fatigue, illness, or strain."
            case ("RHR", false):              return "Below baseline — a positive recovery signal."
            case ("Sleep", true):             return "Short vs target — recovery and performance both take a hit."
            case ("Sleep", false):            return "Above your target — a strong recovery night."
            case ("Sleep Efficiency", true):  return "Fragmented sleep — even with adequate duration."
            case ("Respiratory Rate", true):  return "Elevated overnight — frequently precedes other symptoms."
            case ("Wrist Temp", true):        return "Above baseline — worth watching for illness or inflammation."
            case ("SpO2", true):              return "Lower than usual overnight — can be noisy, watch for repeat patterns."
            case ("Pain", true):              return "Reported pain is elevated — train around it."
            case ("Sick", true):              return "Marked sick — recovery takes priority over training."
            default:                          return "Off from baseline."
            }
        }

        func addDriver(_ label: String, _ score: Int, consecutiveFlag: KeyPath<DailyVerdictRecord, Bool>? = nil) {
            guard score != 0 else { return }

            let isNegative = score < 0

            // Cluster flags only describe negative/concerning states, so only
            // look up a streak when this driver is actually a negative one.
            let consecutiveDays: Int = {
                guard isNegative, let kp = consecutiveFlag else { return 0 }
                return SharedStore.consecutiveDaysActive(flag: kp, asOf: todayISO)
            }()

            drivers.append(
                ReadinessDriver(
                    label: label,
                    impact: abs(score),
                    isNegative: isNegative,
                    reason: driverReason(label, isNegative: isNegative),
                    consecutiveDays: consecutiveDays
                )
            )
        }

        addDriver("HRV", adjustedHRVScore, consecutiveFlag: \.hrvDown10)
        addDriver("RHR", rhrScore, consecutiveFlag: \.rhrUp4)
        addDriver("Sleep", sleepScore, consecutiveFlag: \.sleepShort1)
        // Label is "Sleep Efficiency" (not "Sleep Quality") so the readiness driver row
        // doesn't collide with the SleepQualityEngine composite tile, which is titled
        // "Sleep Quality" and can validly show the opposite verdict (they're different
        // metrics: engine efficiency vs multi-axis composite). Still fires off sleepEffScore.
        addDriver("Sleep Efficiency", sleepEffScore, consecutiveFlag: \.sleepEffLow)
        addDriver("Respiratory Rate", rrScore, consecutiveFlag: \.rrUp10)
        addDriver("Wrist Temp", tempScore, consecutiveFlag: \.tempUp03)
        addDriver("SpO2", spo2Score)
        addDriver("Pain", painScore)
        addDriver("Sick", sickScore, consecutiveFlag: \.sick)

        let topDrivers = drivers
            .sorted { $0.impact > $1.impact }
            .prefix(3)
        
        let cardioLoad = today?.dailyTrimp ?? 0
        let mechanicalLoad = MechanicalLoadReader.read(for: Date())

        return ReadinessResult(
            truth: truth,
            rawTruth: rawTruth,
            action: action,
            confidence: confidence,
            flags: Array(uniqueFlags),
            drivers: Array(topDrivers),
            actionTitle: actionTitle,
            actionMessage: actionMessage,
            canPushKeyLift: canPushKeyLift,
            rhrDelta: rhrDeltaAbs,
            hrvDelta: hrvDeltaMS,
            sleepDelta: sleepDeltaAbs,
            tempDelta: tempDeltaAbs,
            rrDelta: rrDeltaAbs,
            effDelta: effDeltaForResult,
            cardioLoad: cardioLoad,
            mechanicalLoad: mechanicalLoad,
            totalScore: total
        )
    }
}
