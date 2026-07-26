import Foundation

// MARK: - Multi-source session model (AgentPeek-parity W0)

/// Where a session row came from. Used for merge ranking and UI badges.
public enum SessionSourceKind: String, Sendable, Equatable, CaseIterable {
    /// Spoke to Shannon gate over the Unix socket (highest trust).
    case gate
    /// Parsed from the agent's own on-disk transcript / rollout artifacts.
    case artifact
    /// Frontmost-app / pet observation only.
    case observed

    /// Lower is stronger when reconciling two rows for the same logical session.
    public var mergeRank: Int {
        switch self {
        case .gate: return 0
        case .artifact: return 1
        case .observed: return 2
        }
    }
}

/// One coding-agent session as known from any provider.
///
/// Every optional field is *not reported* when the source lacks it — never
/// invent tokens, quota, branch, or model. Project to `AgentActivitySnapshot`
/// for existing pill surfaces.
public struct AgentSession: Sendable, Equatable, Identifiable {
    public var id: String
    public var agentId: String
    public var displayName: String
    public var presence: AgentPresence
    public var status: AgentRunStatus
    public var sourceKind: SessionSourceKind
    public var updatedAt: Date
    public var project: String?
    public var cwd: String?
    public var hostTerminal: String?
    public var stateLabel: String?
    public var lastTask: String?
    public var model: String?
    public var account: String?
    public var branch: String?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var sourcePath: String?
    public var startedAt: Date?
    public var activitySummary: String?

    public init(
        id: String,
        agentId: String,
        displayName: String,
        presence: AgentPresence,
        status: AgentRunStatus,
        sourceKind: SessionSourceKind,
        updatedAt: Date,
        project: String? = nil,
        cwd: String? = nil,
        hostTerminal: String? = nil,
        stateLabel: String? = nil,
        lastTask: String? = nil,
        model: String? = nil,
        account: String? = nil,
        branch: String? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        sourcePath: String? = nil,
        startedAt: Date? = nil,
        activitySummary: String? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.displayName = displayName
        self.presence = presence
        self.status = status
        self.sourceKind = sourceKind
        self.updatedAt = updatedAt
        self.project = project
        self.cwd = cwd
        self.hostTerminal = hostTerminal
        self.stateLabel = stateLabel
        self.lastTask = lastTask
        self.model = model
        self.account = account
        self.branch = branch
        self.tokensIn = tokensIn.flatMap { $0 >= 0 ? $0 : nil }
        self.tokensOut = tokensOut.flatMap { $0 >= 0 ? $0 : nil }
        self.sourcePath = sourcePath
        self.startedAt = startedAt
        self.activitySummary = activitySummary
    }

    /// Projection used by existing agent rows / busy roster.
    public func asActivitySnapshot() -> AgentActivitySnapshot {
        let task = (lastTask ?? activitySummary ?? stateLabel ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentActivitySnapshot(
            id: agentId,
            displayName: displayName,
            status: status,
            lastTask: AgentActivitySnapshot.shorten(task, max: 120),
            source: sourceKind.rawValue,
            updatedAt: updatedAt,
            resumable: status.isBusy || sourceKind == .artifact,
            historyCount: 1,
            presence: presence
        )
    }

    public var collapsedLine: String {
        let task = AgentActivitySnapshot.shorten(lastTask ?? activitySummary ?? "", max: 36)
        if task.isEmpty {
            return "\(displayName) · \(status.label)"
        }
        return "\(displayName) · \(task)"
    }
}

// MARK: - Provider plug-in surface

/// One telemetry source (gate DB, Claude JSONL, Codex rollouts, …).
public protocol SessionProviding: Sendable {
    var providerId: String { get }
    func fetchSessions(now: Date) -> [AgentSession]
}

// MARK: - Merge (pure)

public enum SessionMerge {
    /// Presence ranking: live > observed > offline.
    public static func presenceRank(_ p: AgentPresence) -> Int {
        switch p {
        case .live: return 0
        case .observed: return 1
        case .offline: return 2
        }
    }

