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
    private let minimumInterval: TimeInterval = WatchRelayThrottle.defaultMinimumInterval
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
        if WatchRelayThrottle.shouldSendImmediately(
            isAwaitingConfirmation: snapshot.isAwaitingConfirmation,
            elapsedSinceLastSend: elapsed,
            minimumInterval: minimumInterval
        ) {
            flush()
            return
        }
        scheduleFlush(
            in: WatchRelayThrottle.scheduleDelay(
                elapsedSinceLastSend: elapsed,
                minimumInterval: minimumInterval
            )
        )
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

    private func cancelScheduledFlush() {
        flushTask?.cancel()
        flushTask = nil
    }

    /// Delivers the latest pending snapshot if the session can accept it.
    /// Fail-closed on transport: never advances the throttle clock or clears
    /// `pending` unless the context update was accepted. A dropped early
    /// snapshot (pre-activation) is kept and retried from
    /// `activationDidComplete`.
    private func flush() {
        guard let snapshot = pending else { return }

        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else {
            // No WatchConnectivity on this build — nothing to deliver.
            pending = nil
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            // Keep pending; activationDidComplete will retry. Do not pretend
            // we sent — that would throttle the real first delivery.
            return
        }
        guard let payload = try? WatchMessageCodec.encode(.snapshot(snapshot)) else {
            // Unencodable payload would infinite-loop if kept; drop it.
            pending = nil
            return
        }
        do {
            try session.updateApplicationContext(payload)
            pending = nil
            lastSentAt = Date()
            cancelScheduledFlush()
        } catch {
            // Keep pending for the next send / activation. The watch continues
            // showing its previous snapshot — never invent a fresher one.
        }
        #else
        pending = nil
        #endif
    }

    /// Alerts travel as an immediate message so the watch can tap even when
    /// the throttled state update has not gone out yet.
    ///
    /// Fail-closed when the watch is unreachable: `sendMessage` requires a live
    /// link. We do not queue fake delivery — the confirmation still rides the
    /// application-context snapshot (which bypasses the throttle).
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

// MARK: - Pure throttle policy

/// Pure send/throttle decision for the phone→watch relay.
///
/// Extracted so the policy is reviewable without WCSession, and ready to
/// promote into ShannonCore tests if the orchestrator wants package coverage.
public enum WatchRelayThrottle: Sendable {
    public static let defaultMinimumInterval: TimeInterval = 2

    /// Confirmation prompts always go out immediately; otherwise wait out the
    /// minimum interval since the last *successful* application-context update.
    public static func shouldSendImmediately(
        isAwaitingConfirmation: Bool,
        elapsedSinceLastSend: TimeInterval,
        minimumInterval: TimeInterval = defaultMinimumInterval
    ) -> Bool {
        isAwaitingConfirmation || elapsedSinceLastSend >= minimumInterval
    }

    public static func scheduleDelay(
        elapsedSinceLastSend: TimeInterval,
        minimumInterval: TimeInterval = defaultMinimumInterval
    ) -> TimeInterval {
        max(0, minimumInterval - elapsedSinceLastSend)
    }
}

#if canImport(WatchConnectivity)
extension PhoneWatchRelay: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        // First CloudKit refresh can finish before WCSession activates. Flush
        // any snapshot we held rather than waiting up to a full poll interval.
        guard state == .activated else { return }
        Task { @MainActor in self.flush() }
    }

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
