import WidgetKit
import SwiftUI

// MARK: - Timeline

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), projection: SharedStore.loadWidgetProjection())
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: Date(), projection: SharedStore.loadWidgetProjection()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let entry = SimpleEntry(date: Date(), projection: SharedStore.loadWidgetProjection())

        // Refresh every 30 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)

        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Entry
//
// Dumb mirror: the widget renders exactly what the app last projected, via
// SharedStore.loadWidgetProjection(). It must never call ReadinessEngine.evaluate()
// itself — that both diverges from the app's own verdict and writes to the shared
// hysteresis gate log (SharedStore.appendVerdictLog) from a second, unsynchronized
// process. `projection` is nil only when the app has never written one yet.

struct SimpleEntry: TimelineEntry {
    let date: Date
    let projection: WidgetProjection?
}

// MARK: - View

struct HealthDashboardWidgetEntryView: View {
    let entry: Provider.Entry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var isSmall: Bool { family == .systemSmall }

    // Dumb mirror: everything rendered comes from the app's last projection.
    // nil only when the app has never written one (fresh install, App Group not yet
    // populated) — rendered as an explicit neutral placeholder, never a guessed verdict.
    private var projection: WidgetProjection? { entry.projection }

    private var rhrSeries: [Double?] { projection?.rhrSeries ?? [] }
    private var hrvSeries: [Double?] { projection?.hrvSeries ?? [] }
    private var sleepSeries: [Double?] { projection?.sleepSeries ?? [] }

    private var readinessLine: String {
        guard let projection else { return "No data yet" }
        return "\(projection.truth.title) · \(projection.flagCount) flag" + (projection.flagCount == 1 ? "" : "s")
    }

    private var statusPillText: String { projection?.truth.title ?? "—" }

    // Layout tuning (keeps it from “jumping”)
    private var outerPadding: CGFloat { isSmall ? 10 : 12 }
    private var stackSpacing: CGFloat { isSmall ? 4 : 6 }
    private var rowSpacing: CGFloat { isSmall ? 1 : 2 }

    private var labelFont: Font { isSmall ? .caption2 : .caption }
    private var valueFont: Font {
        isSmall
        ? .system(size: 24, weight: .bold)
        : .system(size: 30, weight: .bold)
    }

    private var sparkHeight: CGFloat { isSmall ? 12 : 16 }
    private var sparkWidth: CGFloat { isSmall ? 78 : 92 }

    // MARK: - Light-ink styling (fixes light mode “washed out”)
    private var headerColor: Color { Color.white.opacity(0.70) }
    private var labelColor: Color { Color.white.opacity(0.55) }
    private var valueColor: Color { Color.white.opacity(0.95) }
    private var inkShadow: Color { Color.black.opacity(0.60) }
    private var shadowRadius: CGFloat { 2 }

    // MARK: - Background tuning (more punch in light mode)
    private var bgLeft: Double  { colorScheme == .light ? 0.82 : 0.78 }
    private var bgMid: Double   { colorScheme == .light ? 0.62 : 0.55 }
    private var bgRight: Double { colorScheme == .light ? 0.26 : 0.22 }

    var body: some View {
        VStack(alignment: .leading, spacing: stackSpacing) {
            headerCompact

            metricRow(label: "RHR",
                      value: projection.map { "\($0.rhr)" } ?? "—",
                      series: rhrSeries)

            metricRow(label: "HRV",
                      value: projection.map { "\($0.hrv) ms" } ?? "—",
                      series: hrvSeries)

            metricRow(label: "Sleep",
                      value: projection.map { String(format: "%.1f h", $0.sleepHours) } ?? "—",
                      series: sleepSeries)
        }
        .padding(outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            ZStack {
                // Photo layer
                Image("WidgetBackground")
                    .resizable()
                    .scaledToFill()
                    .clipped()

                // Readability layer: darker left, lighter right
                LinearGradient(
                    colors: [
                        Color.black.opacity(bgLeft),
                        Color.black.opacity(bgMid),
                        Color.black.opacity(bgRight)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                // Vignette to keep corners/edges clean (helps “card” feel)
                RadialGradient(
                    colors: [
                        Color.black.opacity(0.05),
                        Color.black.opacity(0.55)
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: 260
                )

                // ✅ OPTIONAL "glass" polish (subtle highlight + thin border)
                // Delete this whole block if you decide "no glass".
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.06),
                                Color.white.opacity(0.00),
                                Color.black.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .padding(2)
            }
        }
    }

    private var headerCompact: some View {
        HStack(alignment: .center) {
            Text(isSmall ? readinessLine : "Health Snapshot")
                .font(.caption.bold())
                .foregroundStyle(headerColor)
                .shadow(color: inkShadow, radius: shadowRadius, x: 0, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 6)

            Text(statusPillText)
                .font(.caption2.bold())
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.horizontal, isSmall ? 8 : 10)
                .padding(.vertical, isSmall ? 4 : 5)
                .background(pillBackground)
                .clipShape(Capsule())
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var pillBackground: Color {
        guard let truth = projection?.truth else {
            return Color(.systemGray).opacity(0.22)   // no projection yet — neutral, not a guessed verdict
        }
        switch truth {
        case .green: return Color(.systemGreen).opacity(0.22)
        case .yellow: return Color(.systemOrange).opacity(0.22)
        case .red: return Color(.systemRed).opacity(0.22)
        }
    }

    @ViewBuilder
    private func metricRow(label: String, value: String, series: [Double?]) -> some View {
        HStack(alignment: .center, spacing: isSmall ? 8 : 10) {
            VStack(alignment: .leading, spacing: rowSpacing) {
                Text(label)
                    .font(labelFont)
                    .foregroundStyle(labelColor)
                    .shadow(color: inkShadow, radius: shadowRadius, x: 0, y: 1)
                    .lineLimit(1)

                Text(value)
                    .font(valueFont)
                    .foregroundStyle(valueColor)
                    .shadow(color: inkShadow, radius: shadowRadius, x: 0, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 6)

            Sparkline(values: series, height: sparkHeight, showDot: true, showRangeBand: true)
                .frame(width: sparkWidth, height: sparkHeight)
                .environment(\.colorScheme, .dark)     // ✅ forces white-ish strokes
                .opacity(0.95)
        }
    }
}

// MARK: - Widget

@main
struct HealthDashboardWidget: Widget {
    let kind: String = "HealthDashboardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HealthDashboardWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Health Dashboard")
        .description("Shows your latest health snapshot.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
