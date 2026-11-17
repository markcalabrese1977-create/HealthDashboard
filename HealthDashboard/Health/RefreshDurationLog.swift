import Foundation

// App-target only. Where a refresh came from, and (DEBUG only) a ring buffer of how long recent
// refreshes took, so a hang can be told apart from a slow fetch.

enum RefreshSource: String {
    case userTap, autoLoop, foreground, observer
}

/// Set by the fetch closure when it learns whether it attached to an in-flight fetch.
final class RefreshProbe {
    var joined = false
}

#if DEBUG
struct RefreshDurationEntry: Codable, Equatable {
    var date: Date
    var ms: Int
    var outcome: String      // success | error | timeout
    var source: String
    var joined: Bool
}

struct RefreshDurationSummary: Equatable {
    var count: Int
    var p50: Int
    var p90: Int
    var max: Int
    var timeouts: Int
}

enum RefreshDurationLog {
    static let key = "debug.refreshDurations.v1"
    static let capacity = 50

    private static var defaults: UserDefaults? { UserDefaults(suiteName: SharedStore.appGroupID) }

    static func milliseconds(_ d: Duration) -> Int {
        let c = d.components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }

    static func line(_ e: RefreshDurationEntry) -> String {
        "⏱ refresh: \(e.ms) ms, outcome=\(e.outcome), source=\(e.source), joined=\(e.joined)"
    }

    static func record(_ entry: RefreshDurationEntry) {
        print(line(entry))
        var all = load()
        all.append(entry)
        if all.count > capacity { all.removeFirst(all.count - capacity) }
        if let data = try? JSONEncoder().encode(all) { defaults?.set(data, forKey: key) }
    }

    static func load() -> [RefreshDurationEntry] {
        guard let data = defaults?.data(forKey: key),
              let all = try? JSONDecoder().decode([RefreshDurationEntry].self, from: data) else { return [] }
        return all
    }

    /// Nearest-rank percentiles over the stored entries.
    static func summary(of entries: [RefreshDurationEntry]) -> RefreshDurationSummary {
        let sorted = entries.map(\.ms).sorted()
        func pct(_ p: Double) -> Int {
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((p * Double(sorted.count)).rounded(.up))
            return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank - 1))]
        }
        return RefreshDurationSummary(
            count: sorted.count,
            p50: pct(0.5),
            p90: pct(0.9),
            max: sorted.last ?? 0,
            timeouts: entries.filter { $0.outcome == "timeout" }.count
        )
    }

    static func dumpRefreshDurations() {
        let s = summary(of: load())
        print("⏱ refreshDurations: count=\(s.count) p50=\(s.p50) ms p90=\(s.p90) ms max=\(s.max) ms timeouts=\(s.timeouts)")
    }
}
#endif