    /// Merge multi-source session lists.
    ///
    /// Same `id` (preferred) or same `agentId`+`sourcePath` collapses to one
    /// row. Gate live outranks artifact/observed; newer `updatedAt` breaks ties.
    public static func merge(
        _ batches: [[AgentSession]],
        now: Date = Date()
    ) -> [AgentSession] {
        _ = now
        var byKey: [String: AgentSession] = [:]
        for batch in batches {
            for session in batch {
                let key = session.id
                if let existing = byKey[key] {
                    byKey[key] = prefer(existing, session)
                } else {
                    byKey[key] = session
                }
            }
        }
        return byKey.values.sorted { lhs, rhs in
            let lp = presenceRank(lhs.presence)
            let rp = presenceRank(rhs.presence)
            if lp != rp { return lp < rp }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Prefer stronger presence, then stronger source, then fresher update.
    ///
    /// Always fill optional meta (project / branch / model / tokens / …) from the
    /// non-winner when the winner lacks them — gate live must not drop artifact chips.
    public static func prefer(_ a: AgentSession, _ b: AgentSession) -> AgentSession {
        let winner: AgentSession
        let loser: AgentSession
        let pa = presenceRank(a.presence)
        let pb = presenceRank(b.presence)
        if pa != pb {
            if pa < pb { winner = a; loser = b } else { winner = b; loser = a }
        } else if a.sourceKind.mergeRank != b.sourceKind.mergeRank {
            if a.sourceKind.mergeRank < b.sourceKind.mergeRank {
                winner = a; loser = b
            } else {
                winner = b; loser = a
            }
        } else if a.updatedAt != b.updatedAt {
            if a.updatedAt >= b.updatedAt { winner = a; loser = b }
            else { winner = b; loser = a }
        } else {
            // Equal rank: keep `a` as base, still absorb missing fields from `b`.
            return fillMissing(from: a, using: b)
        }
        return fillMissing(from: winner, using: loser)
    }

    /// One best session per `agentId` (presence → source → freshness), with meta fill.
    public static func byAgentId(_ sessions: [AgentSession]) -> [String: AgentSession] {
        var best: [String: AgentSession] = [:]
        for s in sessions {
            if let existing = best[s.agentId] {
                best[s.agentId] = prefer(existing, s)
            } else {
                best[s.agentId] = s
            }
        }
        return best
    }

    /// Project merged sessions to legacy activity rows (one row per agent id,
    /// best presence wins).
    public static func projectToActivity(_ sessions: [AgentSession]) -> [AgentActivitySnapshot] {
        byAgentId(sessions).values
            .map { $0.asActivitySnapshot() }
            .sorted { lhs, rhs in
                let lb = lhs.status.isBusy && lhs.presence.canBeBusy
                let rb = rhs.status.isBusy && rhs.presence.canBeBusy
                if lb != rb { return lb && !rb }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private static func fillMissing(from primary: AgentSession, using secondary: AgentSession) -> AgentSession {
        var out = primary
        if out.project == nil { out.project = secondary.project }
        if out.cwd == nil { out.cwd = secondary.cwd }
        if out.hostTerminal == nil { out.hostTerminal = secondary.hostTerminal }
        if out.stateLabel == nil { out.stateLabel = secondary.stateLabel }
        if out.lastTask == nil || out.lastTask?.isEmpty == true {
            out.lastTask = secondary.lastTask
        }
        if out.model == nil { out.model = secondary.model }
        if out.account == nil { out.account = secondary.account }
        if out.branch == nil { out.branch = secondary.branch }
        if out.tokensIn == nil { out.tokensIn = secondary.tokensIn }
        if out.tokensOut == nil { out.tokensOut = secondary.tokensOut }
        if out.sourcePath == nil { out.sourcePath = secondary.sourcePath }
        if out.startedAt == nil { out.startedAt = secondary.startedAt }
        if out.activitySummary == nil { out.activitySummary = secondary.activitySummary }
        return out
    }
}

// MARK: - Registry

/// Collects session providers and merges their output.
public final class SessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [any SessionProviding] = []

    public init(providers: [any SessionProviding] = []) {
        self.providers = providers
    }

    public func register(_ provider: any SessionProviding) {
        lock.lock()
        defer { lock.unlock() }
        // Replace same provider id so re-register is idempotent.
        providers.removeAll { $0.providerId == provider.providerId }
        providers.append(provider)
    }

    public var providerIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return providers.map(\.providerId)
    }

    public func allSessions(now: Date = Date()) -> [AgentSession] {
        lock.lock()
        let snapshot = providers
        lock.unlock()
        let batches = snapshot.map { $0.fetchSessions(now: now) }
        return SessionMerge.merge(batches, now: now)
    }

    public func activitySnapshots(now: Date = Date()) -> [AgentActivitySnapshot] {
        SessionMerge.projectToActivity(allSessions(now: now))
    }
}

// MARK: - Gate adapter (wraps today's AgentActivitySnapshot rows)

/// Adapts gate / pet activity snapshots into the multi-source session model.
public struct GateSessionProvider: SessionProviding {
    public let providerId = "gate"
    public var agents: [AgentActivitySnapshot]

    public init(agents: [AgentActivitySnapshot] = []) {
        self.agents = agents
    }

    public func fetchSessions(now: Date) -> [AgentSession] {
        _ = now
        return agents.map { a in
            AgentSession(
                id: "gate:\(a.id)",
                agentId: a.id,
                displayName: a.displayName,
                presence: a.presence,
                status: a.status,
                sourceKind: a.source == "gate" || a.presence == .live ? .gate : .observed,
                updatedAt: a.updatedAt,
                lastTask: a.lastTask.isEmpty ? nil : a.lastTask,
                activitySummary: a.lastTask.isEmpty ? nil : a.lastTask
            )
        }
    }
}
