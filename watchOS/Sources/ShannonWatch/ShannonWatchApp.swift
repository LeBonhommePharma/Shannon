import SwiftUI
import ShannonCore
#if canImport(WatchKit)
import WatchKit
#endif

@main
@available(watchOS 10.0, *)
struct ShannonWatchApp: App {
    @State private var model = WatchModel()
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .task {
                    model.activate()
                    delegate.model = model
                }
        }
    }
}

/// Handles background refresh so the face is fresh the moment the wrist comes
/// up. The watch itself does not fetch from CloudKit — it asks the phone for
/// the latest snapshot and schedules the next wake.
@available(watchOS 10.0, *)
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    @MainActor var model: WatchModel?

    func applicationDidFinishLaunching() {
        scheduleRefresh(after: 15 * 60)
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                // Reloading the cached snapshot is enough to keep the
                // complication warm; the phone pushes anything newer.
                Task { @MainActor in
                    if let cached = SnapshotCache.watch.load() {
                        self.model?.applyCached(cached)
                    }
                }
                scheduleRefresh(after: 15 * 60)
                refresh.setTaskCompletedWithSnapshot(true)

            case let snapshotTask as WKSnapshotRefreshBackgroundTask:
                snapshotTask.setTaskCompleted(
                    restoredDefaultState: true,
                    estimatedSnapshotExpiration: .distantFuture,
                    userInfo: nil
                )

            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    private func scheduleRefresh(after interval: TimeInterval) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: nil
        ) { _ in }
    }
}
