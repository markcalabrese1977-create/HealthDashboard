import WatchConnectivity
import WidgetKit
import Foundation

/// Watch-side half of the bridge. Pure consumer — it never computes anything,
/// never queries HealthKit, and never sends anything back to the iPhone. It only
/// decodes whatever WatchPayload the iPhone last pushed via applicationContext,
/// and caches the raw bytes in the Watch's own App Group UserDefaults so the
/// complication (a separate process) and a fresh app launch can read the last
/// known state immediately, before a new context arrives.
final class WatchSessionReceiver: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionReceiver()

    @Published var payload: WatchPayload? = nil

    private let appGroupID = "group.com.calabrese.healthdashboard.watch"
    private let cacheKey = "watchPayloadCache"

    override private init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        loadCached()
    }

    // MARK: - WCSessionDelegate
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["payload"] as? Data,
              let payload = try? JSONDecoder().decode(WatchPayload.self, from: data) else { return }
        DispatchQueue.main.async {
            self.payload = payload
            self.saveCache(data)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    // MARK: - Persistence (so Watch + complication show last known data after relaunch)
    private func saveCache(_ data: Data) {
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: cacheKey)
        // Nudge the complication to redraw now rather than waiting for its
        // fallback timeline policy (~12h) — it reads from the same cache.
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func loadCached() {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: cacheKey),
              let payload = try? JSONDecoder().decode(WatchPayload.self, from: data) else { return }
        self.payload = payload
    }
}
