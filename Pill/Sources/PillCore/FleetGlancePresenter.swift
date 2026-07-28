import Foundation

// MARK: - Fleet glance snapshot (one resolve per UI tick)

/// Immutable product of one fleet entropy resolve for dual-HUD surfaces
/// (collapsed island, expanded board, menu-bar popover).
///
/// Views must not re-call `EntropyProvenance.resolve` / `resolveAll` for the
/// same tick inputs — bind this snapshot instead. Per-agent H is independent;
/// fleet H is never painted onto every row.
public struct FleetGlanceSnapshot: Sendable, Equatable {
    /// Worst/freshest fleet reading (collapse border, thermodynamic strip).
    public let fleetReading: EntropyReading
    /// Agent ids included in this tick’s per-agent resolve.
    public let agentIds: [String]
    /// Admitted live ids (sole-live unnamed bridge attach policy).
    public let liveAgentIds: Set<String>
    /// Live resolve map (bridge/gate only — no memory merge).
    public let liveReadings: [String: EntropyReading]
    /// Row map after `preferredRowReading(live, memory)` — what UI labels show.
    public let rowReadings: [String: EntropyReading]
    /// Companion-board deltas from **measured** live readings only.
    public let companionDeltas: [String: Double]
    /// Collapsed-island mono chip, e.g. `"H 8.2"`, or `nil` when unmeasured.
    public let collapsedEntropyLabel: String?
    /// Whether the expanded per-agent entropy strip should render.
    public let showPerAgentEntropyStrip: Bool

    public init(
        fleetReading: EntropyReading,
        agentIds: [String],
        liveAgentIds: Set<String>,
        liveReadings: [String: EntropyReading],
        rowReadings: [String: EntropyReading],
        companionDeltas: [String: Double],
        collapsedEntropyLabel: String?,
        showPerAgentEntropyStrip: Bool
    ) {
        self.fleetReading = fleetReading
        self.agentIds = agentIds
        self.liveAgentIds = liveAgentIds
        self.liveReadings = liveReadings
        self.rowReadings = rowReadings
        self.companionDeltas = companionDeltas
        self.collapsedEntropyLabel = collapsedEntropyLabel
        self.showPerAgentEntropyStrip = showPerAgentEntropyStrip
    }

    /// Lookup for a roster row — map only (no second bridge resolve).
    public func reading(for agentId: String) -> EntropyReading {
        let id = agentId.trimmingCharacters(in: .whitespaces)
        return rowReadings[id]
            ?? liveReadings[id]
            ?? .absent(.noDetector)
    }
}

// MARK: - Presenter

/// Shared fleet glance policy for pill + popover (AgentNotch-class density).
///
/// Keeps Shannon’s differentiator: **per-agent** entropy via one `resolveAll`
/// per tick, fail-closed, never inventing H.
public enum FleetGlancePresenter: Sendable {

    /// How to pick which agent ids get a per-agent resolve this tick.
    public enum ResolveScope: Sendable, Equatable {
        /// Use explicit listed board ids (pill expanded surfaces).
        case listed([String])
        /// Admit roster, prefer busy when any; optional hard cap.
        case admittedPreferBusy(limit: Int?)
    }

    /// Pure agent-id set for one tick (admission + density).
    public static func resolveAgentIds(
        agents: [AgentActivitySnapshot],
        pendingAgentIDs: Set<String>,
        scope: ResolveScope
    ) -> [String] {
        switch scope {
        case .listed(let ids):
            var seen = Set<String>()
            var out: [String] = []
            for raw in ids {
                let id = raw.trimmingCharacters(in: .whitespaces)
                guard !id.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                out.append(id)
            }
            return out
        case .admittedPreferBusy(let limit):
            let admitted = LiveRosterAdmission.filterListed(
                agents: agents,
                pendingAgentIDs: pendingAgentIDs
            )
            let busy = admitted.filter(\.status.isBusy)
            let pool = busy.isEmpty ? admitted : busy
            let capped: [AgentActivitySnapshot]
            if let limit, limit > 0 {
                capped = Array(pool.prefix(limit))
            } else {
                capped = pool
            }
            return capped.map(\.id)
        }
    }

    /// Live agent ids among admitted rows (for sole-live fleet bridge attach).
    public static func liveAgentIds(
        agents: [AgentActivitySnapshot],
        pendingAgentIDs: Set<String>
    ) -> Set<String> {
        let admitted = LiveRosterAdmission.filterListed(
            agents: agents,
            pendingAgentIDs: pendingAgentIDs
        )
        return Set(admitted.filter { $0.presence == .live }.map(\.id))
    }

