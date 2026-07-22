import Foundation
#if canImport(Combine)
import Combine
#endif

/// Pulls every record type into one `ShannonSnapshot` and reports the
/// edge-triggered alerts the UI turns into haptics. The reducer half is pure;
/// only `ShannonStore` touches the main actor.
public struct SnapshotAssembler: Sendable {
    private var dockingTracker = DockingAlertTracker()
    private var seenNotifications: Set<String> = []
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

        for note in snapshot.notifications.sorted(by: { $0.postedAt < $1.postedAt }) {
            guard !seenNotifications.contains(note.id) else { continue }
            seenNotifications.insert(note.id)
            if primed { alerts.append(.notification(note)) }
        }

        primed = true
        return alerts
    }
}

#if canImport(Combine)

/// The object both the iOS and watchOS apps bind to. On iPhone it is fed by
/// CloudKit; on Watch it is fed by the WatchConnectivity relay, or by CloudKit
/// directly when the phone is unreachable.
@MainActor
public final class ShannonStore: ObservableObject {
    @Published public private(set) var snapshot = ShannonSnapshot()
    @Published public private(set) var isRefreshing = false
    /// Nil until the first successful fetch; set on failure so the UI can show
    /// a connection banner rather than an empty list that looks like "no work".
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastSyncedAt: Date?

    /// Fired for each alert so the app layer can play the platform haptic.
    public var onAlert: ((SnapshotAssembler.Alert) -> Void)?

    private let backend: ShannonSyncBackend
    private var assembler = SnapshotAssembler()
    private var timer: Timer?
    private let interval: TimeInterval

    public init(backend: ShannonSyncBackend, interval: TimeInterval = 30) {
        self.backend = backend
        self.interval = interval
    }

    /// Periodic refresh as a safety net. Push subscriptions drive the common
    /// case; this covers a missed silent push.
    public func start() {
        Task { await refresh() }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

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

            let fresh = ShannonSnapshot(
                agents: try await agents,
                docking: try await docking,
                nowPlaying: try await media.first,
                device: try await devices.first,
                notifications: try await notes.sorted { $0.postedAt > $1.postedAt },
                timers: try await timers,
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
        snapshot = fresh
        for alert in assembler.consume(fresh) {
            onAlert?(alert)
        }
    }

    /// Send a playback command back to the Mac.
    public func send(_ command: PlaybackCommand, origin: String) {
        let record = RemoteCommand(command: command, origin: origin)
        Task { [backend] in
            try? await backend.save(record)
        }
    }
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

    /// `updatedAt` changes on every poll even when nothing else did, so it is
    /// excluded from the change comparison.
    private func fieldsMatch(_ a: CloudFields, _ b: CloudFields) -> Bool {
        var lhs = a, rhs = b
        lhs.removeValue(forKey: CloudKeys.updatedAt)
        rhs.removeValue(forKey: CloudKeys.updatedAt)
        return lhs == rhs
    }
}
