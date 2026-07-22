import Foundation
import Observation
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

/// Which screen the Digital Crown is currently on. One screen at a time, in a
/// fixed order, so the crown always means the same thing.
public enum WatchScreen: Int, CaseIterable, Sendable {
    case face
    case agents
    case nowPlaying
    case notifications

    public var title: String {
        switch self {
        case .face:          return "Shannon"
        case .agents:        return "Agents"
        case .nowPlaying:    return "Playing"
        case .notifications: return "Alerts"
        }
    }
}

/// Receives snapshots from the iPhone and republishes them to the views and
/// the complication. The watch does no computation and never queries CloudKit
/// itself — it is a display relay, which is what keeps its battery out of the
/// sync path.
@available(watchOS 10.0, *)
@MainActor
@Observable
public final class WatchModel: NSObject {
    public private(set) var snapshot = ShannonSnapshot()
    public private(set) var lastReceivedAt: Date?
    /// Set immediately on an answer so the card can confirm before the phone
    /// has acknowledged anything.
    public private(set) var lastAnswer: (answer: ConfirmationAnswer, at: Date)?

    public var screen: WatchScreen = .face
    /// Digital Crown position, mapped onto `screen`.
    public var crownPosition: Double = 0

    @ObservationIgnored private var motion: WristMotionMonitor?

    public override init() {
        super.init()
    }

    public var pendingConfirmation: PendingConfirmation? {
        snapshot.oldestPendingConfirmation()
    }

    public var isAwaitingConfirmation: Bool { pendingConfirmation != nil }

    public func activate() {
        // A cached snapshot means the first frame after a wrist raise shows
        // real state instead of a spinner. Never show a loading state.
        if let cached = SnapshotCache.watch.load() {
            snapshot = cached
        }

        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif

        let monitor = WristMotionMonitor()
        monitor.onFlick = { [weak self] in
            // A wrist flick brings the face back, so Shannon is one gesture
            // away even when the app is showing another screen.
            guard let self else { return }
            withTaptic(.click) { self.screen = .face }
        }
        monitor.start()
        motion = monitor
    }

    public func deactivate() {
        motion?.stop()
        motion = nil
    }

    // MARK: Crown navigation

    public func screen(forCrown value: Double) -> WatchScreen {
        let index = Int(value.rounded())
        let clamped = min(max(index, 0), WatchScreen.allCases.count - 1)
        return WatchScreen(rawValue: clamped) ?? .face
    }

    public func crownChanged(to value: Double) {
        let next = screen(forCrown: value)
        guard next != screen else { return }
        // Detent feedback: the crown should feel like it clicks between
        // screens rather than sliding continuously.
        withTaptic(.click) { screen = next }
    }

    /// Crown press / back gesture returns home.
    public func goHome() {
        guard screen != .face else { return }
        crownPosition = 0
        withTaptic(.click) { screen = .face }
    }

    // MARK: Actions

    /// The Double Tap target, and the tap target, for whichever screen is
    /// showing. Contextual by design: one gesture, obvious meaning.
    public func primaryAction() {
        switch screen {
        case .face:
            if isAwaitingConfirmation {
                answer(.confirmed, source: .doubleTap)
            }
        case .nowPlaying:
            send(.togglePlayPause)
        case .agents, .notifications:
            goHome()
        }
    }

    public func answer(_ answer: ConfirmationAnswer, source: ConfirmationSource) {
        guard let pending = pendingConfirmation else { return }
        // Optimistic: drop it from the local snapshot now, tell the phone
        // after. The card must never linger while a radio round-trip happens.
        snapshot.confirmations.removeAll { $0.id == pending.id }
        lastAnswer = (answer, Date())
        SnapshotCache.watch.save(snapshot)

        playHaptic(answer == .confirmed ? .success : .failure)
        relay(.answer(id: pending.id, answer: answer, source: source))
    }

    public func send(_ command: PlaybackCommand) {
        playHaptic(.click)
        relay(.command(command))
    }

    /// Commands and answers go to the phone, which owns the CloudKit write.
    private func relay(_ message: WatchMessage) {
        #if canImport(WatchConnectivity)
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        guard let payload = try? WatchMessageCodec.encode(message) else { return }
        session.sendMessage(payload, replyHandler: nil) { _ in }
        #endif
    }

    // MARK: Inbound

    fileprivate func apply(_ fresh: ShannonSnapshot) {
        let wasAwaiting = isAwaitingConfirmation
        snapshot = fresh
        lastReceivedAt = Date()
        SnapshotCache.watch.save(fresh)

        #if canImport(WidgetKit)
        // This is what meets the "under 15 s from Mac state change" target:
        // the phone relays on every CloudKit change, and the complication
        // reloads here rather than waiting for its own timeline budget.
        WidgetCenter.shared.reloadAllTimelines()
        #endif

        // A newly arrived question taps and jumps to the face, which is the
        // only screen that can answer it.
        if !wasAwaiting, isAwaitingConfirmation {
            playHaptic(.notification)
            screen = .face
            crownPosition = 0
        }
    }

    /// Background-refresh entry point: adopt a cached snapshot without
    /// replaying its alerts as haptics.
    public func applyCached(_ cached: ShannonSnapshot) {
        guard cached.capturedAt > snapshot.capturedAt else { return }
        snapshot = cached
        lastReceivedAt = Date()
    }

    fileprivate func handleAlert(_ description: String) {
        playHaptic(description.contains("finished") ? .success : .notification)
    }

    // MARK: Haptics

    #if canImport(WatchKit)
    public func playHaptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
    #else
    public enum WKHapticType { case click, success, failure, notification }
    public func playHaptic(_ type: WKHapticType) {}
    #endif

    private func withTaptic(_ type: WKHapticType, _ change: () -> Void) {
        playHaptic(type)
        change()
    }
}

#if canImport(WatchConnectivity)
@available(watchOS 10.0, *)
extension WatchModel: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated public func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let message = try? WatchMessageCodec.decode(applicationContext),
              case .snapshot(let fresh) = message else { return }
        Task { @MainActor in self.apply(fresh) }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard let decoded = try? WatchMessageCodec.decode(message) else { return }
        Task { @MainActor in
            switch decoded {
            case .snapshot(let fresh): self.apply(fresh)
            case .alert(let text):     self.handleAlert(text)
            case .command, .answer:    break   // watch → phone only
            }
        }
    }
}
#endif
