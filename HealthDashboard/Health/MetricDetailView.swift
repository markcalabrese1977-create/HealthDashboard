import SwiftUI

// MARK: - Metric kind

enum HealthMetric: String, Identifiable {
    case rhr
    case hrv
    case sleep
    case wristTemp
    case respRate
    case sleepEff
    case sleepEfficiency
    case spo2
    case trainingLoad
    case strengthLoad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rhr:      return "Resting HR"
        case .hrv:      return "HRV"
        case .sleep:    return "Sleep"
        case .wristTemp: return "Wrist Temp"
        case .respRate: return "Resp Rate"
        case .sleepEff:         return "Sleep Quality"
        case .sleepEfficiency:  return "Sleep Efficiency"
        case .spo2:             return "SpO2"
        case .trainingLoad: return "Training Load"
        case .strengthLoad: return "Strength Load"
        }
    }

    var unit: String {
        switch self {
        case .rhr:      return "bpm"
        case .hrv:      return "ms"
        case .sleep:    return "h"
        case .wristTemp: return "°C"
        case .respRate: return "br/min"
        case .sleepEff:         return ""
        case .sleepEfficiency:  return "%"
        case .spo2:             return "%"
        case .trainingLoad: return ""
        case .strengthLoad: return ""
        }
    }

    var systemImage: String {
        switch self {
        case .rhr:      return "heart.fill"
        case .hrv:      return "waveform.path.ecg"
        case .sleep:    return "bed.double.fill"
        case .wristTemp: return "thermometer"
        case .respRate: return "lungs.fill"
        case .sleepEff:         return "bed.double.fill"
        case .sleepEfficiency:  return "bed.double.fill"
        case .spo2:             return "drop.fill"
        case .trainingLoad: return "bolt.heart.fill"
        case .strengthLoad: return "dumbbell.fill"
        }
    }

    var higherIsBetter: Bool {
        switch self {
        case .rhr, .wristTemp, .respRate: return false
        case .trainingLoad, .strengthLoad: return false
        case .hrv, .sleep, .sleepEff, .sleepEfficiency, .spo2: return true
        }
    }

    var explanation: String {
        switch self {
        case .rhr:
            return "Resting heart rate reflects cardiovascular efficiency and recovery state. A lower value than your baseline suggests good recovery. Elevated values — especially combined with low HRV — often indicate accumulated fatigue, stress, or early illness."
        case .hrv:
            return "Heart rate variability measures variation between heartbeats during sleep. Higher values indicate your autonomic nervous system is in a parasympathetic (recovery) state. HRV is the most sensitive early signal of training stress, poor sleep, or oncoming illness."
        case .sleep:
            return "Total asleep time is the foundation of recovery. Consistently hitting your personal target supports hormone regulation, muscle repair, and cognitive function. Even one night significantly below baseline meaningfully impairs next-day performance."
        case .wristTemp:
            return "Wrist skin temperature during sleep deviates from your personal baseline when your body is fighting inflammation, illness, or significant physical stress. Elevations above +0.3°C above your baseline are worth monitoring alongside other signals."
        case .respRate:
            return "Breathing rate during sleep is a sensitive early warning signal. Elevated respiratory rate — even 1–2 br/min above your baseline — often appears 1–2 days before other illness symptoms become obvious. It also rises with significant training load."
        case .sleepEff:
            return "Sleep Quality is a 0–100 composite of sleep architecture (deep/REM/core vs your baseline), duration against a dynamic need, efficiency (latency + wake-after-onset), fragmentation (discrete awakenings), and schedule consistency. Each night is scored against an expanding baseline of your prior nights; the 28-day chart is the composite over time."
        case .sleepEfficiency:
            return "Sleep efficiency measures how much of your time in bed was actually spent asleep (asleep ÷ in-bed, minimum 5-minute gap required). A lower value than your 28-day norm flags fragmented nights or trouble falling asleep. It is a supporting recovery signal — noisy on its own, meaningful in combination with HRV and RHR trends."
        case .spo2:
            return "Blood oxygen saturation measures how well your lungs are oxygenating your blood during sleep. Values consistently below your personal baseline may indicate breathing disruptions during sleep."
        case .trainingLoad:
            return "Training Load (TRIMP) quantifies cardiovascular training stress using the Bannister formula — workout duration scaled by intensity relative to your max and resting HR. Scores elevated above your baseline indicate a high-stress training day; tracking trends over 7–28 days reveals accumulated fatigue or effective load management."
        case .strengthLoad:
            return "Strength Load is an intensity-weighted volume score from ElitePerformance, calculated as Σ(load × reps × load/e1RM) per set. It captures both volume and relative intensity. Track trends over 7–28 days alongside TRIMP to monitor total training stress across modalities."
        }
    }

    func values(from history: [DailyHealthPoint]) -> [Double?] {
        history.map { point in
            switch self {
            case .rhr:      return point.restingHR
            case .hrv:      return point.hrvMS
            case .sleep:    return point.sleepHours
            case .wristTemp: return point.wristTempDeltaC
            case .respRate: return point.respiratoryRate
            case .sleepEff:
                // Composite series (Phase 6 precondition): the persisted per-night score.
                return point.sleepCompositeScore
            case .sleepEfficiency:
                return ReadinessEngine.efficiency(asleep: point.sleepHours, inBed: point.sleepInBedHours)
            case .spo2:         return point.spo2Pct
            case .trainingLoad:  return point.dailyTrimp
            case .strengthLoad:  return point.mechanicalLoad
            }
        }
    }

    func formatValue(_ v: Double) -> String {
        switch self {
        case .rhr:      return "\(Int(v.rounded())) bpm"
        case .hrv:      return "\(Int(v.rounded())) ms"
        case .sleep:
            let h = Int(v)
            let m = Int((v - Double(h)) * 60)
            return "\(h)h \(m)m"
        case .wristTemp: return String(format: "%+.1f °C", v)
        case .respRate: return String(format: "%.1f br/min", v)
        case .sleepEff:         return "\(Int(v.rounded()))"
        case .sleepEfficiency:  return "\(Int((v * 100).rounded()))%"
        case .spo2:             return "\(Int(v.rounded()))%"
        case .trainingLoad:  return "\(Int(v.rounded()))"
        case .strengthLoad:  return v >= 1000 ? String(format: "%.1fK", v / 1000) : "\(Int(v.rounded()))"
        }
    }
}

