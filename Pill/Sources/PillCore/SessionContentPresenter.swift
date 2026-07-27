import Foundation
import ShannonCore

// MARK: - Session content card (AgentNotch-class field assembly)

/// One session row for expanded pill / menu-bar roster / pulled-sessions.
///
/// Optional fields are **absent** when the source never reported them —
/// never zero-filled, never guessed. Attention and badge wording come from
/// `AgentLiveSurfaceLogic` so notch + popover cannot drift.
public struct SessionContentCard: Sendable, Equatable, Identifiable {
    public var id: String
    public var agentId: String
    public var displayName: String
    public var attention: AgentLiveAttention
    public var badgeLabel: String
    /// Live tool / ask / task line (may be empty when quiet).
    public var activityLine: String
    public var project: String?
    public var branch: String?
    public var model: String?
    public var usage: AgentUsageSnapshot?
    /// Relative age of last update, e.g. `"12s"` / `"3m"`.
    public var relativeAge: String?
    /// Wall-clock of last update — used for same-attention ranking, not drawn alone.
    public var updatedAt: Date
    public var needsYou: Bool
    public var isFinished: Bool
    public var sourceKind: SessionSourceKind
    /// Collapsed-style focus for this row (e.g. `"Needs you · Claude Code"`).
    public var collapsedFocus: String
    /// Whether the gate can answer an open ask for this agent (Approve/Deny).
    public var canAnswerInline: Bool
    /// Pending ask prompt when `needsYou` and an ask exists.
    public var pendingPrompt: String?
    /// Gate Unix socket present — fail-closed when unknown (UX-043).
    public var gateAvailable: Bool

    public init(
        id: String,
        agentId: String,
        displayName: String,
        attention: AgentLiveAttention,
        badgeLabel: String,
        activityLine: String,
        project: String? = nil,
        branch: String? = nil,
        model: String? = nil,
        usage: AgentUsageSnapshot? = nil,
        relativeAge: String? = nil,
        updatedAt: Date = .distantPast,
        needsYou: Bool = false,
        isFinished: Bool = false,
        sourceKind: SessionSourceKind = .observed,
        collapsedFocus: String = "",
        canAnswerInline: Bool = false,
        pendingPrompt: String? = nil,
        gateAvailable: Bool = false
    ) {
        self.id = id
        self.agentId = agentId
        self.displayName = displayName
        self.attention = attention
        self.badgeLabel = badgeLabel
        self.activityLine = activityLine
        self.project = project
        self.branch = branch
        self.model = model
        self.usage = usage
        self.relativeAge = relativeAge
        self.updatedAt = updatedAt
        self.needsYou = needsYou
        self.isFinished = isFinished
        self.sourceKind = sourceKind
        self.collapsedFocus = collapsedFocus
        self.canAnswerInline = canAnswerInline
        self.pendingPrompt = pendingPrompt
        self.gateAvailable = gateAvailable
    }

    /// Secondary meta chips: project · branch · model — only real fields.
    public var metaChips: [String] {
        var chips: [String] = []
        if let project, !project.isEmpty { chips.append(project) }
        if let branch, !branch.isEmpty { chips.append(branch) }
        if let model, !model.isEmpty { chips.append(model) }
        return chips
    }

    /// Single-line meta for compact rows (`website · main · GPT-5`).
    public var metaLine: String? {
        let chips = metaChips
        return chips.isEmpty ? nil : chips.joined(separator: " · ")
    }

    /// Usage short label when a real source provided metrics.
    public var usageLabel: String? { usage?.shortLabel }

    /// Detail line under roster name/badge: prefer pending ask prompt when needs-you.
    ///
    /// Fail-closed: never invents prompt text. When `needsYou` and a non-empty
    /// `pendingPrompt` exist, returns a shortened prompt (~90 chars). Otherwise
    /// falls back to `activityLine` when attention is known. Empty/unknown → nil.
    public var rosterDetailLine: String? {
        if needsYou, let prompt = pendingPrompt {
            let short = AgentActivitySnapshot.shorten(prompt, max: 90)
            if !short.isEmpty { return short }
        }
        if !activityLine.isEmpty, attention != .unknown {
            return activityLine
        }
        return nil
    }

    /// Whether to show a tertiary gate-approve hint on roster rows
    /// (`GateAskActionCopy.rosterApproveHint`). True only when the gate has a
    /// matching ask **and** the hub socket is up (`canAnswerInline && gateAvailable`)
    /// — never invent Approve affordances when offline / ask is missing (UX-043).
    public var showsApproveHint: Bool { canAnswerInline && gateAvailable }
}

// MARK: - Companion board density (macOS 14+ expanded path)

