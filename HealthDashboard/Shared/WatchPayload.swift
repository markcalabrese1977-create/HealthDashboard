import Foundation

/// Encapsulates everything the Watch needs to display.
/// Sent from the iPhone via WatchConnectivity applicationContext, and cached by
/// the Watch app in its own App Group UserDefaults so the complication and a
/// fresh app launch can show the last-known state before a new context arrives.
///
/// The Watch never computes this itself — it only decodes what the iPhone sends.
struct WatchPayload: Codable {
    var result: ReadinessResult
    var last7Days: [DailyHealthPoint]   // most-recent first
    var updatedAt: Date
}
