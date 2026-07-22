import SwiftUI
import ShannonCore

@main
struct ShannonWatchApp: App {
    @StateObject private var relay = WatchRelay()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(relay)
                .task { relay.activate() }
        }
    }
}
