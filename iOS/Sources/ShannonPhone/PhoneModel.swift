import Foundation
import Observation
import ShannonCore
import WidgetKit

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
        self.store = ShannonStore(
            backend: resolved,
            interval: MultiDeviceCadence.companionRefreshInterval,
            deviceName: "iPhone"
        )
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
            // App Group + WidgetKit reload (UX-035); offline flag from lastError (UX-038).
            self.persistWidgetCache(snapshot: snapshot)
            self.updateGestureArming(for: snapshot)
        }
        // UX-038: refresh errors must rewrite the cache so the glance fail-closes.
        store.onSyncFailure = { [weak self] in
            guard let self else { return }
            self.persistWidgetCache(snapshot: self.store.snapshot)
            self.updateGestureArming(for: self.store.snapshot)
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

    /// True only while `HeadGestureListener` is actually tracking (UX-037).
    /// Distinct from `isAwaitingConfirmation` (stem/voice may still answer).
    public var headGesturesArmed: Bool { gestures.isArmed }

    /// Status string for unavailable gesture coaching line.
    public var headGestureStatus: String { gestures.statusDescription }

    /// Mirror into App Group (encrypted at rest), then reload WidgetKit so
    /// lock-screen glance stays within MultiDeviceCadence rather than the
    /// 15-minute timeline fallback (UX-035). Persists offline signal (UX-038).
    private func persistWidgetCache(snapshot: ShannonSnapshot) {
        if SnapshotCache.phone.save(snapshot, lastError: store.lastError) {
            WidgetCenter.shared.reloadTimelines(ofKind: "ShannonWidget")
        }
    }

    /// Arms head-gesture listening only while a question is on screen **and**
    /// motion is available — CoreMotion updates cost battery, and coaching must
    /// not claim "Nod to confirm" when arming no-ops (UX-037).
    private func updateGestureArming(for snapshot: ShannonSnapshot) {
        // Answerable pending ask (not expired / not hub offline) — stem/voice gate.
        var awaiting = snapshot.isAwaitingConfirmation
        if awaiting, let pending = snapshot.oldestPendingConfirmation() {
            let a = GateAskActionCopy.companionAffordance(
                pending: pending,
                lastError: store.lastError
            )
            awaiting = a.canInteract
        }
        isAwaitingConfirmation = awaiting

        // UX-037: arm only when gestures are available; always re-evaluate so a
        // late AirPods connect can arm without waiting for another snapshot flip.
        if awaiting, gestures.isAvailable {
            if !gestures.isArmed {
                gestures.arm { [weak self] gesture in
                    self?.answer(gesture.answer, source: gesture == .nod ? .headNod : .headShake)
                }
            }
        } else {
            gestures.disarm()
        }
    }

    // MARK: Answering

    public func answer(_ answer: ConfirmationAnswer, source: ConfirmationSource) {
        guard let pending = store.snapshot.oldestPendingConfirmation() else { return }
        // OS-agnostic contract: expired prompts refuse the answer (no haptic success).
        guard GlobalNotifyResponse.canAnswer(pending) else { return }
        // UX-003: hub offline — do not fake success when CloudKit cannot write back.
        let affordance = GateAskActionCopy.companionAffordance(
            pending: pending,
            lastError: store.lastError
        )
        guard affordance.canInteract else { return }
        let accepted = store.answer(pending, answer, source: source)
        guard accepted else { return }
        lastAnswer = (answer, Date())
        Haptics.confirmation(answer)
        // UX-044: spoken outcome shares GateAskActionCopy family (not dual Confirmed/Denied).
        airPods.announce(
            GateAskActionCopy.outcomeLabel(approved: answer == .confirmed)
        )
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
            // ENH-024: optimistic local clear of mirrored notifications (no Mac retract).
            dismissAllNotifications()
        }
    }

    /// Stem tertiary: clear notification cards on-device immediately.
    /// Does not invent a CloudKit retract — Mac-published notes stay filtered
    /// until the hub drops them (``ShannonStore.dismissMirroredNotificationsLocally``).
    private func dismissAllNotifications() {
        _ = store.dismissMirroredNotificationsLocally()
        Haptics.transition()
    }

    // MARK: Voice

    public func startDictation() {
        voice.start()
    }

    /// Called on mic release (hold-to-talk) or second double-tap (hands-free).
    /// Parses with the same command table as the Mac and the Watch.
    public func finishDictation() {
        // Leaving hands-free whenever we intentionally stop (UX-045).
        voice.isHandsFree = false
        voice.stop { [weak self] transcript in
            guard let self, let transcript, !transcript.isEmpty else { return }
            self.handle(VoiceCommand.parse(transcript))
        }
    }

    /// UX-045: double-tap mic toggles hands-free listen; second double-tap finishes.
    public func toggleHandsFreeDictation() {
        if voice.isHandsFree {
            finishDictation()
            return
        }
        voice.isHandsFree = true
        Haptics.transition()
        if !voice.isListening {
            startDictation()
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
        case .confirm, .deny:
            // No answerable pending ask — ignore (do not invent success).
            Haptics.transition()
        case .freeform:
            // ENH-025: freeform is an explicit phone no-op. There is no
            // freeform RemoteCommand / CloudKit query transport yet; unrecognised
            // speech is not forwarded to the Mac. Haptic acknowledges release only.
            Haptics.transition()
        }
    }
}
