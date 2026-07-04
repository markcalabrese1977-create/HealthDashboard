import SwiftUI

@main
struct HealthDashboardWatchApp: App {
    @StateObject private var receiver = WatchSessionReceiver.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(receiver)
        }
    }
}