    /// Companion deltas from an already-resolved reading map (no re-resolve).
    public static func companionDeltas(
        from readings: [String: EntropyReading]
    ) -> [String: Double] {
        var out: [String: Double] = [:]
        for (id, reading) in readings {
            guard case .measured(let m) = reading else { continue }
            if let d = m.deltaH, d.isFinite {
                out[id] = d
            } else if m.collapsed == true {
                out[id] = -4.0
            }
        }
        return out
    }

    /// Collapsed island H chip — **measured display only**.
    ///
    /// Prefers the primary agent’s row reading when it can display bits;
    /// otherwise falls back to fleet when the fleet reading is displayable.
    /// Synthetic / absent never yields a label (fail-closed).
    public static func collapsedEntropyLabel(
        primaryAgentId: String?,
        rowReadings: [String: EntropyReading],
        fleetReading: EntropyReading,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> String? {
        if let pid = primaryAgentId?.trimmingCharacters(in: .whitespaces),
           !pid.isEmpty,
           let reading = rowReadings[pid],
           let display = reading.display(at: now, policy: policy)
        {
            return String(format: "H %.1f", display.bits)
        }
        guard let display = fleetReading.display(at: now, policy: policy) else {
            return nil
        }
        // Fleet chip only when measured (not stale-observe-as-current alone
        // unless display path already allows it under policy).
        return String(format: "H %.1f", display.bits)
    }

    /// Merge live resolve + optional per-agent memory (same rule as roster rows).
    public static func rowReadings(
        live: [String: EntropyReading],
        memoryByAgent: [String: EntropyReading]
    ) -> [String: EntropyReading] {
        var out: [String: EntropyReading] = [:]
        out.reserveCapacity(live.count)
        for (id, liveReading) in live {
            out[id] = EntropyProvenance.preferredRowReading(
                live: liveReading,
                memory: memoryByAgent[id]
            )
        }
        // Memory-only ids (not in live resolve set) stay off the map — rows
        // not listed this tick must not resurrect phantom agents.
        return out
    }

    /// One snapshot for dual-HUD binding this tick.
    public static func snapshot(
        agents: [AgentActivitySnapshot],
        pendingAgentIDs: Set<String>,
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gate: [EntropyMeasurement],
        gateDBAvailable: Bool,
        scope: ResolveScope,
        memoryByAgent: [String: EntropyReading] = [:],
        primaryAgentId: String? = nil,
        companionBoardVisible: Bool = true,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> FleetGlanceSnapshot {
        let agentIds = resolveAgentIds(
            agents: agents,
            pendingAgentIDs: pendingAgentIDs,
            scope: scope
        )
        let liveIds = liveAgentIds(
            agents: agents,
            pendingAgentIDs: pendingAgentIDs
        )
        let fleet = EntropyProvenance.resolve(
            bridgeConnected: bridgeConnected,
            bridgeStatus: bridgeStatus,
            gate: gate,
            gateDBAvailable: gateDBAvailable,
            now: now,
            policy: policy
        )
        let live = EntropyProvenance.resolveAll(
            agentIds: agentIds,
            bridgeConnected: bridgeConnected,
            bridgeStatus: bridgeStatus,
            gate: gate,
            gateDBAvailable: gateDBAvailable,
            now: now,
            policy: policy,
            liveAgentIds: liveIds
        )
        let rows = rowReadings(live: live, memoryByAgent: memoryByAgent)
        let deltas = companionDeltas(from: live)
        let chip = collapsedEntropyLabel(
            primaryAgentId: primaryAgentId,
            rowReadings: rows,
            fleetReading: fleet,
            now: now,
            policy: policy
        )
        let anyH = ExpandedBoardDensity.anyDisplayableH(
            readings: rows, now: now, policy: policy
        )
        let showStrip = ExpandedBoardDensity.showPerAgentEntropyStrip(
            companionBoardVisible: companionBoardVisible,
            anyListedAgentHasMeasuredH: anyH
        )
        return FleetGlanceSnapshot(
            fleetReading: fleet,
            agentIds: agentIds,
            liveAgentIds: liveIds,
            liveReadings: live,
            rowReadings: rows,
            companionDeltas: deltas,
            collapsedEntropyLabel: chip,
            showPerAgentEntropyStrip: showStrip
        )
    }
}