/// Optional meta + usage for one companion board row.
///
/// Fail-closed: both fields nil when no session/usage source reported them.
/// Shared by pure assembly and `CompanionBoardView` so the macOS 14+ path
/// cannot silently drop project/branch/model/usage that `agentRow` already shows.
public struct CompanionBoardDensity: Sendable, Equatable {
    public var metaLine: String?
    public var usageLabel: String?

    public init(metaLine: String? = nil, usageLabel: String? = nil) {
        self.metaLine = Self.nonEmpty(metaLine)
        self.usageLabel = Self.nonEmpty(usageLabel)
    }

    public var isEmpty: Bool { metaLine == nil && usageLabel == nil }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - Pure presenter

/// Assembles session cards and collapsed status from real local signals only.
public enum SessionContentPresenter {

    /// Build usage from session token + window fields — fail-closed when none reported.
    ///
    /// Delegates to `UsageBridge` (UsageCore) so readers + presenters share one map.
    /// Windows pass through only when the session already carries provider-reported
    /// windows (ENH-026); never derived from token totals.
    public static func usageFromSession(_ session: AgentSession) -> AgentUsageSnapshot? {
        UsageBridge.snapshot(
            tokensIn: session.tokensIn,
            tokensOut: session.tokensOut,
            windows: session.usageWindows,
            planLabel: session.usagePlanLabel
        )
    }

    /// Map sessions → usage snapshots for surface resolve (fail-closed, no zeros).
    ///
    /// Used by notch pill **and** menu-bar roster so collapsed chips / expanded
    /// usage badges share one path (AgentNotch/AgentPeek density).
    public static func usageByAgent(
        from sessionsByAgent: [String: AgentSession]
    ) -> [String: AgentUsageSnapshot] {
        var out: [String: AgentUsageSnapshot] = [:]
        for (id, session) in sessionsByAgent {
            if let u = usageFromSession(session) { out[id] = u }
        }
        return out
    }

    /// Merge explicit usage with session-derived tokens (explicit wins per id).
    public static func mergedUsageByAgent(
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        sessionsByAgent: [String: AgentSession] = [:]
    ) -> [String: AgentUsageSnapshot] {
        var merged = usageByAgent
        for (id, session) in sessionsByAgent {
            if merged[id] == nil, let u = usageFromSession(session) {
                merged[id] = u
            }
        }
        return merged
    }

    /// Optional meta line for an agent when a session has project/branch/model.
    public static func metaLine(
        agentId: String,
        sessionsByAgent: [String: AgentSession]
    ) -> String? {
        guard let s = sessionsByAgent[agentId] else { return nil }
        var chips: [String] = []
        if let p = nonEmpty(s.project) { chips.append(p) }
        if let b = nonEmpty(s.branch) { chips.append(b) }
        if let m = nonEmpty(s.model) { chips.append(m) }
        return chips.isEmpty ? nil : chips.joined(separator: " · ")
    }

    /// Board rows with surfaces — same inputs as menu-bar `cardsFromAgents`.
    ///
    /// Pure so tests prove notch cannot drop `sessionsByAgent` / usage without
    /// the returned surface.usage / meta diverging from card assembly.
    public static func listedSurfaces(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        sessionsByAgent: [String: AgentSession] = [:],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date(),
        limit: Int = 4
    ) -> [(agent: AgentActivitySnapshot, surface: AgentLiveSurface, metaLine: String?)] {
        let merged = mergedUsageByAgent(
            usageByAgent: usageByAgent,
            sessionsByAgent: sessionsByAgent
        )
        let pairs = AgentLiveSurfaceLogic.rankedAgentSurfaces(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: merged,
            now: now,
            limit: limit
        )
        return pairs.map { agent, surface in
            let meta = metaLine(agentId: agent.id, sessionsByAgent: sessionsByAgent)
            return (agent, surface, meta)
        }
    }

    /// Optional project/branch/model + usage labels for the **macOS 14+** companion board.
    ///
    /// Fail-closed: empty map when no session fields or usage exist. Pure so tests
    /// prove `CompanionBoardView` density cannot be dropped without this map going empty.
    public static func companionBoardDensityByAgent(
        sessionsByAgent: [String: AgentSession],
        usageByAgent: [String: AgentUsageSnapshot] = [:]
    ) -> [String: CompanionBoardDensity] {
        let merged = mergedUsageByAgent(
            usageByAgent: usageByAgent,
            sessionsByAgent: sessionsByAgent
        )
        var ids = Set(sessionsByAgent.keys)
        ids.formUnion(merged.keys)
        var out: [String: CompanionBoardDensity] = [:]
        for id in ids {
            let meta = metaLine(agentId: id, sessionsByAgent: sessionsByAgent)
            let usage = merged[id]?.shortLabel
            let density = CompanionBoardDensity(metaLine: meta, usageLabel: usage)
            if !density.isEmpty {
                out[id] = density
            }
        }
        return out
    }

