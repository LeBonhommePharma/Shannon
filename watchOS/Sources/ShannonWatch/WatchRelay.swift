import Foundation
import SwiftUI
import ShannonCore
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
#if canImport(WatchKit)
import WatchKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Receives snapshots from the iPhone and republishes them to the views and
/// the complication. The watch does no computation and never queries
/// CloudKit — it is a display relay, as designed.
@MainActor
final class WatchRelay: NSObject, ObservableObject {
    @Published private(set) var snapshot = ShannonSnapshot()
    @Published private(set) var lastReceivedAt: Date?

    func activate() {
        // A cached snapshot means the first frame after a wrist raise shows
        // real state instead of an empty list while the phone reconnects.
        if let cached = WatchSnapshotCache.load() {
            snapshot = cached
        }
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    /// Playback taps go to the phone, which owns the CloudKit write.
    func send(_ command: PlaybackCommand) {
        #if canImport(WatchConnectivity)
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["command": command.rawValue], replyHandler: nil) { _ in }
        #endif
        playHaptic(.click)
    }

    fileprivate func apply(_ fresh: ShannonSnapshot) {
        snapshot = fresh
        lastReceivedAt = Date()
        WatchSnapshotCache.save(fresh)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    #if canImport(WatchKit)
    fileprivate func playHaptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
    #else
    enum WKHapticType { case click, success, notification }
    fileprivate func playHaptic(_ type: WKHapticType) {}
    #endif

    /// Taptic feedback for an alert forwarded by the phone.
    fileprivate func handleAlert(_ description: String) {
        playHaptic(description.contains("finished") ? .success : .notification)
    }
}

#if canImport(WatchConnectivity)
extension WatchRelay: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let fresh = try? WatchRelayCodec.decode(applicationContext) else { return }
        Task { @MainActor in self.apply(fresh) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        if let fresh = try? WatchRelayCodec.decode(message) {
            Task { @MainActor in self.apply(fresh) }
        }
        if let alert = message["alert"] as? String {
            Task { @MainActor in self.handleAlert(alert) }
        }
    }
}
#endif
