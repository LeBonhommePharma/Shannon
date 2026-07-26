import Foundation
import PillCore

/// Mac → iCloud publishing. Reads the same models the pill renders and mirrors
/// them into CloudKit for the iPhone and Apple Watch.
///
/// Publishing is best-effort by design: an unsigned `swift run` build has no
/// iCloud entitlement, and the pill must keep working regardless. Failures are
/// counted and exposed for the status line rather than surfaced as alerts.
@MainActor
final class CloudPublisher {
    private let publisher: ShannonPublisher
    private let deviceName: String
    private var timer: Timer?
    private let interval: TimeInterval

    private(set) var lastPublishedAt: Date?
    private(set) var failureCount = 0

    /// Honest multi-device status for the popover footer (P2.7).
    /// - `off` / `in-memory`: unsigned or SHANNON_ICLOUD≠1
    /// - `on`: CloudKit backend active
    private(set) var multiDeviceStatus: String = "in-memory"

    /// Sources are read at publish time rather than observed, so this stays a
    /// leaf: nothing in the pill has to know it exists.
    private weak var nowPlaying: NowPlayingModel?
    private weak var battery: BatteryMonitor?
    private weak var bridge: ShannonBridge?
    private weak var resources: SystemResourceMonitor?
    /// Source of the gate's pending approvals, mirrored to phone/watch/iPad and
    /// the sink the returning answers are applied to.
    private weak var activity: AgentActivityMonitor?

    /// Confirmation ids currently mirrored to iCloud, so a resolved ask can be
    /// retracted from every device rather than lingering.
    private var publishedConfirmationIDs: Set<String> = []

    /// AgentState ids currently mirrored, so agents that leave the live roster
    /// are retracted the same way cleared confirmations are (ENH-020).
    private var publishedAgentIDs: Set<String> = []

    /// Decides the `createdAt` each open ask is mirrored with — the gate's own
    /// `created_at_ns` where there is one, a stable local first-seen otherwise.
    /// See `ConfirmationCreatedAtResolver` for why both halves are needed.
    private var confirmationCreatedAt = ConfirmationCreatedAtResolver()

    init(
        nowPlaying: NowPlayingModel?,
        battery: BatteryMonitor?,
        bridge: ShannonBridge?,
        activity: AgentActivityMonitor? = nil,
        resources: SystemResourceMonitor? = nil,
        backend: ShannonSyncBackend? = nil,
        interval: TimeInterval = 10,
        deviceName: String = Host.current().localizedName ?? "Mac"
    ) {
        self.nowPlaying = nowPlaying
        self.battery = battery
        self.bridge = bridge
        self.activity = activity
        self.resources = resources
        self.interval = interval
        self.deviceName = deviceName
        let resolved = backend ?? CloudPublisher.defaultBackend()
        self.publisher = ShannonPublisher(backend: resolved)
        self.multiDeviceStatus = CloudPublisher.statusLabel(for: resolved)
    }

    /// Operator-facing label for the multi-device path.
    static func statusLabel(for backend: ShannonSyncBackend) -> String {
        let name = String(describing: type(of: backend))
        let cloudKit = name.contains("CloudKit")
        let optIn = MultiDeviceBackendPolicy.optInFromEnvironment()
        let profile = MultiDeviceBackendPolicy.hasEmbeddedProvisioningProfile()
        return MultiDeviceBackendPolicy.status(
            optIn: optIn,
            hasProvisioningProfile: profile,
            cloudKitConstructed: cloudKit
        ).rawValue
    }

    /// Default backend is **always** in-memory unless the user opts into iCloud
    /// with `SHANNON_ICLOUD=1` *and* the process has a real iCloud entitlement.
    ///
    /// macOS 27 (and earlier): `CKContainer(identifier:)` raises `EXC_BREAKPOINT`
    /// when the container id is not in the app's entitlements. That is a hard
    /// process kill, not a catchable Swift error — so we must never construct
    /// `CloudKitSyncBackend` from an ad-hoc / Homebrew / `swift run` build.
    /// Policy is pure in `MultiDeviceBackendPolicy` (unit-tested).
    private static func defaultBackend() -> ShannonSyncBackend {
        #if canImport(CloudKit)
        let optIn = MultiDeviceBackendPolicy.optInFromEnvironment()
        let profile = MultiDeviceBackendPolicy.hasEmbeddedProvisioningProfile()
        if MultiDeviceBackendPolicy.shouldUseCloudKit(
            optIn: optIn,
            hasProvisioningProfile: profile
        ) {
            return CloudKitSyncBackend()
        }
        #endif
        return InMemorySyncBackend()
    }

