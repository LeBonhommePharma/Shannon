import Foundation

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
        pendingPrompt: String? = nil
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

    /// Whether to show a tertiary "Gate · approve" hint on roster rows.
    /// True only when the gate has a matching ask (`canAnswerInline`) — never
    /// invent Approve affordances when the hub is offline / ask is missing.
    public var showsApproveHint: Bool { canAnswerInline }
}

// MARK: - Pure presenter

/// Assembles session cards and collapsed status from real local signals only.
public enum SessionContentPresenter {

    /// Build usage from session token fields — fail-closed when none reported.
    public static func usageFromSession(_ session: AgentSession) -> AgentUsageSnapshot? {
        let tin = session.tokensIn
        let tout = session.tokensOut
        guard tin != nil || tout != nil else { return nil }
        let used: Int?
        switch (tin, tout) {
        case let (i?, o?):
            let sum = i + o
            used = sum > 0 ? sum : (i > 0 ? i : nil)
        case let (i?, nil):
            used = i > 0 ? i : nil
        case let (nil, o?):
            used = o > 0 ? o : nil
        case (nil, nil):
            used = nil
        }
        return AgentLiveSurfaceLogic.usageIfReal(AgentUsageSnapshot(tokensUsed: used))
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
        now: Date = Date()
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
            pendingPrompt: ask.map(\.prompt).flatMap { nonEmpty($0) }
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
        liveAgentIds: Set<String> = []
    ) -> [SessionContentCard] {
        let filtered = sessionsExcludingLiveAgents(sessions, liveAgentIds: liveAgentIds)
        let built = filtered.map {
            card(session: $0, pendingAsks: pendingAsks, activity: activity, now: now)
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
        limit: Int = 4
    ) -> [SessionContentCard] {
        // Merge session token usage into the resolve map once so roster cards
        // share one surface tick with rankedAgentSurfaces (ENH-007).
        var mergedUsage = usageByAgent
        for (id, session) in sessionsByAgent {
            if mergedUsage[id] == nil, let u = usageFromSession(session) {
                mergedUsage[id] = u
            }
        }
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
                pendingPrompt: ask.map(\.prompt).flatMap { nonEmpty($0) }
            ))
        }
        return Array(out.prefix(max(0, limit)))
    }

    /// Collapsed-pill status copy: primary focus, multi-agent count hint, or quiet idle.
    ///
    /// Returns the primary focus line only (chips are separate UI). When nothing
    /// actionable is happening, returns `"Shannon · idle"`.
    public static func collapsedStatusLine(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date()
    ) -> String {
        if let focus = AgentLiveSurfaceLogic.primaryFocus(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: usageByAgent,
            now: now
        ) {
            return focus
        }
        return "Shannon · idle"
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