    /// Density overlay from `listedSurfaces` rows (same path the #else agentRow uses).
    public static func companionBoardDensity(
        from listed: [(agent: AgentActivitySnapshot, surface: AgentLiveSurface, metaLine: String?)]
    ) -> [String: CompanionBoardDensity] {
        var out: [String: CompanionBoardDensity] = [:]
        for pair in listed {
            let density = CompanionBoardDensity(
                metaLine: pair.metaLine,
                usageLabel: pair.surface.usage?.shortLabel
            )
            if !density.isEmpty {
                out[pair.agent.id] = density
            }
        }
        return out
    }

    /// Resolve live surface for one session (identity + gate activity + asks).
    public static func resolveSurface(
        session: AgentSession,
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usage: AgentUsageSnapshot? = nil,
        now: Date = Date()
    ) -> AgentLiveSurface {
        let snap = session.asActivitySnapshot()
        let u = usage ?? usageFromSession(session)
        return AgentLiveSurfaceLogic.resolve(
            agent: snap,
            pendingAsks: pendingAsks,
            activity: activity,
            usage: u,
            now: now
        )
    }

    /// One card for one session — optional fields stay nil when absent.
    public static func card(
        session: AgentSession,
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        now: Date = Date(),
        gateAvailable: Bool = false
    ) -> SessionContentCard {
        let surface = resolveSurface(
            session: session,
            pendingAsks: pendingAsks,
            activity: activity,
            now: now
        )
        let ask = pendingAsks.first { $0.agentId == session.agentId }
        let fallback = session.asActivitySnapshot().statusLine(at: now)
        let project = nonEmpty(session.project)
        let branch = nonEmpty(session.branch)
        let model = nonEmpty(session.model)
        let activityLine: String = {
            if !surface.activityLine.isEmpty { return surface.activityLine }
            if let task = nonEmpty(session.lastTask) { return task }
            if let summary = nonEmpty(session.activitySummary) { return summary }
            return ""
        }()
        return SessionContentCard(
            id: session.id,
            agentId: session.agentId,
            displayName: surface.displayName.isEmpty ? session.displayName : surface.displayName,
            attention: surface.attention,
            badgeLabel: AgentLiveSurfaceLogic.badgeLabel(
                surface: surface,
                fallbackStatusLine: fallback
            ),
            activityLine: activityLine,
            project: project,
            branch: branch,
            model: model,
            usage: surface.usage,
            relativeAge: AgentActivitySnapshot.age(since: session.updatedAt, now: now),
            updatedAt: session.updatedAt,
            needsYou: surface.needsYou,
            isFinished: surface.isFinished,
            sourceKind: session.sourceKind,
            collapsedFocus: surface.collapsedFocus,
            canAnswerInline: surface.needsYou && ask != nil,
            pendingPrompt: ask.map(\.prompt).flatMap { nonEmpty($0) },
            gateAvailable: gateAvailable
        )
    }

    /// Drop artifact/pulled rows whose `agentId` is already on the live roster.
    ///
    /// Keeps the fleet glanceable (ENH-005): live agents own the Active-now
    /// section; disk meta for those ids already folds into roster via
    /// `sessionsByAgent`. Empty `liveAgentIds` returns `sessions` unchanged.
    public static func sessionsExcludingLiveAgents(
        _ sessions: [AgentSession],
        liveAgentIds: Set<String>
    ) -> [AgentSession] {
        guard !liveAgentIds.isEmpty else { return sessions }
        return sessions.filter { !liveAgentIds.contains($0.agentId) }
    }

    /// Ranked session cards: needs-you → working → finished → idle → unknown.
    public static func cards(
        sessions: [AgentSession],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        now: Date = Date(),
        limit: Int = 8,
        liveAgentIds: Set<String> = [],
        gateAvailable: Bool = false
    ) -> [SessionContentCard] {
        let filtered = sessionsExcludingLiveAgents(sessions, liveAgentIds: liveAgentIds)
        let built = filtered.map {
            card(
                session: $0,
                pendingAsks: pendingAsks,
                activity: activity,
                now: now,
                gateAvailable: gateAvailable
            )
        }
        let ranked = built.sorted { lhs, rhs in
            let lp = rank(lhs.attention)
            let rp = rank(rhs.attention)
            if lp != rp { return lp < rp }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                == .orderedAscending
        }
        return Array(ranked.prefix(max(0, limit)))
    }

