import WatchConnectivity
import Foundation

/// iPhone-side half of the Watch bridge. Sends-only — the iPhone never reads
/// anything back from the Watch. All computation (HealthKit fetches, the
/// readiness engine) stays on the iPhone; this just hands the Watch the
/// already-computed result via WatchConnectivity's applicationContext, which
/// is the right transport here since we only ever care about the *latest*
/// state, not a queue of historical updates.
final class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    override private init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func send(_ payload: WatchPayload) {
        guard WCSession.default.isPaired && WCSession.default.isWatchAppInstalled else { return }
        guard WCSession.default.activationState == .activated else { return }
        do {
            let data = try JSONEncoder().encode(payload)
            try WCSession.default.updateApplicationContext(["payload": data])
            #if DEBUG
            print("⌚ WatchSessionManager: sent payload updatedAt=\(payload.updatedAt)")
            #endif
        } catch {
            print("⌚ WatchSessionManager: send failed \(error)")
        }
    }

    // MARK: - WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