// MARK: - Detail view

struct MetricDetailView: View {
    let metric: HealthMetric
    let history: [DailyHealthPoint]
    let readiness: ReadinessResult

    private var allValues: [Double?] { metric.values(from: history) }
    private var presentValues: [Double] { allValues.compactMap { $0 } }

    private var baseline: Double? {
        let base = Array(presentValues.dropLast())
        guard base.count >= 3 else { return nil }
        let sorted = base.sorted()
        if sorted.count % 2 == 1 { return sorted[sorted.count / 2] }
        return (sorted[(sorted.count / 2) - 1] + sorted[sorted.count / 2]) / 2.0
    }

    private var todayValue: Double? { presentValues.last }

    private var sevenDayValues: [Double] { Array(presentValues.suffix(7)) }
    private var sevenDayAvg: Double? {
        guard !sevenDayValues.isEmpty else { return nil }
        return sevenDayValues.reduce(0, +) / Double(sevenDayValues.count)
    }

    private var allTimeMin: Double? { presentValues.min() }
    private var allTimeMax: Double? { presentValues.max() }

    private var delta: Double? {
        guard let t = todayValue, let b = baseline else { return nil }
        return t - b
    }

    private var deltaColor: Color {
        guard let d = delta else { return .secondary }
        let favorable = metric.higherIsBetter ? d >= 0 : d <= 0
        return abs(d) < 0.3 ? .secondary : favorable ? .green : .orange
    }

