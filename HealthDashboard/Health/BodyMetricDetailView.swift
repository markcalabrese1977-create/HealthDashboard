import SwiftUI

// MARK: - Body metric kind

enum BodyMetric: String, Identifiable {
    case weight
    case bodyFat
    case leanMass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weight:   return "Weight"
        case .bodyFat:  return "Body Fat"
        case .leanMass: return "Lean Mass"
        }
    }

    var unit: String {
        switch self {
        case .weight:   return "lb"
        case .bodyFat:  return "%"
        case .leanMass: return "lb"
        }
    }

    var systemImage: String {
        switch self {
        case .weight:   return "scalemass"
        case .bodyFat:  return "percent"
        case .leanMass: return "figure.strengthtraining.traditional"
        }
    }

    var higherIsBetter: Bool {
        switch self {
        case .weight:   return false
        case .bodyFat:  return false
        case .leanMass: return true
        }
    }

    var formatDigits: Int {
        switch self {
        case .bodyFat: return 1
        default:       return 1
        }
    }

    func values(from history: [DailyHealthPoint]) -> [Double?] {
        history.map { point in
            switch self {
            case .weight:   return point.bodyWeightLb
            case .bodyFat:  return point.bodyFatPct
            case .leanMass: return point.leanMassLb
            }
        }
    }

    func formatValue(_ v: Double) -> String {
        String(format: "%.\(formatDigits)f \(unit)", v)
    }

    var explanation: String {
        switch self {
        case .weight:
            return "Body weight fluctuates 1–3 lb daily due to hydration, food volume, and glycogen. Weekly averages are more meaningful than individual readings. A consistent downward trend of 0.5–1 lb per week indicates a sustainable fat loss rate. Faster losses often include lean mass."
        case .bodyFat:
            return "Body fat percentage from a smart scale uses bioelectrical impedance, which is sensitive to hydration state. The trend over weeks matters more than any single reading. For accuracy, weigh at the same time daily under similar conditions. DXA provides the most accurate snapshot."
        case .leanMass:
            return "Lean mass is everything that isn't fat — muscle, bone, water, and organs. Preserving lean mass during a cut is the key marker of effective training. A stable or rising lean mass while weight drops indicates fat loss without muscle loss, which is the goal."
        }
    }
}

// MARK: - Linear regression helper

private func linearTrend(values: [Double]) -> (slope: Double, intercept: Double)? {
    guard values.count >= 3 else { return nil }
    let n = Double(values.count)
    let xs = (0..<values.count).map { Double($0) }
    let sumX = xs.reduce(0, +)
    let sumY = values.reduce(0, +)
    let sumXY = zip(xs, values).map { $0 * $1 }.reduce(0, +)
    let sumX2 = xs.map { $0 * $0 }.reduce(0, +)
    let denom = n * sumX2 - sumX * sumX
    guard denom != 0 else { return nil }
    let slope = (n * sumXY - sumX * sumY) / denom
    let intercept = (sumY - slope * sumX) / n
    return (slope, intercept)
}

// MARK: - Detail view

struct BodyMetricDetailView: View {
    let metric: BodyMetric
    let history: [DailyHealthPoint]
    let dxaScans: [DXAScan]

    private var allValues: [Double?] { metric.values(from: history) }
    private var presentValues: [Double] { allValues.compactMap { $0 } }
    private var presentWithIndex: [(Int, Double)] {
        allValues.enumerated().compactMap { i, v in v.map { (i, $0) } }
    }

    private var latestValue: Double? { presentValues.last }

    private var weeklyRateOfChange: Double? {
        guard let trend = linearTrend(values: presentValues) else { return nil }
        return trend.slope * 7.0
    }

    private var allTimeMin: Double? { presentValues.min() }
    private var allTimeMax: Double? { presentValues.max() }

    private var avg28: Double? {
        guard !presentValues.isEmpty else { return nil }
        return presentValues.reduce(0, +) / Double(presentValues.count)
    }

    private var latestDXA: DXAScan? {
        dxaScans.max(by: { $0.dateISO < $1.dateISO })
    }

    private var dxaValue: Double? {
        switch metric {
        case .weight:   return latestDXA?.weightLb
        case .bodyFat:  return latestDXA?.bodyFatPct
        case .leanMass: return latestDXA?.leanMassLb
        }
    }

    private var leanMassPreservation: String? {
        guard metric == .weight,
              let weightTrend = linearTrend(values: history.compactMap { $0.bodyWeightLb }),
              let leanVals = {
                  let v = history.compactMap { $0.leanMassLb }
                  return v.count >= 3 ? v : nil
              }(),
              let leanTrend = linearTrend(values: leanVals)
        else { return nil }

        let weeklyWeightChange = weightTrend.slope * 7.0
        let weeklyLeanChange = leanTrend.slope * 7.0

        if abs(weeklyWeightChange) < 0.2 { return nil }

        if weeklyWeightChange < -0.2 {
            if weeklyLeanChange >= -0.1 {
                return "Lean mass is stable while weight is dropping — good sign of fat-focused loss."
            } else if weeklyLeanChange < -0.3 {
                return "Lean mass is declining alongside weight loss. Consider increasing protein intake or reducing training volume cut."
            } else {
                return "Minor lean mass fluctuation during weight loss — monitor over coming weeks."
            }
        }
        return nil
    }

