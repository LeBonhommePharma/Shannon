import Foundation

// MARK: - Shared HUD ↔ menu-bar ↔ exec telemetry binding

/// One equality-comparable snapshot of everything the notch HUD and menu-bar
/// popover both render for agents / asks / entropy / bridge.
///
/// Both surfaces bind the same `AgentActivityMonitor` + `ShannonBridge`
/// instances in `ShannonPillApp`. This type freezes that joint observation for:
/// - multi-consumer identity tests (same agent id cannot disagree)
/// - equality-gated republish (identical samples → not dirty)
///
/// Fail-closed: optional H / asks stay absent when not present — never invented.
public struct SharedTelemetrySnapshot: Sendable, Equatable {
    public var agents: [AgentActivitySnapshot]
    public var pendingAsks: [GateDBReader.PendingAsk]
    /// Gate `agent_activity` rows — required so shared HUD matches live pill tool lines.
    public var recentActivity: [GateDBReader.ActivityEvent]
    public var agentEntropy: [EntropyMeasurement]
    public var bridgeConnected: Bool
    /// Backend label only — synthetic backends remain visible but not measured.
    public var bridgeBackend: String?
    public var bridgeEntropy: Double?
    public var bridgeAgent: String?
    /// Per-agent retained series lengths (multi-agent memory), not the bits themselves.
    public var entropySeriesCounts: [String: Int]
    public var gateAvailable: Bool
    public var scannedAt: Date

    public init(
        agents: [AgentActivitySnapshot] = [],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        recentActivity: [GateDBReader.ActivityEvent] = [],
        agentEntropy: [EntropyMeasurement] = [],
        bridgeConnected: Bool = false,
        bridgeBackend: String? = nil,
        bridgeEntropy: Double? = nil,
        bridgeAgent: String? = nil,
        entropySeriesCounts: [String: Int] = [:],
        gateAvailable: Bool = false,
        scannedAt: Date = Date()
    ) {
        self.agents = agents
        self.pendingAsks = pendingAsks
        self.recentActivity = recentActivity
        self.agentEntropy = agentEntropy
        self.bridgeConnected = bridgeConnected
        self.bridgeBackend = bridgeBackend
        self.bridgeEntropy = bridgeEntropy
        self.bridgeAgent = bridgeAgent
        self.entropySeriesCounts = entropySeriesCounts
        self.gateAvailable = gateAvailable
        self.scannedAt = scannedAt
    }

    /// Capture from live monitor + bridge pieces (pure inputs — no AppKit).
    ///
    /// Multi-agent entropy memory is retained as series counts only here so
    /// publish equality stays cheap; bit values still come from `agentEntropy`
    /// / provenance (never invented when empty).
    public static func capture(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk],
        recentActivity: [GateDBReader.ActivityEvent] = [],
        agentEntropy: [EntropyMeasurement],
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        entropyMemory: AgentEntropyMemory = AgentEntropyMemory(),
        gateAvailable: Bool,
        scannedAt: Date = Date()
    ) -> SharedTelemetrySnapshot {
        // Keep multi-agent series intact: ingest this poll without wiping others.
        var memory = entropyMemory
        if !agentEntropy.isEmpty {
            memory.ingest(agentEntropy, now: scannedAt)
        }
        var counts: [String: Int] = [:]
        for id in memory.agentIds {
            counts[id] = memory.series(for: id).samples.count
        }
        let status = bridgeStatus
        let synthetic = status.map(\.isSynthetic) ?? true
        return SharedTelemetrySnapshot(
            agents: agents,
            pendingAsks: pendingAsks,
            recentActivity: recentActivity,
            agentEntropy: agentEntropy,
            bridgeConnected: bridgeConnected,
            bridgeBackend: status?.backend,
            // Only surface bridge H when connected and non-synthetic.
            bridgeEntropy: (bridgeConnected && status != nil && !synthetic)
                ? status?.entropy : nil,
            bridgeAgent: status?.agent,
            entropySeriesCounts: counts,
            gateAvailable: gateAvailable,
            scannedAt: scannedAt
        )
    }
}

/// Pure helpers for multi-consumer agreement and non-thrashing publish.
public enum SharedTelemetryBinding {
    /// Attention + busy claim for one agent as both HUD and menu bar would derive it.
    public struct AgentView: Sendable, Equatable {
        public var agentId: String
        public var presence: AgentPresence
        public var status: AgentRunStatus
        public var attention: AgentLiveAttention
        public var needsYou: Bool
        public var activityLine: String
        /// Trusted measured bits when present; `nil` when absent (never invented).
        public var entropyBits: Double?
        public var entropyCurrent: Bool

        public init(
            agentId: String,
            presence: AgentPresence,
            status: AgentRunStatus,
            attention: AgentLiveAttention,
            needsYou: Bool,
            activityLine: String,
            entropyBits: Double?,
            entropyCurrent: Bool
        ) {
            self.agentId = agentId
            self.presence = presence
            self.status = status
            self.attention = attention
            self.needsYou = needsYou
            self.activityLine = activityLine
            self.entropyBits = entropyBits
            self.entropyCurrent = entropyCurrent
        }

        /// Same busy rule as `AgentActivitySummary.busy` (live + busy status).
        public var isBusy: Bool { status.isBusy && presence.canBeBusy }
    }

