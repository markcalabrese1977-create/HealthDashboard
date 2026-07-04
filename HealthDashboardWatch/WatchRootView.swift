import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var receiver: WatchSessionReceiver

    var body: some View {
        Group {
            if let payload = receiver.payload {
                TabView {
                    VerdictTab(payload: payload)
                        .tag(0)

                    SignalsTab(payload: payload)
                        .tag(1)
                }
                .tabViewStyle(.page)
                .containerBackground(.black, for: .tabView)
            } else {
                NoDataPlaceholder()
                    .containerBackground(.black, for: .tabView)
            }
        }
    }
}

// MARK: - Favorability (display-only — maps an already-computed delta to a
// green/yellow/red status using the same 3-state vocabulary as ReadinessStatus,
// purely for Watch-side coloring. Does not reproduce any ReadinessEngine scoring.)

private func favorability(_ delta: Double?, higherIsBetter: Bool, noiseThreshold: Double) -> ReadinessStatus {
    guard let d = delta else { return .yellow }
    if abs(d) < noiseThreshold { return .yellow }
    let favorable = higherIsBetter ? d > 0 : d < 0
    return favorable ? .green : .red
}

private func arrow(_ d: Double) -> String { d >= 0 ? "↑" : "↓" }

private func fmtSleepHM(_ hours: Double?) -> String {
    guard let hours else { return "--" }
    let totalMinutes = Int((hours * 60).rounded())
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    return "\(h)h \(m)m"
}

// MARK: - Tab 1: Today's verdict

private struct VerdictTab: View {
    let payload: WatchPayload

    private var result: ReadinessResult { payload.result }
    private var today: DailyHealthPoint? { payload.last7Days.first }

    // HRV is shown as a % delta (matching how the iPhone app frames HRV moves) —
    // derived locally from the already-computed result.hrvDelta (ms) and today's
    // raw value, since ReadinessResult only exposes the absolute-ms delta.
    private var hrvPctDelta: Double? {
        guard let delta = result.hrvDelta, let cur = today?.hrvMS else { return nil }
        let base = cur - delta
        guard base > 0 else { return nil }
        return delta / base
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(WatchVerdictPalette.color(for: result.truth).opacity(0.25), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: 1)
                        .stroke(WatchVerdictPalette.color(for: result.truth), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 2) {
                        Text(WatchVerdictPalette.verdictLabel(for: result.truth))
                            .font(.headline.weight(.bold))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)

                        Text(signedScore(result.totalScore))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 120)
                .padding(.top, 6)

                // Engine's own recommendation strings — not reconstructed on the Watch.
                VStack(spacing: 2) {
                    Text(result.actionTitle)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)

                    Text(result.actionMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding(.horizontal, 4)

                Divider()
                    .padding(.vertical, 2)

                VStack(spacing: 6) {
                    VerdictSignalRow(
                        name: "HRV",
                        value: fmtInt(today?.hrvMS, unit: "ms"),
                        delta: hrvPctDelta,
                        deltaText: hrvPctDelta.map { "\(arrow($0))\(Int((abs($0) * 100).rounded()))%" },
                        status: favorability(hrvPctDelta, higherIsBetter: true, noiseThreshold: 0.05)
                    )
                    VerdictSignalRow(
                        name: "RHR",
                        value: fmtInt(today?.restingHR, unit: nil),
                        delta: result.rhrDelta,
                        deltaText: result.rhrDelta.map { "\(arrow($0))\(Int(abs($0).rounded()))bpm" },
                        status: favorability(result.rhrDelta, higherIsBetter: false, noiseThreshold: 2)
                    )
                    VerdictSignalRow(
                        name: "Sleep",
                        value: fmtSleepHM(today?.sleepHours),
                        delta: result.sleepDelta,
                        deltaText: result.sleepDelta.map { "\(arrow($0))\(String(format: "%.1f", abs($0)))h" },
                        status: favorability(result.sleepDelta, higherIsBetter: true, noiseThreshold: 0.3)
                    )
                }

                Text("Updated \(payload.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func signedScore(_ v: Int) -> String {
        v > 0 ? "+\(v)" : "\(v)"
    }

    private func fmtInt(_ v: Double?, unit: String?) -> String {
        guard let v else { return "--" }
        let n = "\(Int(v.rounded()))"
        return unit.map { "\(n) \($0)" } ?? n
    }
}

private struct VerdictSignalRow: View {
    let name: String
    let value: String
    let delta: Double?
    let deltaText: String?
    let status: ReadinessStatus

