import Foundation
import ShannonCore
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone → Watch relay. The watch never queries CloudKit in the common case:
/// it renders whatever the phone last handed it, which keeps the watch's radio
/// and battery out of the sync path.
///
/// State goes out via `updateApplicationContext` (latest-wins, system-coalesced,
/// cheap). Only genuinely time-critical things — an alert to tap for, a command
/// to relay — use `sendMessage`.
@MainActor
public final class PhoneWatchRelay: NSObject {
    public var onWatchCommand: ((PlaybackCommand) -> Void)?
    public var onWatchAnswer: ((ConfirmationAnswer, ConfirmationSource) -> Void)?

    /// Coalesces bursts — an agent that ticks several times a second must not
    /// produce one WatchConnectivity update per tick.
    private var lastSentAt = Date.distantPast
    private let minimumInterval: TimeInterval = 2
    private var pending: ShannonSnapshot?
    private var flushTask: Task<Void, Never>?

    public func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    public func send(_ snapshot: ShannonSnapshot) {
        pending = snapshot
        let elapsed = Date().timeIntervalSince(lastSentAt)

        // A pending question bypasses throttling: the watch showing it two
        // seconds late is the difference between answering from the wrist and
        // walking back to the desk.
        if snapshot.isAwaitingConfirmation || elapsed >= minimumInterval {
            flush()
            return
        }
        scheduleFlush(in: minimumInterval - elapsed)
    }

    private func scheduleFlush(in delay: TimeInterval) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    private func flush() {
        guard let snapshot = pending else { return }
        pending = nil
        lastSentAt = Date()

        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard let payload = try? WatchMessageCodec.encode(.snapshot(snapshot)) else { return }
        // A failed relay is not worth surfacing — the watch keeps showing its
        // previous snapshot and the next update carries the state.
        try? session.updateApplicationContext(payload)
        #endif
    }

    /// Alerts travel as an immediate message so the watch can tap even when
    /// the throttled state update has not gone out yet.
    public func notifyWatch(of alert: SnapshotAssembler.Alert) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        guard let payload = try? WatchMessageCodec.encode(.alert(Self.describe(alert))) else {
            return
        }
        session.sendMessage(payload, replyHandler: nil) { _ in }
        #endif
    }

    public static func describe(_ alert: SnapshotAssembler.Alert) -> String {
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
        case .confirmationRequested(let pending):
            return pending.question
        }
    }

    private func handle(_ message: WatchMessage) {
        switch message {
        case .command(let command):
            onWatchCommand?(command)
        case .answer(_, let answer, let source):
            onWatchAnswer?(answer, source)
        case .snapshot, .alert:
            // Phone → watch only.
            break
        }
    }
}

#if canImport(WatchConnectivity)
extension PhoneWatchRelay: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}

    /// After a watch switch the session must be reactivated, or the relay goes
    /// permanently silent.
    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard let decoded = try? WatchMessageCodec.decode(message) else { return }
        Task { @MainActor in self.handle(decoded) }
    }

    /// The watch sends gate answers with a reply handler so it can show a
    /// delivered state; the reply is the ack, its content is irrelevant.
    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        replyHandler(["ok": true])
        guard let decoded = try? WatchMessageCodec.decode(message) else { return }
        Task { @MainActor in self.handle(decoded) }
    }

    /// Gate answers queued while the phone was unreachable arrive here once
    /// connectivity returns. Without this handler they would be received by
    /// the system and dropped on the floor.
    nonisolated public func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        guard let decoded = try? WatchMessageCodec.decode(userInfo) else { return }
        Task { @MainActor in self.handle(decoded) }
    }
}
#endif
