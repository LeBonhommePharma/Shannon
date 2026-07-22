import Foundation
#if canImport(Observation)
import Observation
#endif

/// Pulls every record type into one `ShannonSnapshot` and reports the
/// edge-triggered alerts the UI turns into haptics. The reducer half is pure;
/// only `ShannonStore` touches the main actor.
public struct SnapshotAssembler: Sendable {
    private var dockingTracker = DockingAlertTracker()
    private var seenNotifications: Set<String> = []
    private var seenConfirmations: Set<String> = []
    private var lastAgentActivity: [String: AgentActivity] = [:]
    /// Nothing is "new" on the first assembly — otherwise every launch would
    /// buzz once per already-finished benchmark.
    private var primed = false

    public init() {}

    public enum Alert: Equatable, Sendable {
        case docking(DockingAlertTracker.Alert)
        case agentErrored(name: String)
        case agentFinished(name: String)
        case notification(NotificationMirror)
        case confirmationRequested(PendingConfirmation)

        public var deservesHaptic: Bool { true }
    }

    /// Feed a freshly fetched snapshot; returns alerts to fire, oldest first.
    public mutating func consume(_ snapshot: ShannonSnapshot) -> [Alert] {
        var alerts: [Alert] = []

        for progress in snapshot.docking {
            if let a = dockingTracker.consume(progress), primed {
                alerts.append(.docking(a))
            }
        }

        for agent in snapshot.agents {
            let previous = lastAgentActivity[agent.id]
            lastAgentActivity[agent.id] = agent.activity
            guard primed, previous != nil, previous != agent.activity else { continue }
            switch agent.activity {
            case .errored:  alerts.append(.agentErrored(name: agent.name))
            case .finished: alerts.append(.agentFinished(name: agent.name))
            default: break
            }
        }

        // A pending question alerts even on the first snapshot: unlike a
        // finished benchmark, it is still waiting on an answer right now.
        for confirmation in snapshot.confirmations.sorted(by: { $0.createdAt < $1.createdAt })
        where !confirmation.isExpired() {
            guard !seenConfirmations.contains(confirmation.id) else { continue }
            seenConfirmations.insert(confirmation.id)
            alerts.append(.confirmationRequested(confirmation))
        }

        for note in snapshot.notifications.sorted(by: { $0.postedAt < $1.postedAt }) {
            guard !seenNotifications.contains(note.id) else { continue }
            seenNotifications.insert(note.id)
            if primed { alerts.append(.notification(note)) }
        }

        primed = true
        return alerts
    }
}

#if canImport(Observation)

/// The object both the iOS and watchOS apps bind to. On iPhone it is fed by
/// CloudKit; on Watch it is fed by the WatchConnectivity relay, or by its
/// on-disk cache when the phone is unreachable.
///
/// Uses the Observation framework rather than `ObservableObject`: SwiftUI then
/// invalidates only the views that read a changed property, which is what
/// keeps a one-second entropy tick from redrawing the whole card list.
@available(iOS 17.0, watchOS 10.0, macOS 14.0, *)
@MainActor
@Observable
public final class ShannonStore {
    public private(set) var snapshot = ShannonSnapshot()
    public private(set) var isRefreshing = false
    /// Nil until the first successful fetch; set on failure so the UI can show
    /// a connection banner rather than an empty list that looks like "no work".
    public private(set) var lastError: String?
    public private(set) var lastSyncedAt: Date?

    /// Answers already sent, so the card can disappear immediately while the
    /// Mac catches up. Optimistic UI: never wait on a network round-trip to
    /// redraw.
    public private(set) var answeredConfirmations: Set<String> = []

    /// Fired for each alert so the app layer can play the platform haptic.
    /// Not observed — a closure, so setting it does not invalidate views.
    @ObservationIgnored public var onAlert: ((SnapshotAssembler.Alert) -> Void)?
    /// Called after every snapshot change, for the watch relay and the widget
    /// cache. Also unobserved.
    @ObservationIgnored public var onSnapshot: ((ShannonSnapshot) -> Void)?

    @ObservationIgnored private let backend: ShannonSyncBackend
    @ObservationIgnored private var assembler = SnapshotAssembler()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored public let deviceName: String

    public init(
        backend: ShannonSyncBackend,
        interval: TimeInterval = 30,
        deviceName: String = "device"
    ) {
        self.backend = backend
        self.interval = interval
        self.deviceName = deviceName
    }

    /// Periodic refresh as a safety net. Push subscriptions drive the common
    /// case; this covers a missed silent push.
    public func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// All CloudKit I/O happens inside the backend actor/task; only the
    /// resulting value is applied here on the main actor.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let agents = backend.fetch(AgentState.self)
            async let docking = backend.fetch(DockingProgress.self)
            async let media = backend.fetch(NowPlayingSnapshot.self)
            async let devices = backend.fetch(MacDeviceState.self)
            async let notes = backend.fetch(NotificationMirror.self)
            async let timers = backend.fetch(TimerState.self)
            async let confirmations = backend.fetch(PendingConfirmation.self)