    /// Resolve the joint view for every agent in the snapshot (shared path).
    public static func agentViews(
        in snap: SharedTelemetrySnapshot,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> [String: AgentView] {
        var out: [String: AgentView] = [:]
        for agent in snap.agents {
            let surface = AgentLiveSurfaceLogic.resolve(
                agent: agent,
                pendingAsks: snap.pendingAsks,
                activity: snap.recentActivity,
                now: now
            )
            let reading = EntropyProvenance.resolveForAgent(
                agentId: agent.id,
                bridgeConnected: snap.bridgeConnected,
                bridgeStatus: bridgeStatus(from: snap),
                gate: snap.agentEntropy,
                gateDBAvailable: snap.gateAvailable,
                now: now,
                policy: policy
            )
            let bits: Double?
            let current: Bool
            if case .measured(let m) = reading {
                bits = m.bits
                current = true
            } else if case .stale(let m, _) = reading {
                bits = m.bits
                current = false
            } else {
                bits = nil
                current = false
            }
            out[agent.id] = AgentView(
                agentId: agent.id,
                presence: agent.presence,
                status: agent.status,
                attention: surface.attention,
                needsYou: surface.needsYou,
                activityLine: surface.activityLine,
                entropyBits: bits,
                entropyCurrent: current
            )
        }
        return out
    }

    /// Multi-consumer identity: every snapshot must agree on each agent id's
    /// busy / needsYou / presence / attention / H (when both have a number).
    public static func consumersAgree(
        _ snaps: [SharedTelemetrySnapshot],
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> Bool {
        guard snaps.count >= 2 else { return true }
        let views = snaps.map { agentViews(in: $0, now: now, policy: policy) }
        let ids = Set(views.flatMap(\.keys))
        for id in ids {
            let row = views.compactMap { $0[id] }
            guard row.count == views.count else { return false }
            let first = row[0]
            for other in row.dropFirst() {
                if other.presence != first.presence { return false }
                if other.status != first.status { return false }
                if other.isBusy != first.isBusy { return false }
                if other.attention != first.attention { return false }
                if other.needsYou != first.needsYou { return false }
                if other.entropyCurrent != first.entropyCurrent { return false }
                switch (first.entropyBits, other.entropyBits) {
                case (nil, nil): break
                case let (a?, b?):
                    if abs(a - b) > 1e-9 { return false }
                default:
                    return false
                }
            }
        }
        return true
    }

    /// Busy claim for one agent id as both consumers would derive it.
    public static func isBusy(agentId: String, in snap: SharedTelemetrySnapshot) -> Bool {
        guard let agent = snap.agents.first(where: { $0.id == agentId }) else { return false }
        return agent.status.isBusy && agent.presence.canBeBusy
    }

    /// Needs-you claim for one agent id (pending ask present).
    public static func needsYou(agentId: String, in snap: SharedTelemetrySnapshot) -> Bool {
        snap.pendingAsks.contains { $0.agentId == agentId }
    }

    /// Measured H for one agent, or `nil` when not measured (never invents).
    public static func hBits(
        agentId: String,
        in snap: SharedTelemetrySnapshot,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> Double? {
        agentViews(in: snap, now: now, policy: policy)[agentId]?.entropyBits
    }

    /// Whether a republish should occur. Ignores `scannedAt` alone so a pure
    /// clock tick with identical telemetry is not dirty.
    public static func shouldPublish(
        previous: SharedTelemetrySnapshot?,
        next: SharedTelemetrySnapshot
    ) -> Bool {
        guard let previous else { return true }
        return !displayEqual(previous, next)
    }

    /// Display equality for telemetry — same agents/asks/entropy/bridge, clock free.
    public static func displayEqual(
        _ a: SharedTelemetrySnapshot,
        _ b: SharedTelemetrySnapshot
    ) -> Bool {
        a.agents == b.agents
            && a.pendingAsks == b.pendingAsks
            && a.recentActivity == b.recentActivity
            && a.agentEntropy == b.agentEntropy
            && a.bridgeConnected == b.bridgeConnected
            && a.bridgeBackend == b.bridgeBackend
            && optionalClose(a.bridgeEntropy, b.bridgeEntropy)
            && a.bridgeAgent == b.bridgeAgent
            && a.entropySeriesCounts == b.entropySeriesCounts
            && a.gateAvailable == b.gateAvailable
    }

    /// Primary focus line both chrome surfaces should show for the same snap.
    public static func primaryFocus(
        in snap: SharedTelemetrySnapshot,
        now: Date = Date()
    ) -> String? {
        AgentLiveSurfaceLogic.primaryFocus(
            agents: snap.agents,
            pendingAsks: snap.pendingAsks,
            activity: snap.recentActivity,
            now: now
        )
    }

    // MARK: - Internals

    private static func bridgeStatus(from snap: SharedTelemetrySnapshot) -> ShannonStatus? {
        guard let backend = snap.bridgeBackend else { return nil }
        // Reconstruct minimal status for resolveForAgent when bridge was live.
        // Synthetic backends carry entropy that must not become measured.
        return ShannonStatus(
            entropy: snap.bridgeEntropy ?? 0,
            deltaH: 0,
            collapsed: false,
            tokenCount: 0,
            backend: backend,
            agent: snap.bridgeAgent
        )
    }

    private static func optionalClose(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) < 1e-9
        default: return false
        }
    }
}