    private var rateLabel: String {
        guard let rate = weeklyRateOfChange else { return "--" }
        let sign = rate > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", rate)) \(metric.unit)/week"
    }

    private var rateColor: Color {
        guard let rate = weeklyRateOfChange else { return .secondary }
        let favorable = metric.higherIsBetter ? rate > 0 : rate < 0
        return abs(rate) < 0.05 ? .secondary : favorable ? .green : .orange
    }

    private var trendLinePoints: [CGPoint]? {
        guard let trend = linearTrend(values: presentValues),
              let minV = presentValues.min(),
              let maxV = presentValues.max(),
              presentValues.count >= 3 else { return nil }
        let range = max(maxV - minV, 0.001)
        let count = allValues.count
        return [0, Double(count - 1)].map { x in
            let y = trend.slope * x + trend.intercept
            let xFrac = count > 1 ? x / Double(count - 1) : 0
            let yFrac = 1.0 - (y - minV) / range
            return CGPoint(x: xFrac, y: max(0, min(1, yFrac)))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Hero
                VStack(alignment: .leading, spacing: 4) {
                    if let v = latestValue {
                        Text(metric.formatValue(v))
                            .font(.system(size: 48, weight: .bold, design: .rounded))

                        Text(rateLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(rateColor)
                    } else {
                        Text("--")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("No data available")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)

                // MARK: Chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("28-day history")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ZStack {
                        Sparkline(
                            values: allValues,
                            lineWidth: 2.5,
                            height: 100,
                            showDot: true,
                            showRangeBand: false
                        )
                        .frame(height: 100)

                        // Trend line overlay
                        if let pts = trendLinePoints {
                            GeometryReader { geo in
                                Path { path in
                                    let start = CGPoint(
                                        x: pts[0].x * geo.size.width,
                                        y: pts[0].y * geo.size.height
                                    )
                                    let end = CGPoint(
                                        x: pts[1].x * geo.size.width,
                                        y: pts[1].y * geo.size.height
                                    )
                                    path.move(to: start)
                                    path.addLine(to: end)
                                }
                                .stroke(
                                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                                )
                                .foregroundStyle(rateColor.opacity(0.7))
                            }
                            .frame(height: 100)
                        }
                    }
                    .frame(height: 100)

                    HStack(spacing: 12) {
                        if weeklyRateOfChange != nil {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(rateColor.opacity(0.6))
                                    .frame(width: 6, height: 6)
                                Text("Trend: \(rateLabel)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1))

                // MARK: Stats grid
                VStack(alignment: .leading, spacing: 8) {
                    Text("Statistics")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        BodyStatCell(label: "Current", value: latestValue.map { metric.formatValue($0) } ?? "--")
                        BodyStatCell(label: "28-day avg", value: avg28.map { metric.formatValue($0) } ?? "--")
                        BodyStatCell(label: "Personal low", value: allTimeMin.map { metric.formatValue($0) } ?? "--")
                        BodyStatCell(label: "Personal high", value: allTimeMax.map { metric.formatValue($0) } ?? "--")
                    }
                }

                // MARK: DXA comparison
                if let dxa = dxaValue, let latest = latestValue {
                    let diff = latest - dxa
                    let sign = diff > 0 ? "+" : ""
                    let diffStr = "\(sign)\(String(format: "%.\(metric.formatDigits)f", diff)) \(metric.unit)"

                    VStack(alignment: .leading, spacing: 8) {
                        Text("DXA comparison")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text("Last DXA (\(fmtDXADate(latestDXA?.dateISO)))")
                                                            .font(.caption2)
                                                            .foregroundStyle(.secondary)
                                                        Text(metric.formatValue(dxa))
                                                            .font(.subheadline.weight(.semibold))
                                                    }
                                                    Spacer()
                                                    VStack(alignment: .trailing, spacing: 4) {
                                                        Text("Change since DXA")
                                                            .font(.caption2)
                                                            .foregroundStyle(.secondary)
                                                        Text(diffStr)
                                                            .font(.subheadline.weight(.semibold))
                                                            .foregroundStyle(diffColor(diff: diff))
                                                    }
                                                }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.systemBackground)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1))
                    }
                }

                // MARK: Lean mass preservation note
                if let note = leanMassPreservation {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Lean mass signal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1))
                }

                // MARK: About
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
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1))
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.large)
    }

    private func diffColor(diff: Double) -> Color {
            if abs(diff) < 0.5 { return .secondary }
            if metric.higherIsBetter { return diff > 0 ? .green : .orange }
            return diff < 0 ? .green : .orange
        }
    
    private func fmtDXADate(_ iso: String?) -> String {
        guard let iso else { return "--" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Stat cell

private struct BodyStatCell: View {
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
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1))
    }
}