    private var interpretation: String {
        guard todayValue != nil, let b = baseline, let d = delta else {
            return "Not enough data yet to interpret this metric against your baseline."
        }

        let pct = abs(d / b) * 100
        let direction = d >= 0 ? "above" : "below"
        let favorable = metric.higherIsBetter ? d >= 0 : d <= 0

        let context: String
        if pct < 3 {
            context = "\(metric.title) is within normal variation of your baseline (\(metric.formatValue(b))). No action needed."
        } else if favorable {
            context = "\(metric.title) is \(String(format: "%.0f", pct))% \(direction) your baseline of \(metric.formatValue(b)). This is a positive recovery signal."
        } else if metric == .strengthLoad {
            // Strength Load (mechanicalLoad) is NOT an input to the readiness score — it
            // feeds sleep-quality strain and training-stress trends only. TRIMP (Training
            // Load) does feed readiness via loadMod; mechanicalLoad does not. Don't overclaim.
            context = "\(metric.title) is \(String(format: "%.0f", pct))% \(direction) your baseline of \(metric.formatValue(b)). This adds to your training-stress trend and sleep-quality strain, but it does not currently factor into the readiness score."
        } else {
            context = "\(metric.title) is \(String(format: "%.0f", pct))% \(direction) your baseline of \(metric.formatValue(b)). This is contributing to today's readiness score."
        }

        return context
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Hero value
                if metric == .sleepEff, let sq = readiness.sleepQuality, sq != .unavailable {
                    // Sleep Quality composite (Phase 5) — today-only. The 28-day chart below
                    // stays on the efficiency input series (there is no per-day composite).
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Int(sq.composite.rounded()))")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                        Text("\(sq.verdict.title) · composite / 100")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(sq.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                } else if metric == .sleepEfficiency {
                    // Efficiency hero: values sourced from the engine (same computation the
                    // detractor fired on) — not re-derived from history so the tile's norm
                    // always matches the value that set the readiness flag.
                    VStack(alignment: .leading, spacing: 4) {
                        if let cur = readiness.effCur {
                            Text("\(Int((cur * 100).rounded()))%")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                            if let base = readiness.effBase, let delta = readiness.effDelta {
                                let sign = delta >= 0 ? "+" : ""
                                Text("\(sign)\(String(format: "%.0f", delta * 100)) pp vs \(Int((base * 100).rounded()))% norm")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(delta >= -0.04 ? Color.secondary : Color.orange)
                            } else if let base = readiness.effBase {
                                Text("Norm: \(Int((base * 100).rounded()))%")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("--")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text("Efficiency unavailable last night")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let t = todayValue {
                        Text(metric.formatValue(t))
                            .font(.system(size: 48, weight: .bold, design: .rounded))

                        if let d = delta {
                            let sign = d >= 0 ? "+" : ""
                            let dStr: String = {
                                switch metric {
                                case .sleep:
                                    let h = Int(abs(d))
                                    let m = Int((abs(d) - Double(h)) * 60)
                                    return "\(sign)\(h)h \(m)m vs baseline"
                                case .sleepEff:
                                    return "\(sign)\(String(format: "%.0f", d)) vs baseline"
                                case .sleepEfficiency:
                                    return "\(sign)\(String(format: "%.0f", d * 100)) pp vs norm"
                                case .trainingLoad:
                                    return "\(sign)\(Int(abs(d).rounded())) pts vs baseline"
                                case .strengthLoad:
                                    return "\(sign)\(String(format: "%.1f", abs(d) / 1000))K vs baseline"
                                default:
                                    return "\(sign)\(String(format: "%.1f", d)) \(metric.unit) vs baseline"
                                }
                            }()
                            Text(dStr)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(deltaColor)
                        }
                    } else {
                        Text("--")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("No data for today")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
                }

                // MARK: 28-day chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("28-day history")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ZStack(alignment: .topLeading) {
                        Sparkline(
                                                    values: allValues,
                                                    lineWidth: 2.5,
                                                    height: 100,
                                                    showDot: true,
                                                    showRangeBand: false
                                                )
                        .frame(height: 100)

                        // Baseline reference line
                        if let b = baseline {
                            let present = allValues.compactMap { $0 }
                            let minV = present.min() ?? 0
                            let maxV = present.max() ?? 1
                            let range = max(maxV - minV, 0.0001)
                            let t = (b - minV) / range
                            let yFrac = CGFloat(1.0 - t)

                            GeometryReader { geo in
                                Path { path in
                                    let y = yFrac * geo.size.height
                                    path.move(to: CGPoint(x: 0, y: y))
                                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                                }
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .foregroundStyle(.secondary)
                                .opacity(0.5)
                            }
                            .frame(height: 100)
                        }
                    }
                    .frame(height: 100)

                    if let b = baseline {
                        HStack {
                            Circle()
                                .fill(Color.secondary.opacity(0.4))
                                .frame(width: 6, height: 6)
                            Text("Baseline: \(metric.formatValue(b))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

                // MARK: Stats grid
                VStack(alignment: .leading, spacing: 8) {
                    Text("Statistics")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        StatCell(label: "7-day avg", value: sevenDayAvg.map { metric.formatValue($0) } ?? "--")
                        StatCell(label: "28-day baseline", value: baseline.map { metric.formatValue($0) } ?? "--")
                        StatCell(label: "Personal low", value: allTimeMin.map { metric.formatValue($0) } ?? "--")
                        StatCell(label: "Personal high", value: allTimeMax.map { metric.formatValue($0) } ?? "--")
                    }
                }

                // MARK: Today's context
                VStack(alignment: .leading, spacing: 8) {
                    Text("Today's context")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(interpretation)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

                // MARK: What this measures
                VStack(alignment: .leading, spacing: 8) {
                    Text("About this metric")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(metric.explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Stat cell

private struct StatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}