    func start() {
        publish()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One publish pass. `ShannonPublisher` suppresses unchanged records, so
    /// calling this on a timer does not burn the CloudKit request quota.
    ///
    /// Mirrored types: NowPlaying, MacDeviceState, AgentState (multi-agent
    /// roster when activity is present, else bridge aggregate), PendingConfirmation.
    /// Not mirrored yet: DockingProgress, NotificationMirror, TimerState (ENH-019).
    func publish() {
        let media = nowPlayingSnapshot()
        let device = deviceSnapshot()
        let agents = agentSnapshots()
        // The gate's open approvals, mirrored so phone/watch/iPad can answer.
        // id == interaction_id so a returning ConfirmationResponse resolves the
        // exact gate row; agentID carries what the socket write needs.
        let asks = activity?.pendingAsks ?? []
        let now = Date()
        let confirmations = asks.map { ask -> PendingConfirmation in
            // Stable across passes, so an unchanged ask serialises to an
            // identical record and the publisher can suppress it — and anchored
            // to the gate's clock, so `expiresAt` counts from when the agent
            // actually asked rather than from this pill launch.
            PendingConfirmation(
                id: ask.interactionId,
                question: ask.prompt,
                agentID: ask.agentId,
                createdAt: confirmationCreatedAt.createdAt(for: ask, now: now)
            )
        }
        let liveConfirmationIDs = Set(confirmations.map(\.id))
        let staleConfirmationIDs = publishedConfirmationIDs.subtracting(liveConfirmationIDs)
        publishedConfirmationIDs = liveConfirmationIDs
        // Drop bookkeeping for asks the gate has cleared, so this cannot grow
        // without bound and a re-used interaction id starts fresh.
        confirmationCreatedAt.prune(keeping: liveConfirmationIDs)

        let liveAgentIDs = Set(agents.map(\.id))
        let staleAgentIDs = publishedAgentIDs.subtracting(liveAgentIDs)
        publishedAgentIDs = liveAgentIDs

        Task { [publisher] in
            do {
                if let media { try await publisher.publish(nowPlaying: media) }
                if let device { try await publisher.publish(device) }

                // One AgentState per live roster agent (or bridge-only fallback).
                for agent in agents {
                    try await publisher.publish(agent)
                }
                for id in staleAgentIDs {
                    try await publisher.retract(
                        AgentState(id: id, name: "", activity: .idle)
                    )
                }

                // Mirror open approvals, and retract the ones the gate cleared so
                // a resolved card vanishes from every device.
                for confirmation in confirmations {
                    try await publisher.publish(confirmation)
                }
                for id in staleConfirmationIDs {
                    try await publisher.retract(
                        PendingConfirmation(id: id, question: "")
                    )
                }

                // Playback taps made on the phone or watch come back here.
                let commands = try await publisher.consumeCommands()
                // Answers to pending questions made off the desk come back here;
                // forwarding them to the gate socket is the link that actually
                // unblocks the waiting agent.
                let answers = try await publisher.consumeConfirmationResponses()
                await MainActor.run {
                    self.lastPublishedAt = Date()
                    for command in commands { self.execute(command) }
                    for (response, confirmation) in answers {
                        self.applyRemoteAnswer(response, confirmation)
                    }
                }
            } catch {
                await MainActor.run { self.failureCount += 1 }
            }
        }
    }

    /// Forward a phone/watch/iPad answer to the gate socket, then drop the local
    /// ask so the pill stops pulsing without waiting for the next DB poll.
    private func applyRemoteAnswer(
        _ response: ConfirmationResponse,
        _ confirmation: PendingConfirmation?
    ) {
        // agentID is required to resolve the gate row; without it the socket
        // write can't be addressed, so we drop the answer rather than guess.
        guard let agentID = confirmation?.agentID, !agentID.isEmpty else { return }
        let interactionID = response.id
        let approved = response.answer == .confirmed
        publishedConfirmationIDs.remove(interactionID)
        Task { [weak self] in
            _ = try? await GateApprovalClient.resolveAsync(
                interactionId: interactionID,
                agentId: agentID,
                approved: approved
            )
            await MainActor.run { self?.activity?.clearAsk(interactionID) }
        }
    }

    // MARK: Model translation

    private func nowPlayingSnapshot() -> NowPlayingSnapshot? {
        guard let info = nowPlaying?.state.info else {
            // An explicit idle record is what clears the card on the phone;
            // omitting it would leave a stale track on screen forever.
            return NowPlayingSnapshot(title: "", artist: "")
        }
        return NowPlayingSnapshot(
            title: info.title,
            artist: info.artist,
            album: info.album,
            duration: info.duration,
            elapsed: info.elapsed,
            isPlaying: info.isPlaying,
            artworkJPEG: info.artworkData,
            sourceBundleID: info.sourceBundleID
        )
    }

    private func deviceSnapshot() -> MacDeviceState? {
        guard let snapshot = battery?.snapshot else { return nil }
        // Host capacity (SSD/thermal/CPU/RAM) for multi-device load preference.
        let capacity = resources?.snapshot.hostCapacity
        return MacDeviceState(
            deviceName: deviceName,
            batteryPercent: snapshot.percentage,
            isCharging: snapshot.isCharging,
            minutesRemaining: snapshot.isCharging
                ? snapshot.minutesToFull
                : snapshot.minutesToEmpty,
            capacity: capacity
        )
    }

    /// Multi-agent roster when activity has agents; otherwise the single bridge
    /// aggregate (provenance tests + no-fleet machines).
    private func agentSnapshots() -> [AgentState] {
        AgentStateRosterPublish.snapshots(
            activityAgents: activity?.summary.agents ?? [],
            bridgeConnected: bridge?.connected ?? false,
            bridgeStatus: bridge?.status,
            gateEntropy: activity?.agentEntropy ?? [],
            gateDBAvailable: activity?.gateDBAvailable ?? false,
            entropyMemory: activity?.entropyMemory
        )
    }

    // MARK: Inbound commands

    private func execute(_ command: RemoteCommand) {
        guard let nowPlaying else { return }
        switch command.command {
        case .togglePlayPause: nowPlaying.togglePlayPause()
        case .nextTrack:       nowPlaying.nextTrack()
        case .previousTrack:   nowPlaying.previousTrack()
        }
    }
}

// MARK: - Pure multi-agent AgentState roster (ENH-020)

/// Builds `AgentState` rows for CloudKit from the Mac activity roster.
///
/// Pure and deterministic: no I/O, no wall clock (callers pass `now` only when
/// resolving entropy). Fail-closed on entropy — only `.measured` readings may
/// set `entropyBits` / `entropyDelta` / `isCollapsed`.
enum AgentStateRosterPublish {
    /// One `AgentState` per **live** agent on the Mac roster (presence `.live`,
    /// already display-ranked in `summary.agents`). When the roster is empty,
    /// falls back to a single ShannonBridge aggregate so provenance tests and
    /// bridge-only machines still publish one row.
    static func snapshots(
        activityAgents: [AgentActivitySnapshot],
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gateEntropy: [EntropyMeasurement] = [],
        gateDBAvailable: Bool = false,
        entropyMemory: AgentEntropyMemory? = nil,
        now: Date = Date()
    ) -> [AgentState] {
        if !activityAgents.isEmpty {
            // Live set = presence.live, preserving summary display order.
            // Per-agent gate entropy feeds resolveForAgent (ENH-022 / ENH-020).
            let live = activityAgents.filter { $0.presence == .live }
            return live.map { agent in
                state(
                    for: agent,
                    bridgeConnected: bridgeConnected,
                    bridgeStatus: bridgeStatus,
                    gateEntropy: gateEntropy,
                    gateDBAvailable: gateDBAvailable,
                    entropyMemory: entropyMemory,
                    now: now
                )
            }
        }
        // No roster: fleet-level resolve (bridge → gate → absent), same as the
        // pill header — not bridge-only isMeasured (ENH-022).
        if let single = bridgeAggregate(
            bridgeConnected: bridgeConnected,
            bridgeStatus: bridgeStatus,
            gateEntropy: gateEntropy,
            gateDBAvailable: gateDBAvailable,
            now: now
        ) {
            return [single]
        }
        return []
    }