            let fresh = ShannonSnapshot(
                agents: try await agents,
                docking: try await docking,
                nowPlaying: try await media.first,
                device: try await devices.first,
                notifications: try await notes.sorted { $0.postedAt > $1.postedAt },
                timers: try await timers,
                confirmations: try await confirmations,
                capturedAt: Date()
            )
            apply(fresh)
            lastError = nil
            lastSyncedAt = Date()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Entry point for snapshots arriving over the watch relay rather than
    /// from CloudKit.
    public func apply(_ fresh: ShannonSnapshot) {
        var incoming = fresh
        // Drop anything already answered locally, so a card cannot flicker
        // back into view on the next refresh before the Mac has retracted it.
        incoming.confirmations.removeAll { answeredConfirmations.contains($0.id) }
        snapshot = incoming

        for alert in assembler.consume(incoming) {
            onAlert?(alert)
        }
        onSnapshot?(incoming)
    }

    /// Send a playback command back to the Mac.
    public func send(_ command: PlaybackCommand, origin: String? = nil) {
        let record = RemoteCommand(command: command, origin: origin ?? deviceName)
        Task { [backend] in
            try? await backend.save(record)
        }
    }

    /// Answer a pending question. The card disappears immediately; the write
    /// reconciles in the background.
    public func answer(
        _ confirmation: PendingConfirmation,
        _ answer: ConfirmationAnswer,
        source: ConfirmationSource,
        origin: String? = nil
    ) {
        guard !answeredConfirmations.contains(confirmation.id) else { return }
        answeredConfirmations.insert(confirmation.id)
        snapshot.confirmations.removeAll { $0.id == confirmation.id }

        let response = ConfirmationResponse(
            confirmation: confirmation,
            answer: answer,
            source: source,
            origin: origin ?? deviceName
        )
        Task { [backend] in
            try? await backend.save(response)
        }
    }

    /// Convenience for the gesture, voice and Double Tap paths, which all
    /// answer whichever question is currently on screen.
    @discardableResult
    public func answerPending(
        _ answer: ConfirmationAnswer,
        source: ConfirmationSource
    ) -> PendingConfirmation? {
        guard let pending = snapshot.oldestPendingConfirmation() else { return nil }
        self.answer(pending, answer, source: source)
        return pending
    }

    public var isAwaitingConfirmation: Bool { snapshot.isAwaitingConfirmation }
}

#endif

/// Mac-side publishing. The Pill app calls these as its own state changes;
/// each snapshot type writes to a stable record name, so iCloud holds current
/// state rather than a growing history.
public actor ShannonPublisher {
    private let backend: ShannonSyncBackend
    /// Last published fields per record, so unchanged state is not rewritten.
    private var published: [String: CloudFields] = [:]

    public init(backend: ShannonSyncBackend) {
        self.backend = backend
    }

    /// Writes only when the fields actually changed. Republishing an identical
    /// record on every 1 s poll would burn the CloudKit request quota.
    @discardableResult
    public func publish<T: CloudSyncable>(_ value: T) async throws -> Bool {
        let key = "\(T.recordType)/\(value.recordName)"
        let fields = value.cloudFields
        if let previous = published[key], fieldsMatch(previous, fields) { return false }
        try await backend.save(value)
        published[key] = fields
        return true
    }

    public func publish(nowPlaying: NowPlayingSnapshot) async throws {
        try await publish(nowPlaying.trimmedForSync())
    }

    /// Removes an agent's record when it exits, so the phone stops listing it.
    public func retract<T: CloudSyncable>(_ value: T) async throws {
        try await backend.delete(value)
        published.removeValue(forKey: "\(T.recordType)/\(value.recordName)")
    }

    /// Drains commands the phone or watch issued. Stale ones are deleted
    /// without executing — a tap queued offline should not skip a track later.
    public func consumeCommands(now: Date = Date()) async throws -> [RemoteCommand] {
        let all = try await backend.fetch(RemoteCommand.self)
        var fresh: [RemoteCommand] = []
        for command in all.sorted(by: { $0.issuedAt < $1.issuedAt }) {
            if !command.isStale(now: now) { fresh.append(command) }
            try? await backend.delete(command)
        }
        return fresh
    }

    /// Drains answers to pending questions and retracts the matching prompts,
    /// so the card disappears from every device at once.
    ///
    /// An answer to an expired prompt is discarded: the agent has already
    /// stopped waiting, and acting on it would apply LP's intent to whatever
    /// the agent moved on to.
    public func consumeConfirmationResponses(
        now: Date = Date()
    ) async throws -> [(response: ConfirmationResponse, confirmation: PendingConfirmation?)] {
        let responses = try await backend.fetch(ConfirmationResponse.self)
        guard !responses.isEmpty else { return [] }
        let prompts = try await backend.fetch(PendingConfirmation.self)
        let byID = Dictionary(prompts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var out: [(ConfirmationResponse, PendingConfirmation?)] = []
        for response in responses.sorted(by: { $0.answeredAt < $1.answeredAt }) {
            let prompt = byID[response.id]
            if let prompt {
                try? await retract(prompt)
            }
            try? await backend.delete(response)
            guard let prompt, !prompt.isExpired(now: now) else { continue }
            out.append((response, prompt))
        }
        return out
    }

    /// `updatedAt` changes on every poll even when nothing else did, so it is
    /// excluded from the change comparison.
    private func fieldsMatch(_ a: CloudFields, _ b: CloudFields) -> Bool {
        var lhs = a, rhs = b
        lhs.removeValue(forKey: CloudKeys.updatedAt)
        rhs.removeValue(forKey: CloudKeys.updatedAt)
        return lhs == rhs
    }
}
