import Foundation

// MARK: - Simultaneous multi-agent entropy memory

/// One retained sample in an agent’s series. Wraps a trusted measurement only —
/// never invents bits.
public struct AgentEntropySample: Sendable, Equatable, Identifiable {
    public var id: String {
        "\(agentId)|\(measurement.measuredAt.timeIntervalSince1970)|\(measurement.bits)"
    }
    public var agentId: String
    public var measurement: EntropyMeasurement
    /// When this memory store accepted the sample (may equal measuredAt).
    public var retainedAt: Date

    public init(agentId: String, measurement: EntropyMeasurement, retainedAt: Date) {
        self.agentId = agentId
        self.measurement = measurement
        self.retainedAt = retainedAt
    }

    public var bits: Double { measurement.bits }
    public var measuredAt: Date { measurement.measuredAt }
    public var presence: AgentPresence {
        if case .gate(_, let p) = measurement.source { return p }
        return .observed
    }
}

/// Snapshot of one agent’s retained series (oldest → newest).
public struct AgentEntropySeries: Sendable, Equatable, Identifiable {
    public var id: String { agentId }
    public var agentId: String
    public var samples: [AgentEntropySample]
    public var latest: AgentEntropySample? { samples.last }

    public init(agentId: String, samples: [AgentEntropySample] = []) {
        self.agentId = agentId
        self.samples = samples
    }

    /// Rolling bits for sparklines / fluid gauges — empty when none retained.
    public var bitSeries: [Double] { samples.map(\.bits) }

    /// Presence on the newest sample (if any).
    public var latestPresence: AgentPresence? { latest?.presence }
}

/// Pure multi-agent entropy memory: independent series per agent id.
///
/// Updating agent A never clears agent B. Offline presence keeps history but
/// is not reported as a *current* measured H. Only trusted `EntropyMeasurement`
/// values are retained (fail-closed — no fabricated bits).
public struct AgentEntropyMemory: Sendable, Equatable {
    public var maxSamplesPerAgent: Int
    /// agentId → samples oldest-first.
    private var seriesByAgent: [String: [AgentEntropySample]]

    public init(maxSamplesPerAgent: Int = 32, seriesByAgent: [String: [AgentEntropySample]] = [:]) {
        self.maxSamplesPerAgent = max(1, maxSamplesPerAgent)
        self.seriesByAgent = seriesByAgent
    }

    public var agentIds: [String] {
        seriesByAgent.keys.sorted()
    }

    public var isEmpty: Bool { seriesByAgent.isEmpty }

    // MARK: Ingest

    /// Ingest a poll batch. Only updates agents present in `measurements`;
    /// other agents’ series are left intact.
    public mutating func ingest(
        _ measurements: [EntropyMeasurement],
        now: Date = Date()
    ) {
        for m in measurements {
            guard EntropyIntegrity.isTrustedSource(m.source) else { continue }
            guard let id = m.source.agentId?.trimmingCharacters(in: .whitespaces),
                  !id.isEmpty else { continue }
            append(agentId: id, measurement: m, retainedAt: now)
        }
    }

    /// Ingest a single measurement for one agent.
    public mutating func ingest(
        agentId: String,
        measurement: EntropyMeasurement,
        now: Date = Date()
    ) {
        let id = agentId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        guard EntropyIntegrity.isTrustedSource(measurement.source) else { return }
        // Prefer the measurement’s own agent id when present.
        if let mid = measurement.source.agentId, !mid.isEmpty, mid != id {
            // Refuse cross-agent contamination.
            return
        }
        append(agentId: id, measurement: measurement, retainedAt: now)
    }

    private mutating func append(
        agentId: String,
        measurement: EntropyMeasurement,
        retainedAt: Date
    ) {
        var series = seriesByAgent[agentId] ?? []
        let sample = AgentEntropySample(
            agentId: agentId,
            measurement: measurement,
            retainedAt: retainedAt
        )
        if let last = series.last,
           last.measurement.measuredAt == measurement.measuredAt,
           abs(last.measurement.bits - measurement.bits) < 1e-12 {
            // Same timestamp+bits: refresh presence/fields without growing series.
            series[series.count - 1] = sample
        } else {
            series.append(sample)
        }
        if series.count > maxSamplesPerAgent {
            series.removeFirst(series.count - maxSamplesPerAgent)
        }
        seriesByAgent[agentId] = series
    }

    // MARK: Query

    public func series(for agentId: String) -> AgentEntropySeries {
        let id = agentId.trimmingCharacters(in: .whitespaces)
        return AgentEntropySeries(agentId: id, samples: seriesByAgent[id] ?? [])
    }

    public func latest(for agentId: String) -> AgentEntropySample? {
        series(for: agentId).latest
    }

    public func allSeries() -> [AgentEntropySeries] {
        agentIds.map { series(for: $0) }
    }

    /// Latest measurements only (compatible with resolveAll `gate:` argument).
    public func latestMeasurements() -> [EntropyMeasurement] {
        seriesByAgent.values.compactMap(\.last?.measurement)
    }

    /// Snapshot map for UI publish (equality-gated).
    public func seriesMap() -> [String: [AgentEntropySample]] {
        seriesByAgent
    }

    // MARK: Presence-gated currency

