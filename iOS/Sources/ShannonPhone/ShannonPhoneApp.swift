import SwiftUI
import Combine
import ShannonCore

@main
struct ShannonPhoneApp: App {
    @StateObject private var environment = PhoneEnvironment()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(environment)
                .task { environment.start() }
        }
    }
}

/// Owns the store, the watch relay and the haptic engine, and wires them
/// together. The phone is the only device that talks to CloudKit directly;
/// the watch is fed from here.
@MainActor
final class PhoneEnvironment: ObservableObject {
    let store: ShannonStore
    private let relay = PhoneWatchRelay()
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    init(backend: ShannonSyncBackend? = nil) {
        let resolved = backend ?? PhoneEnvironment.defaultBackend()
        self.store = ShannonStore(backend: resolved, interval: 30)
    }

    /// Falls back to an empty in-memory backend when CloudKit is unavailable
    /// (Simulator without an iCloud account, or a build without the
    /// entitlement) so the app still launches and shows its empty state.
    private static func defaultBackend() -> ShannonSyncBackend {
        #if canImport(CloudKit) && !targetEnvironment(simulator)
        return CloudKitSyncBackend()
        #else
        return InMemorySyncBackend()
        #endif
    }

    func start() {
        guard !started else { return }
        started = true

        store.onAlert = { [weak self] alert in
            Haptics.play(for: alert)
            self?.relay.notifyWatch(of: alert)
        }
        relay.activate()
        store.start()

        // Push the freshly fetched state to the watch on every change.
        relay.observe(store: store)

        // The widget extension has no access to this process's store, so each
        // snapshot is mirrored into the App Group container for it to read.
        store.$snapshot
            .sink { WidgetSnapshotStore.save($0) }
            .store(in: &cancellables)

        // Playback commands tapped on the watch arrive via the relay and are
        // forwarded to CloudKit from here — the watch never writes directly.
        NotificationCenter.default.addObserver(
            forName: .shannonWatchCommand, object: nil, queue: .main
        ) { [weak self] note in
            guard let command = note.userInfo?["command"] as? PlaybackCommand else { return }
            Task { @MainActor in self?.store.send(command, origin: "Apple Watch") }
        }
    }

    func send(_ command: PlaybackCommand) {
        store.send(command, origin: "iPhone")
        Haptics.tap()
    }
}