    /// Card projection from live agent snapshots (menu-bar roster / agent board).
    public static func cardsFromAgents(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        sessionsByAgent: [String: AgentSession] = [:],
        now: Date = Date(),
        limit: Int = 4,
        gateAvailable: Bool = false
    ) -> [SessionContentCard] {
        // Merge session token usage once so roster cards share one surface tick
        // with notch `listedSurfaces` (ENH-007 / product-class density).
        let mergedUsage = mergedUsageByAgent(
            usageByAgent: usageByAgent,
            sessionsByAgent: sessionsByAgent
        )
        let ranked = AgentLiveSurfaceLogic.rankedAgentSurfaces(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: mergedUsage,
            now: now,
            limit: max(limit, agents.count)
        )
        var out: [SessionContentCard] = []
        for (agent, surface) in ranked {
            // Live surface owns attention; session only contributes
            // optional meta (project/branch/model) fail-closed.
            let session = sessionsByAgent[agent.id]
            let ask = pendingAsks.first { $0.agentId == agent.id }
            out.append(SessionContentCard(
                id: session?.id ?? "agent:\(agent.id)",
                agentId: agent.id,
                displayName: surface.displayName,
                attention: surface.attention,
                badgeLabel: AgentLiveSurfaceLogic.badgeLabel(
                    surface: surface,
                    fallbackStatusLine: agent.statusLine(at: now)
                ),
                activityLine: surface.activityLine,
                project: nonEmpty(session?.project),
                branch: nonEmpty(session?.branch),
                model: nonEmpty(session?.model),
                usage: surface.usage,
                relativeAge: agent.relativeAge(at: now),
                updatedAt: agent.updatedAt,
                needsYou: surface.needsYou,
                isFinished: surface.isFinished,
                sourceKind: session?.sourceKind
                    ?? (agent.presence == .live ? .gate : .observed),
                collapsedFocus: surface.collapsedFocus,
                canAnswerInline: surface.needsYou && ask != nil,
                pendingPrompt: ask.map(\.prompt).flatMap { nonEmpty($0) },
                gateAvailable: gateAvailable
            ))
        }
        return Array(out.prefix(max(0, limit)))
    }

    /// Collapsed-pill status copy: primary focus, multi-agent count hint, or quiet idle.
    ///
    /// Returns the primary focus line only (chips are separate UI). When nothing
    /// actionable is happening, returns ``CompanionFocusCopy/quietFace`` (watch face parity).
    ///
    /// **Multi-agent (ENH-015):** when `collapsedActiveCount > 1` and the primary
    /// attention is working or finished (never needs-you), re-prefix the real
    /// activity fragment as `"N agents · \(activityLine)"`. Does not invent tool
    /// text — empty activity falls back to the single-agent `collapsedFocus`.
    public static func collapsedStatusLine(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date()
    ) -> String {
        guard let surface = AgentLiveSurfaceLogic.primarySurface(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: usageByAgent,
            now: now
        ) else {
            // UX-017: same quiet token as watch face / complications.
            return CompanionFocusCopy.quietFace
        }

        let activeCount = collapsedActiveCount(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            now: now
        )
        if let multi = multiAgentCollapsedLabel(
            activeCount: activeCount,
            primary: surface
        ) {
            return multi
        }
        return surface.collapsedFocus
    }

    /// `"N agents · <activity>"` when several agents need a glance and primary
    /// is working/finished with a real activity line. Fail-closed otherwise.
    public static func multiAgentCollapsedLabel(
        activeCount: Int,
        primary: AgentLiveSurface
    ) -> String? {
        guard activeCount > 1 else { return nil }
        switch primary.attention {
        case .working, .finished:
            break
        case .needsYou, .idle, .unknown:
            return nil
        }
        let fragment = primary.activityLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty else { return nil }
        return "\(activeCount) agents · \(fragment)"
    }

    /// Compact usage chip for collapsed pill — only when a real source provided it.
    ///
    /// **Primary-only:** the chip follows `primarySurface` (needs-you first).
    /// If the primary agent has no usage but a lower-ranked working agent does,
    /// the chip stays nil — never scavenge secondary agents for density (ENH-012).
    public static func collapsedUsageChip(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date()
    ) -> String? {
        guard let top = AgentLiveSurfaceLogic.primarySurface(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: usageByAgent,
            now: now
        ) else { return nil }
        return top.usage?.shortLabel
    }

    /// Multi-agent count for collapsed chip (needs-you + working only).
    public static func collapsedActiveCount(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        now: Date = Date()
    ) -> Int {
        AgentLiveSurfaceLogic.activeFleetCount(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            now: now
        )
    }

    // MARK: - Internals

    private static func rank(_ a: AgentLiveAttention) -> Int {
        switch a {
        case .needsYou: return 0
        case .working: return 1
        case .finished: return 2
        case .idle: return 3
        case .unknown: return 4
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