    /// Whether this agent’s latest sample may be treated as **current** H.
    ///
    /// Requires: series non-empty, source canBeCurrent (live gate), and age
    /// within policy.maxAge. Offline / observed / stale never claim current.
    public func isCurrent(
        agentId: String,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> Bool {
        guard let sample = latest(for: agentId) else { return false }
        return Self.sampleIsCurrent(sample.measurement, now: now, policy: policy)
    }

    public static func sampleIsCurrent(
        _ m: EntropyMeasurement,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> Bool {
        guard m.source.canBeCurrent else { return false }
        return m.age(at: now) <= policy.maxAge
    }

    /// Resolve a display reading from memory for one agent (fail-closed).
    public func reading(
        for agentId: String,
        now: Date = Date(),
        policy: EntropyPolicy = .current,
        gateDBAvailable: Bool = true
    ) -> EntropyReading {
        guard let sample = latest(for: agentId) else {
            return .absent(gateDBAvailable ? .noDetector : .gateUnavailable)
        }
        let m = sample.measurement
        let age = m.age(at: now)
        if m.source.canBeCurrent, age <= policy.maxAge {
            return .measured(m)
        }
        return .stale(m, age: age)
    }

    /// Independent readings for every retained agent (and optional extra ids).
    public func readings(
        agentIds: [String]? = nil,
        now: Date = Date(),
        policy: EntropyPolicy = .current,
        gateDBAvailable: Bool = true
    ) -> [String: EntropyReading] {
        let ids = agentIds ?? self.agentIds
        var out: [String: EntropyReading] = [:]
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, out[id] == nil else { continue }
            out[id] = reading(
                for: id,
                now: now,
                policy: policy,
                gateDBAvailable: gateDBAvailable
            )
        }
        return out
    }

    /// Agents still eligible for live tracking (gate-live + fresh sample).
    public func currentlyTrackedAgentIds(
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> [String] {
        agentIds.filter { isCurrent(agentId: $0, now: now, policy: policy) }
    }

    /// Pure: whether presence + optional measurement mean “keep tracking now”.
    public static func shouldKeepTracking(
        presence: AgentPresence,
        latest: EntropyMeasurement?,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> Bool {
        // Process-attach / gate-live may still be tracked even before first H.
        if presence == .live {
            if let latest {
                // Live with a sample: track if current OR simply live (waiting
                // for next score) without inventing bits.
                return latest.source.canBeCurrent || presence.canBeBusy
            }
            return true
        }
        // Offline: never claim current tracking for H display.
        if presence == .offline { return false }
        // Observed: history may exist; not current telemetry.
        if let latest {
            return sampleIsCurrent(latest, now: now, policy: policy)
        }
        return false
    }
}

// MARK: - Multi-agent reply / attention board (pure)

/// One row on the concurrent-agent attention board: entropy currency + live surface.
public struct MultiAgentAttentionRow: Sendable, Equatable, Identifiable {
    public var id: String { agentId }
    public var agentId: String
    public var displayName: String
    public var surface: AgentLiveSurface
    public var entropyCurrent: Bool
    public var latestBits: Double?
    public var bitSeries: [Double]
    public var pendingAsk: GateDBReader.PendingAsk?

    public init(
        agentId: String,
        displayName: String,
        surface: AgentLiveSurface,
        entropyCurrent: Bool,
        latestBits: Double?,
        bitSeries: [Double],
        pendingAsk: GateDBReader.PendingAsk?
    ) {
        self.agentId = agentId
        self.displayName = displayName
        self.surface = surface
        self.entropyCurrent = entropyCurrent
        self.latestBits = latestBits
        self.bitSeries = bitSeries
        self.pendingAsk = pendingAsk
    }

    public var needsYou: Bool { surface.needsYou }
    public var canApproveDeny: Bool { pendingAsk != nil }
    public var activityReplayLine: String { surface.activityLine }
}

public enum MultiAgentAttentionBoard {
    /// Build ranked attention rows for concurrent agents without blocking on one.
    public static func rows(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        memory: AgentEntropyMemory = AgentEntropyMemory(),
        now: Date = Date(),
        policy: EntropyPolicy = .current,
        limit: Int = 8
    ) -> [MultiAgentAttentionRow] {
        let surfaces = AgentLiveSurfaceLogic.fleet(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            now: now,
            limit: max(limit, agents.count)
        )
        let byId = Dictionary(uniqueKeysWithValues: surfaces.map { ($0.agentId, $0) })
        var rows: [MultiAgentAttentionRow] = []
        for agent in agents {
            let surface = byId[agent.id] ?? AgentLiveSurfaceLogic.resolve(
                agent: agent,
                pendingAsks: pendingAsks,
                activity: activity,
                now: now
            )
            let series = memory.series(for: agent.id)
            let ask = pendingAsks.first { $0.agentId == agent.id }
            rows.append(MultiAgentAttentionRow(
                agentId: agent.id,
                displayName: agent.displayName,
                surface: surface,
                entropyCurrent: memory.isCurrent(agentId: agent.id, now: now, policy: policy),
                latestBits: series.latest?.bits,
                bitSeries: series.bitSeries,
                pendingAsk: ask
            ))
        }
        rows.sort { lhs, rhs in
            let lp = attentionRank(lhs.surface.attention)
            let rp = attentionRank(rhs.surface.attention)
            if lp != rp { return lp < rp }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return Array(rows.prefix(max(0, limit)))
    }

    private static func attentionRank(_ a: AgentLiveAttention) -> Int {
        switch a {
        case .needsYou: return 0
        case .working: return 1
        case .finished: return 2
        case .idle: return 3
        case .unknown: return 4
        }
    }

    /// Primary focus line — delegates to AgentLiveSurfaceLogic (actionable only).
    public static func primaryFocus(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        now: Date = Date()
    ) -> String? {
        AgentLiveSurfaceLogic.primaryFocus(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            now: now
        )
    }
}
