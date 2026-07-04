import WidgetKit
import SwiftUI

// Reads the same App Group cache that WatchSessionReceiver writes to whenever the
// Watch app receives a fresh applicationContext from the iPhone — so the
// complication updates automatically without any HealthKit access or computation
// of its own. Pure display, same as the Watch app itself.

private let watchAppGroupID = "group.com.calabrese.healthdashboard.watch"
private let watchPayloadCacheKey = "watchPayloadCache"

private func loadCachedPayload() -> WatchPayload? {
    guard let data = UserDefaults(suiteName: watchAppGroupID)?.data(forKey: watchPayloadCacheKey),
          let payload = try? JSONDecoder().decode(WatchPayload.self, from: data) else { return nil }
    return payload
}

struct ReadinessComplicationEntry: TimelineEntry {
    let date: Date
    let payload: WatchPayload?
}

struct ReadinessComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReadinessComplicationEntry {
        ReadinessComplicationEntry(date: Date(), payload: loadCachedPayload())
    }

    func getSnapshot(in context: Context, completion: @escaping (ReadinessComplicationEntry) -> Void) {
        completion(ReadinessComplicationEntry(date: Date(), payload: loadCachedPayload()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReadinessComplicationEntry>) -> Void) {
        let entry = ReadinessComplicationEntry(date: Date(), payload: loadCachedPayload())
        // Single entry — there's nothing to forecast since the iPhone pushes updates
        // asynchronously via WatchConnectivity whenever a refresh completes (which
        // reloads this widget's timeline directly). This policy just tells WidgetKit
        // a reasonable fallback point to ask for a redraw if no push has happened by then.
        let timeline = Timeline(
            entries: [entry],
            policy: .after(Date().addingTimeInterval(12 * 60 * 60))
        )
        completion(timeline)
    }
}

struct WatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ReadinessComplicationEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularComplicationView(payload: entry.payload)
        case .accessoryRectangular:
            RectangularComplicationView(payload: entry.payload)
        default:
            RectangularComplicationView(payload: entry.payload)
        }
    }
}

private struct CircularComplicationView: View {
    let payload: WatchPayload?

    private var status: ReadinessStatus { payload?.result.truth ?? .yellow }
    private var score: Int { payload?.result.totalScore ?? 0 }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Circle()
                .fill(WatchVerdictPalette.color(for: status))
            Text(score > 0 ? "+\(score)" : "\(score)")
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
        }
    }
}

private struct RectangularComplicationView: View {
    let payload: WatchPayload?

    private var status: ReadinessStatus { payload?.result.truth ?? .yellow }
    private var score: Int { payload?.result.totalScore ?? 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(WatchVerdictPalette.color(for: status))
                .frame(width: 8, height: 8)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(WatchVerdictPalette.verdictLabel(for: status).uppercased())
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(score > 0 ? "+\(score)" : "\(score)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WatchComplication: Widget {
    let kind: String = "WatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ReadinessComplicationProvider()) { entry in
            WatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Readiness")
        .description("Today's recovery verdict and score.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

@main
struct WatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        WatchComplication()
    }
}
