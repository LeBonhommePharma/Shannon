import Foundation
import Observation
import ShannonCore

/// Single source of truth for the iPhone app.
///
/// Owns the CloudKit-backed store and the three input surfaces that can answer
/// a pending question — head gestures, AirPods stem presses and voice. Views
/// read it directly; nothing here blocks on the network.
@available(iOS 17.0, *)
@MainActor
@Observable
public final class PhoneModel {
    public let store: ShannonStore

    /// True only while a question is actually pending. Every gesture surface
    /// is gated on this, so ordinary head movement or a stray stem press can
    /// never answer something that was not asked.
    public private(set) var isAwaitingConfirmation = false
    public private(set) var lastAnswer: (answer: ConfirmationAnswer, at: Date)?

    public let airPods: AirPodsMonitor
    public let voice: VoiceDictation

    @ObservationIgnored private let gestures: HeadGestureListener
    @ObservationIgnored private let relay = PhoneWatchRelay()
    @ObservationIgnored private var started = false

    public init(backend: ShannonSyncBackend? = nil) {
        let resolved = backend ?? PhoneModel.defaultBackend()
        self.store = ShannonStore(backend: resolved, interval: 30, deviceName: "iPhone")
        self.gestures = HeadGestureListener()
        self.airPods = AirPodsMonitor()
        self.voice = VoiceDictation()
    }

    /// Falls back to an empty in-memory backend when CloudKit is unavailable
    /// (Simulator without an iCloud account, or a build without the
    /// entitlement) so the app still launches and shows its empty state.
    private static func defaultBackend() -> ShannonSyncBackend {
        #if targetEnvironment(simulator)
        return InMemorySyncBackend()
        #else
        return CloudKitSyncBackend()
        #endif
    }

    public func start() {
        guard !started else { return }
        started = true

        store.onAlert = { [weak self] alert in
            guard let self else { return }
            Haptics.play(for: alert)
            self.relay.notifyWatch(of: alert)
            if case .confirmationRequested(let pending) = alert {
                self.airPods.announce(pending.question)
            }
        }
        store.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.relay.send(snapshot)
            // The widget process cannot read this one, so each snapshot is
            // mirrored into the App Group container, encrypted at rest.
            SnapshotCache.phone.save(snapshot)
            self.updateGestureArming(for: snapshot)
        }

        relay.activate()
        relay.onWatchCommand = { [weak self] command in
            self?.store.send(command, origin: "Apple Watch")
        }
        relay.onWatchAnswer = { [weak self] answer, source in
            self?.answer(answer, source: source)
        }

        airPods.start()
        airPods.onRemoteCommand = { [weak self] command in
            self?.handleStemPress(command)
        }

        store.start()
    }

    /// Arms head-gesture listening only while a question is on screen, and
    /// tears the motion session down the moment it is answered — CoreMotion
    /// updates are a real battery cost to leave running.
    private func updateGestureArming(for snapshot: ShannonSnapshot) {
        let awaiting = snapshot.isAwaitingConfirmation
        guard awaiting != isAwaitingConfirmation else { return }
        isAwaitingConfirmation = awaiting

        if awaiting {
            gestures.arm { [weak self] gesture in
                self?.answer(gesture.answer, source: gesture == .nod ? .headNod : .headShake)
            }
        } else {
            gestures.disarm()
        }
    }

    // MARK: Answering

    public func answer(_ answer: ConfirmationAnswer, source: ConfirmationSource) {
        guard let pending = store.snapshot.oldestPendingConfirmation() else { return }
        store.answer(pending, answer, source: source)
        lastAnswer = (answer, Date())
        Haptics.confirmation(answer)
        airPods.announce(answer == .confirmed ? "Confirmed" : "Denied")
        // Re-derive arming from the mutated snapshot rather than waiting for
        // the next refresh, or the detector stays live after the card is gone.
        updateGestureArming(for: store.snapshot)
    }

    public func send(_ command: PlaybackCommand) {
        store.send(command)
        Haptics.transition()
    }

    /// Stem press mapping: a single press answers a pending question when
    /// there is one, and otherwise behaves like an ordinary transport control.
    private func handleStemPress(_ command: AirPodsMonitor.RemoteCommand) {
        switch command {
        case .primary:
            if isAwaitingConfirmation {
                answer(.confirmed, source: .stemPress)
            } else {
                send(.togglePlayPause)
            }
        case .secondary:
            if isAwaitingConfirmation {
                answer(.denied, source: .stemPress)
            } else {
                send(.nextTrack)
            }
        case .tertiary:
            dismissAllNotifications()
        }
    }

    private func dismissAllNotifications() {
        Haptics.transition()
    }

    // MARK: Voice

    public func startDictation() {
        voice.start()
    }

    /// Called on mic release. Parses with the same command table as the Mac
    /// and the Watch.
    public func finishDictation() {
        voice.stop { [weak self] transcript in
            guard let self, let transcript, !transcript.isEmpty else { return }
            self.handle(VoiceCommand.parse(transcript))
        }
    }

    public func handle(_ command: VoiceCommand) {
        switch command {
        case .confirm where isAwaitingConfirmation:
            answer(.confirmed, source: .voice)
        case .deny where isAwaitingConfirmation:
            answer(.denied, source: .voice)
        case .nowPlaying:
            if let line = store.snapshot.nowPlaying?.compactLine() { airPods.announce(line) }
        case .benchmark:
            if let docking = store.snapshot.docking.first {
                let best = docking.bestRMSD.map { String(format: "%.2f ångströms", $0) }
                    ?? "no result yet"
                airPods.announce("\(docking.countLabel), best \(best)")
            }
        case .status:
            airPods.announce("\(store.snapshot.agents.runningCount) agents running")
        case .confirm, .deny, .freeform:
            // Nothing to answer, or a free query: the Mac owns interpretation.
            Haptics.transition()
        }
    }
}
