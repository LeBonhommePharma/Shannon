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

    /// Whether the paired iPhone is currently reachable for live messages.
    /// Drives the greyed-out gate state — the UI must show "unreachable",
    /// never silently hang.
    public private(set) var isPhoneReachable = false

    /// Where the most recent answer is on its way to the phone.
    public enum AnswerDelivery: Equatable {
        case idle
        /// sendMessage dispatched, waiting for the phone's ack.
        case sending(id: String)
        /// Phone acknowledged the live message.
        case sent(id: String)
        /// Phone unreachable or live send failed; queued via transferUserInfo,
        /// the system delivers it when the phone comes back.
        case queued(id: String)
    }
    public private(set) var delivery: AnswerDelivery = .idle

    public var screen: WatchScreen = .face
    /// Digital Crown position, mapped onto `screen`.
    public var crownPosition: Double = 0

    // MARK: Gate crown selection

    /// While a gate prompt is showing, the crown arms a decision instead of
    /// navigating: turn up to arm approve, down to arm deny.
    public var gateCrown: Double = 0

    public enum GateChoice: Equatable {
        case none, approve, deny
    }

    public var gateChoice: GateChoice {
        if gateCrown >= 0.5 { return .approve }
        if gateCrown <= -0.5 { return .deny }
        return .none
    }

    @ObservationIgnored private var motion: WristMotionMonitor?
    /// Confirmation ids already answered from this watch, kept so a phone
    /// snapshot that has not yet caught up cannot resurrect an answered card.
    @ObservationIgnored private var answeredIDs: [String: Date] = [:]

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
                // Submits only what the crown armed — never a blind approve.
                submitGateChoice(source: .doubleTap)
            }
        case .nowPlaying:
            send(.togglePlayPause)
        case .agents, .notifications:
            goHome()
        }
    }

    /// Crown turned while a gate prompt is showing: detent haptics as the
    /// armed choice changes, distinct per direction.
    public func gateCrownChanged(to value: Double) {
        let previous = gateChoice
        gateCrown = value
        guard gateChoice != previous else { return }
        switch gateChoice {
        case .approve: playHaptic(.directionUp)
        case .deny:    playHaptic(.directionDown)
        case .none:    break
        }
    }

    /// Submit whatever the crown has armed. No-op when nothing is armed, so a
    /// stray Double Tap cannot approve an unread prompt.
    public func submitGateChoice(source: ConfirmationSource) {
        switch gateChoice {
        case .approve: answer(.confirmed, source: source)
        case .deny:    answer(.denied, source: source)
        case .none:    break
        }
    }

    public func answer(_ answer: ConfirmationAnswer, source: ConfirmationSource) {
        guard let pending = pendingConfirmation else { return }
        // Optimistic: drop it from the local snapshot now, tell the phone
        // after. The card must never linger while a radio round-trip happens.
        // `answeredIDs` is what keeps the phone's next (still-stale) snapshot
        // from resurrecting the card — the old behaviour that read as "stuck".
        answeredIDs[pending.id] = Date()
        snapshot.confirmations.removeAll { $0.id == pending.id }
        lastAnswer = (answer, Date())
        gateCrown = 0
        SnapshotCache.watch.save(snapshot)

        // Distinct taptics: approve rises, deny falls. The delivery
        // confirmation (`.success`) plays only when the phone acks.
        playHaptic(answer == .confirmed ? .directionUp : .directionDown)
        relayAnswer(.answer(id: pending.id, answer: answer, source: source), id: pending.id)
    }

    public func send(_ command: PlaybackCommand) {
        playHaptic(.click)
        relay(.command(command))
    }

    /// Answers must never be lost: live message when the phone is reachable,
    /// with a fallback to the system-queued `transferUserInfo` (delivered
    /// whenever the phone next connects) on unreachability or send failure.
    private func relayAnswer(_ message: WatchMessage, id: String) {
        #if canImport(WatchConnectivity)
        let session = WCSession.default
        guard session.activationState == .activated,
              let payload = try? WatchMessageCodec.encode(message) else {
            delivery = .queued(id: id)
            return
        }

        guard session.isReachable else {
            session.transferUserInfo(payload)
            delivery = .queued(id: id)
            return
        }

        delivery = .sending(id: id)
        session.sendMessage(payload) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.delivery = .sent(id: id)
                self.playHaptic(.success)   // delivery-confirmed taptic
            }
        } errorHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                WCSession.default.transferUserInfo(payload)
                self.delivery = .queued(id: id)
            }
        }
        #else
        delivery = .sent(id: id)
        #endif
    }

    /// Fire-and-forget commands (playback etc.) — losing one is harmless.
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
        var fresh = fresh
        pruneAnsweredIDs()

        // Once the answered confirmation is gone from the phone's own state,
        // the delivery banner has done its job. Checked against the unfiltered
        // snapshot — that is the phone's word, not our local suppression.
        switch delivery {
        case .sent(let id), .queued(let id), .sending(let id):
            if !fresh.confirmations.contains(where: { $0.id == id }) {
                delivery = .idle
            }
        case .idle:
            break
        }

        // Never resurrect a card answered on this watch: the phone's snapshot
        // lags the answer by a CloudKit round-trip.
        fresh.confirmations.removeAll { answeredIDs[$0.id] != nil }
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
        var cached = cached
        pruneAnsweredIDs()
        cached.confirmations.removeAll { answeredIDs[$0.id] != nil }
        snapshot = cached
        lastReceivedAt = Date()
    }

    /// Suppression entries outlive any snapshot that could resurrect them;
    /// after the confirmation's own lifetime they are moot either way.
    private func pruneAnsweredIDs(now: Date = Date()) {
        answeredIDs = answeredIDs.filter {
            now.timeIntervalSince($0.value) < PendingConfirmation.defaultLifetime
        }
    }

    fileprivate func reachabilityChanged(_ reachable: Bool) {
        isPhoneReachable = reachable
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
    public enum WKHapticType {
        case click, success, failure, notification, directionUp, directionDown
    }
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
    ) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }

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