    var body: some View {
        HStack {
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Spacer(minLength: 0)

            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()

            Spacer(minLength: 0)

            Text(deltaText ?? "--")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(WatchVerdictPalette.color(for: status))
                .frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - Tab 2: Signal tiles

private struct SignalsTab: View {
    let payload: WatchPayload

    private var today: DailyHealthPoint? { payload.last7Days.first }
    private var result: ReadinessResult { payload.result }

    // Sleep Quality composite (Phase 5) rides along on the payload's ReadinessResult;
    // the Watch no longer recomputes the raw efficiency ratio. Nil ⇒ no composite this
    // push (pre-first-fetch or an unstaged .unavailable night) ⇒ tile shows no secondary.
    private var sleepQualityText: String? {
        guard let sq = result.sleepQuality, sq != .unavailable else { return nil }
        return "Qual \(Int(sq.composite.rounded()))"
    }

    private let compactColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                LazyVGrid(columns: compactColumns, spacing: 8) {
                    SignalTile(
                        name: "HRV",
                        value: fmt(today?.hrvMS, digits: 0),
                        unit: "ms",
                        delta: result.hrvDelta,
                        deltaText: result.hrvDelta.map { "\(arrow($0))\(String(format: "%.0f", abs($0)))ms" },
                        status: favorability(result.hrvDelta, higherIsBetter: true, noiseThreshold: 1)
                    )
                    SignalTile(
                        name: "RHR",
                        value: fmt(today?.restingHR, digits: 0),
                        unit: "bpm",
                        delta: result.rhrDelta,
                        deltaText: result.rhrDelta.map { "\(arrow($0))\(String(format: "%.0f", abs($0)))bpm" },
                        status: favorability(result.rhrDelta, higherIsBetter: false, noiseThreshold: 2)
                    )
                    SignalTile(
                        name: "Resp Rate",
                        value: fmt(today?.respiratoryRate, digits: 1),
                        unit: "br/min",
                        delta: result.rrDelta,
                        deltaText: result.rrDelta.map { "\(arrow($0))\(String(format: "%.1f", abs($0)))" },
                        status: favorability(result.rrDelta, higherIsBetter: false, noiseThreshold: 1)
                    )
                    SignalTile(
                        name: "Wrist Temp",
                        value: result.tempDelta.map { "\(arrow($0))\(String(format: "%.1f", abs($0)))°" } ?? "--",
                        unit: "",
                        delta: nil,
                        deltaText: nil,
                        status: favorability(result.tempDelta, higherIsBetter: false, noiseThreshold: 0.2)
                    )
                }

                SignalTile(
                    name: "Sleep",
                    value: fmtSleepHM(today?.sleepHours),
                    unit: "",
                    secondaryValue: sleepQualityText,
                    delta: result.sleepDelta,
                    deltaText: result.sleepDelta.map { "\(arrow($0))\(String(format: "%.1f", abs($0)))h" },
                    status: favorability(result.sleepDelta, higherIsBetter: true, noiseThreshold: 0.3),
                    fullWidth: true
                )

                if let ml = today?.mechanicalLoad, ml > 0 {
                    SignalTile(
                        name: "Mechanical Load",
                        value: fmt(ml, digits: 0),
                        unit: "",
                        delta: nil,
                        deltaText: nil,
                        status: .yellow,
                        fullWidth: true
                    )
                }

                if let trimp = today?.dailyTrimp, trimp > 0 {
                    SignalTile(
                        name: "TRIMP",
                        value: fmt(trimp, digits: 0),
                        unit: "",
                        delta: nil,
                        deltaText: nil,
                        status: .yellow,
                        fullWidth: true
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }

    private func fmt(_ v: Double?, digits: Int) -> String {
        guard let v else { return "--" }
        return String(format: "%.\(digits)f", v)
    }
}

private struct SignalTile: View {
    let name: String
    let value: String
    let unit: String
    var secondaryValue: String? = nil
    let delta: Double?
    let deltaText: String?
    let status: ReadinessStatus
    var fullWidth: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let secondaryValue {
                Text(secondaryValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let deltaText {
                HStack {
                    Spacer()
                    DeltaBadge(text: deltaText, status: status)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(WatchVerdictPalette.color(for: status))
                .frame(width: 7, height: 7)
                .padding(6)
        }
    }
}

private struct DeltaBadge: View {
    let text: String
    let status: ReadinessStatus

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(WatchVerdictPalette.color(for: status))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(WatchVerdictPalette.color(for: status).opacity(0.18))
            )
    }
}

// MARK: - No-data placeholder (before the Watch has ever received a payload)

private struct NoDataPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("Open HealthDashboard on iPhone to sync")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
