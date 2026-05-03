import Foundation

enum ReadinessEngine {

    static func evaluate(history: [DailyHealthPoint], manual: ManualReadinessInputs) -> ReadinessResult {

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

        // HRV score (vs baseline median; cap upside)
        if let cur = today?.hrvMS,
           cur >= 5, cur <= 250,
           let base = hrvBase, base > 0 {
            let d = pctDelta(current: cur, base: base)
            switch d {
            case (-0.05)...(0.05): hrvScore = 0
            case (-0.12)...(-0.05): hrvScore = -1
            case (-0.20)...(-0.12): hrvScore = -2
            case ..<(-0.20): hrvScore = -3
            case (0.05)...(0.12): hrvScore = +1
            default: hrvScore = +2
            }
            if hrvScore < 0 { flags.append("HRV ↓") }
        }

        // RHR score (absolute bpm deviation; cap upside)
        // RHR score (only if plausible)
        if let cur = today?.restingHR,
           cur >= 35, cur <= 110,
           let base = rhrBase {

            let d = cur - base
            if abs(d) <= 3 { rhrScore = 0 }
            else if d > 3 && d <= 5 { rhrScore = -1 }
            else if d > 5 && d <= 8 { rhrScore = -2 }
            else if d > 8 { rhrScore = -3 }
            else if d < -3 && d >= -5 { rhrScore = +1 }
            else if d < -5 { rhrScore = +2 }

            if rhrScore < 0 { flags.append("RHR ↑") }
        }

        // Sleep duration score (asleep hours vs target)
        if let cur = today?.sleepHours {
            let short = sleepTarget - cur
            if short <= 0.5 { sleepScore = 0 }
            else if short <= 1.5 { sleepScore = -1 }
            else if short <= 2.5 { sleepScore = -2 }
            else { sleepScore = -3 }
            if sleepScore < 0 { flags.append("Sleep ↓") }
        }

        // Sleep efficiency score (quality proxy)
        // Goal: catch fragmented nights even when duration looks ok.
        if let effCur = efficiency(asleep: today?.sleepHours, inBed: today?.sleepInBedHours),
           let base = effBase {
            let d = effCur - base
            // Keep this conservative: we only penalize obvious deterioration.
            // Example baseline 0.92 -> 0.84 is meaningful.
            if d >= -0.03 { sleepEffScore = 0 }
            else if d >= -0.07 { sleepEffScore = -1 }
            else { sleepEffScore = -2 }

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

        let recoveryScore =
            hrvScore + rhrScore + sleepScore + sleepEffScore + tempScore + spo2Score + rrScore
            + painScore + sickScore

        // MARK: - Load / Stress modifier (separate from recovery)
        // Still simple spike detector vs baseline medians.
        var loadMod = 0
        if let t = today {

            let workoutEnergyBase = median(baselineSlice.compactMap { $0.workoutEnergyKcal })
            let workoutMinBase    = median(baselineSlice.compactMap { $0.workoutMinutes })

            var workoutLoadScore = 0
            if let base = workoutEnergyBase, let v = t.workoutEnergyKcal, base > 0 {
                if v > base * 1.5 { workoutLoadScore = -2 }
                else if v > base * 1.2 { workoutLoadScore = -1 }
            } else if let base = workoutMinBase, let v = t.workoutMinutes, base > 0 {
                if v > max(base * 1.5, base + 30) { workoutLoadScore = -2 }
                else if v > max(base * 1.2, base + 15) { workoutLoadScore = -1 }
            }

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

        let rhrUp4: Bool = {
            guard let cur = today?.restingHR,
                  cur >= 35, cur <= 110,
                  let base = rhrBase else { return false }
            return (cur - base) >= 4.0
        }()

        let sleepShort1: Bool = {
            guard let cur = today?.sleepHours else { return false }
            return cur <= (sleepTarget - 1.0)
        }()

        let tempUp03: Bool = {
            guard let cur = today?.wristTempDeltaC, let base = tempBase else { return false }
            return (cur - base) >= 0.3
        }()

        let rrUp10: Bool = {
            guard let cur = today?.respiratoryRate, let base = rrBase else { return false }
            return (cur - base) >= 1.0
        }()

        let sleepEffLow: Bool = {
            guard let effCur = efficiency(asleep: today?.sleepHours, inBed: today?.sleepInBedHours),
                  let base = effBase else { return false }
            return (effCur - base) <= -0.05
        }()

        let sickFlag = manual.isSick

        // Cluster now includes: HRV down, RHR up, short sleep, temp up, RR up, sleep quality down, sick
        let clusterCount = [
            hrvDown10, rhrUp4, sleepShort1, tempUp03, rrUp10, sleepEffLow, sickFlag
        ].filter { $0 }.count

        let forceYellow = clusterCount >= 2
        let forceRed = clusterCount >= 3
            || (manual.isSick && (hrvDown10 || rhrUp4 || tempUp03 || sleepShort1 || rrUp10))
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

        // Action defaults to truth; hard-bias to reduce cost if sick/high pain.
        var action = truth
        if manual.isSick || pain >= 7 { action = .red }

        // “Push permission” (general)
        let canPushKeyLift: Bool =
            (truth == .green)
            && !hrvDown10
            && !rhrUp4
            && !tempUp03
            && !rrUp10
            && !sleepEffLow
            && pain <= 2
            && !manual.isSick
            && loadMod >= -1

        // Output strings
        let actionTitle: String
        let actionMessage: String

        switch action {
        case .green:
            actionTitle = canPushKeyLift ? "Train normally (push allowed)" : "Train normally"
            actionMessage = canPushKeyLift
                ? "Run plan as written. You may push one key lift if form stays clean and effort is honest."
                : "Run plan as written. Keep it clean—no extra cost or hero sets today."
        case .yellow:
            actionTitle = "Train with guardrails"
            actionMessage = "Run plan with guardrails: no intensifiers, cap effort (stay ~2 RIR), and treat accessories as optional."
        case .red:
            actionTitle = "Reduce cost today"
            actionMessage = "Reduce: choose the lowest-cost version of training (lighter loads and/or fewer sets). No intensifiers, no grinders."
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
        print("  Scores:  HRV=\(hrvScore) RHR=\(rhrScore) Sleep=\(sleepScore) Eff=\(sleepEffScore) RR=\(rrScore) Temp=\(tempScore) SpO2=\(spo2Score) pain=\(painScore) sick=\(sickScore) recovery=\(recoveryScore) load=\(loadMod) total=\(total)")
        print("  Cluster: hrvDown10=\(hrvDown10) rhrUp4=\(rhrUp4) sleepShort1=\(sleepShort1) sleepEffLow=\(sleepEffLow) rrUp10=\(rrUp10) tempUp03=\(tempUp03) sick=\(sickFlag) count=\(clusterCount) forceY=\(forceYellow) forceR=\(forceRed)")
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

        let confidence: ReadinessConfidence = {
            if availableHighTrustSignals >= 3 && availableCoreSignals >= 5 {
                return .high
            }

            if availableHighTrustSignals >= 2 && availableCoreSignals >= 3 {
                return .medium
            }

            return .low
        }()
        
        var drivers: [ReadinessDriver] = []

        func addDriver(_ label: String, _ score: Int) {
            guard score != 0 else { return }

            let isNegative = score > 0

            drivers.append(
                ReadinessDriver(
                    label: label,
                    impact: abs(score),
                    isNegative: isNegative
                )
            )
        }

        addDriver("HRV", hrvScore)
        addDriver("RHR", rhrScore)
        addDriver("Sleep", sleepScore)
        addDriver("Sleep Quality", sleepEffScore)
        addDriver("Respiratory Rate", rrScore)
        addDriver("Wrist Temp", tempScore)
        addDriver("SpO2", spo2Score)
        addDriver("Pain", painScore)
        addDriver("Sick", sickScore)

        let topDrivers = drivers
            .sorted { $0.impact > $1.impact }
            .prefix(3)
        
        return ReadinessResult(
            truth: truth,
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
            effDelta: effDeltaForResult
        )
    }
}