    /// Single bridge/fleet aggregate when there is no multi-agent roster.
    ///
    /// Uses `EntropyProvenance.resolve` — the same precedence as the pill
    /// header / border / `~H` badge (bridge measured → else gate measured
    /// within policy → else absent). Bridge-only `isMeasured` is deliberately
    /// **not** used: demo + real gate would leave the phone empty while Mac
    /// shows gate H, or (worse) would publish demo collapse as measured.
    static func bridgeAggregate(
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gateEntropy: [EntropyMeasurement] = [],
        gateDBAvailable: Bool = false,
        now: Date = Date()
    ) -> AgentState? {
        guard let status = bridgeStatus else { return nil }
        // `--demo` opens a REAL socket and serves `8.0 + 2.0*sin(n/12)`,
        // asserting `is_collapsed` on ~29% of ticks. `AgentState` has no
        // provenance field, so a fabricated number must never leave the machine
        // as measured collapse. When a live gate score exists, resolve falls
        // through to it and we publish that honest H instead.
        let reading = EntropyProvenance.resolve(
            bridgeConnected: bridgeConnected,
            bridgeStatus: status,
            gate: gateEntropy,
            gateDBAvailable: gateDBAvailable,
            now: now
        )
        return agentState(from: reading, bridgeStatus: status)
    }

