import Foundation
import Combine
import ShannonCore
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone → Watch relay. The watch never queries CloudKit in the common case:
/// it renders whatever the phone last handed it, which keeps the watch's
/// radio and battery out of the sync path.
@MainActor
final class PhoneWatchRelay: NSObject, ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    /// Coalesces bursts — an agent that ticks several times a second must not
    /// produce one WatchConnectivity message per tick.
    private var lastSentAt = Date.distantPast
    private let minimumInterval: TimeInterval = 2
    private var pending: ShannonSnapshot?
    private var flushTimer: Timer?

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    func observe(store: ShannonStore) {
        store.$snapshot
            .sink { [weak self] snapshot in self?.send(snapshot) }
            .store(in: &cancellables)
    }

    /// Uses `updateApplicationContext`, which keeps only the latest payload
    /// queued — exactly the semantics wanted for a state mirror.
    func send(_ snapshot: ShannonSnapshot) {
        pending = snapshot
        let elapsed = Date().timeIntervalSince(lastSentAt)
        guard elapsed >= minimumInterval else {
            scheduleFlush(in: minimumInterval - elapsed)
            return
        }
        flush()
    }

    private func scheduleFlush(in delay: TimeInterval) {
        guard flushTimer == nil else { return }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushTimer = nil
                self?.flush()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        flushTimer = t
    }

    private func flush() {
        guard let snapshot = pending else { return }
        pending = nil
        lastSentAt = Date()
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext(try WatchRelayCodec.encode(snapshot))
        } catch {
            // A failed relay is not worth surfacing — the watch keeps showing
            // its previous snapshot and the next update will carry the state.
        }
        #endif
    }

    /// Alerts travel as a separate immediate message so the watch can tap even
    /// when the throttled state update has not gone out yet.
    func notifyWatch(of alert: SnapshotAssembler.Alert) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["alert": Self.describe(alert)], replyHandler: nil) { _ in }
        #endif
    }

    static func describe(_ alert: SnapshotAssembler.Alert) -> String {
        switch alert {
        case .docking(.targetCompleted(let benchmark, let done, let total)):
            return "\(benchmark) \(done)/\(total)"
        case .docking(.benchmarkFinished(let benchmark)):
            return "\(benchmark) finished"
        case .agentErrored(let name):
            return "\(name) errored"
        case .agentFinished(let name):
            return "\(name) finished"
        case .notification(let note):
            return "\(note.sender): \(note.title)"
        }
    }
}

#if canImport(WatchConnectivity)
extension PhoneWatchRelay: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// After a watch switch the session must be reactivated, or the relay goes
    /// permanently silent.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// The watch can issue playback commands too; the phone forwards them to
    /// CloudKit for the Mac to execute.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard let raw = message["command"] as? String,
              let command = PlaybackCommand(rawValue: raw) else { return }
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .shannonWatchCommand, object: nil, userInfo: ["command": command]
            )
        }
    }
}
#endif

extension Notification.Name {
    static let shannonWatchCommand = Notification.Name("shannonWatchCommand")
}