    /// Fail-closed map from a provenance reading to CloudKit entropy fields.
    /// Only `.measured` contributes bits / ΔH / collapse (token-domain verdict).
    static func publishableEntropy(
        from reading: EntropyReading
    ) -> (bits: Double?, delta: Double?, collapsed: Bool) {
        guard case .measured(let m) = reading else {
            return (nil, nil, false)
        }
        // Gate message scores never alarm as eval-awareness collapse — same
        // polarity as multi-agent `state(for:)` and `EntropyReading.verdict`.
        let collapsed = reading.verdict == .collapsed
        return (m.bits, m.deltaH, collapsed)
    }

    /// Build the fleet `AgentState` from a resolve reading + bridge frame.
    static func agentState(
        from reading: EntropyReading,
        bridgeStatus status: ShannonStatus
    ) -> AgentState {
        let (bits, delta, collapsed) = publishableEntropy(from: reading)
        let id: String
        let name: String
        let taskTitle: String
        if case .measured(let m) = reading {
            switch m.source {
            case .bridge(let backend):
                let b = backend.trimmingCharacters(in: .whitespaces)
                id = status.agent ?? "shannon-gate"
                name = status.agent ?? "Shannon gate"
                taskTitle = "Entropy gate (\(b.isEmpty ? status.backend : b))"
            case .gate(let agentId, _):
                let gid = agentId.trimmingCharacters(in: .whitespaces)
                id = gid.isEmpty ? (status.agent ?? "shannon-gate") : gid
                name = id == "shannon-gate" ? "Shannon gate" : id
                taskTitle = "Entropy gate (gate:\(id))"
            }
        } else if status.isSynthetic {
            id = status.agent ?? "shannon-gate"
            name = status.agent ?? "Shannon gate"
            taskTitle = "Entropy gate (simulated)"
        } else {
            id = status.agent ?? "shannon-gate"
            name = status.agent ?? "Shannon gate"
            taskTitle = "Entropy gate (\(status.backend))"
        }
        return AgentState(
            id: id,
            name: name,
            activity: collapsed ? .blocked : .running,
            taskTitle: taskTitle,
            turnCount: status.tokenCount,
            lastAction: collapsed ? "Entropy collapse detected" : "Monitoring",
            entropyBits: bits,
            entropyDelta: delta,
            isCollapsed: collapsed
        )
    }

    /// One agent row: identity + activity from the roster; entropy only when
    /// `EntropyProvenance.resolveForAgent` (or memory) yields `.measured`.
    static func state(
        for agent: AgentActivitySnapshot,
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gateEntropy: [EntropyMeasurement],
        gateDBAvailable: Bool,
        entropyMemory: AgentEntropyMemory?,
        now: Date = Date()
    ) -> AgentState {
        let reading: EntropyReading = {
            if let memory = entropyMemory, memory.latest(for: agent.id) != nil {
                return memory.reading(
                    for: agent.id,
                    now: now,
                    gateDBAvailable: gateDBAvailable
                )
            }
            return EntropyProvenance.resolveForAgent(
                agentId: agent.id,
                bridgeConnected: bridgeConnected,
                bridgeStatus: bridgeStatus,
                gate: gateEntropy,
                gateDBAvailable: gateDBAvailable,
                now: now
            )
        }()

        // Fail-closed: never invent H / δ / collapse for devices that cannot
        // show provenance (`AgentState` has no ~ marker).
        let measured = reading.isMeasured
        let measurement = measured ? reading.measurement : nil
        // Token-domain collapse only (gate message scores never alarm as
        // eval-awareness collapse — same polarity as `EntropyReading.verdict`).
        let collapsed = measured && reading.verdict == .collapsed

        let task = AgentActivitySnapshot.shorten(agent.lastTask, max: 80)
        let lastAction: String = {
            if collapsed { return "Entropy collapse detected" }
            if !task.isEmpty { return task }
            return agent.statusLine(at: now)
        }()

        return AgentState(
            id: agent.id,
            name: agent.displayName,
            activity: cloudActivity(for: agent, collapsed: collapsed),
            taskTitle: task,
            turnCount: max(0, agent.historyCount),
            lastAction: lastAction,
            entropyBits: measurement?.bits,
            entropyDelta: measurement?.deltaH,
            isCollapsed: collapsed,
            updatedAt: agent.updatedAt
        )
    }

    /// Map Mac presence/status onto the multi-device `AgentActivity` enum.
    static func cloudActivity(
        for agent: AgentActivitySnapshot,
        collapsed: Bool
    ) -> AgentActivity {
        if collapsed { return .blocked }
        switch agent.status {
        case .blocked:
            return .blocked
        case .active, .midTask:
            return .running
        case .idle, .unknown:
            return .idle
        }
    }
}
