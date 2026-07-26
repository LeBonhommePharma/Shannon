import Foundation
import ShannonCore
@_exported import UsageCore

// MARK: - Clean-room live agent surface (AgentNotch-class outcomes)

/// PillCore name for the shared UsageCore snapshot (ENH-014).
public typealias AgentUsageSnapshot = UsageSnapshot

/// What the agent is doing **now**, derived only from local Shannon observations
/// (gate activity rows, pending asks, agent status/task). No invented telemetry.
///
/// Public product outcomes inspired by AgentNotch marketing (live tool line,
/// needs-you, completion, multi-agent fleet, usage when real) — **not** their
/// source, stack, or UI chrome.
public enum AgentLiveAttention: String, Sendable, Equatable, CaseIterable {
    /// Human must act (pending gate approval).
    case needsYou
    /// Agent is actively working (busy + live tool/task signal).
    case working
    /// Run finished recently (completion event or idle after work).
    case finished
    /// Connected or observed but quiet.
    case idle
    /// No trustworthy signal.
    case unknown
}

/// Coarse tool category for the live line (read / edit / shell / …).
public enum AgentToolKind: String, Sendable, Equatable, CaseIterable {
    case read
    case edit
    case shell
    case test
    case browse
    case other
    case none

    public var verb: String {
        switch self {
        case .read: return "Reading"
        case .edit: return "Editing"
        case .shell: return "Running"
        case .test: return "Testing"
        case .browse: return "Browsing"
        case .other: return "Working"
        case .none: return ""
        }
    }
}


/// One agent’s notch/menubar live surface.
public struct AgentLiveSurface: Sendable, Equatable, Identifiable {
    public var id: String { agentId }
    public var agentId: String
    public var displayName: String
    public var attention: AgentLiveAttention
    public var toolKind: AgentToolKind
    /// Short line for collapsed island / row (e.g. "Editing store.ts").
    public var activityLine: String
    public var usage: AgentUsageSnapshot?
    /// True when a human-actionable pending ask is open for this agent.
    public var needsYou: Bool
    public var isFinished: Bool

    public init(
        agentId: String,
        displayName: String,
        attention: AgentLiveAttention,
        toolKind: AgentToolKind = .none,
        activityLine: String,
        usage: AgentUsageSnapshot? = nil,
        needsYou: Bool = false,
        isFinished: Bool = false
    ) {
        self.agentId = agentId
        self.displayName = displayName
        self.attention = attention
        self.toolKind = toolKind
        self.activityLine = activityLine
        self.usage = usage
        self.needsYou = needsYou
        self.isFinished = isFinished
    }

    /// Collapsed-pill priority line (no agent name prefix).
    public var collapsedFocus: String {
        if needsYou { return "Needs you · \(displayName)" }
        if attention == .working, !activityLine.isEmpty {
            return "\(displayName) · \(activityLine)"
        }
        if isFinished { return "Done · \(displayName)" }
        return activityLine.isEmpty ? displayName : "\(displayName) · \(activityLine)"
    }
}

// MARK: - Pure resolver

public enum AgentLiveSurfaceLogic {
    /// Freshness windows (seconds).
    public static let activityFreshSeconds: TimeInterval = 90
    public static let finishedFreshSeconds: TimeInterval = 180
    public static let taskFreshSeconds: TimeInterval = 120

    /// Build a live surface for one agent from local observations only.
    public static func resolve(
        agent: AgentActivitySnapshot,
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usage: AgentUsageSnapshot? = nil,
        now: Date = Date()
    ) -> AgentLiveSurface {
        let style = AgentStyleCatalog.style(for: agent.id)
        let name = agent.displayName.isEmpty ? style.displayName : agent.displayName
        let gateAsk = pendingAsks.contains { $0.agentId == agent.id }
        // Artifact/session "your turn" (e.g. Kimi wait markers) — elevate needsYou
        // without inventing a gate ask. canAnswerInline stays false when no ask.
        let sessionWait = agent.status == .blocked
        let needs = gateAsk || sessionWait
        let mine = activity.filter { $0.agentId == agent.id }
        let latest = mine.max(by: { $0.at < $1.at })
        let tool = classifyTool(event: latest)
        let finished = isCompletion(event: latest, now: now)
        let workingBusy = agent.status.isBusy && agent.presence.canBeBusy
            && !sessionWait  // blocked wait is needs-you, not "working"
        let taskFresh = !agent.lastTask.isEmpty
            && now.timeIntervalSince(agent.updatedAt) <= taskFreshSeconds
        let activityFresh = latest.map {
            now.timeIntervalSince($0.at) <= activityFreshSeconds
        } ?? false

        // ── Attention priority: needs you > finished > working > idle/unknown
        // Finished is checked before workingBusy so a fresh `task_complete`
        // beats a stale mid_task / busy status left on the agent row.
        if needs {
            let prompt: String = {
                if let gate = pendingAsks.first(where: { $0.agentId == agent.id })?.prompt,
                   !gate.isEmpty {
                    return gate
                }
                // Session wait: prefer lastTask / activity line from the snapshot.
                if !agent.lastTask.isEmpty { return agent.lastTask }
                return ""
            }()
            let short = AgentActivitySnapshot.shorten(prompt, max: 40)
            let line: String = {
                if !short.isEmpty { return short }
                if sessionWait && !gateAsk {
                    return "Waiting — answer in terminal"
                }
                return "Waiting for approval"
            }()
            return AgentLiveSurface(
                agentId: agent.id,
                displayName: name,
                attention: .needsYou,
                toolKind: .none,
                activityLine: line,
                usage: usageIfReal(usage),
                needsYou: true,
                isFinished: false
            )
        }

        if finished {
            let line = latest.map { AgentActivitySnapshot.shorten($0.line, max: 42) }
                ?? "Ready for review"
            return AgentLiveSurface(
                agentId: agent.id,
                displayName: name,
                attention: .finished,
                toolKind: .none,
                activityLine: line.isEmpty ? "Finished" : line,
                usage: usageIfReal(usage),
                needsYou: false,
                isFinished: true
            )
        }

        if workingBusy || (activityFresh && tool != .none) {
            let line = liveWorkLine(
                tool: tool,
                event: latest,
                lastTask: agent.lastTask,
                activityFresh: activityFresh
            )
            return AgentLiveSurface(
                agentId: agent.id,
                displayName: name,
                attention: .working,
                toolKind: activityFresh ? tool : .other,
                activityLine: line,
                usage: usageIfReal(usage),
                needsYou: false,
                isFinished: false
            )
        }

        if agent.presence == .live {
            let line = taskFresh
                ? AgentActivitySnapshot.shorten(agent.lastTask, max: 42)
                : "live"
            return AgentLiveSurface(
                agentId: agent.id,
                displayName: name,
                attention: .idle,
                toolKind: .none,
                activityLine: line.isEmpty ? "live" : line,
                usage: usageIfReal(usage),
                needsYou: false,
                isFinished: false
            )
        }

        if agent.presence == .observed, taskFresh {
            return AgentLiveSurface(
                agentId: agent.id,
                displayName: name,
                attention: .idle,
                toolKind: .none,
                activityLine: AgentActivitySnapshot.shorten(agent.lastTask, max: 42),
                usage: usageIfReal(usage),
                needsYou: false,
                isFinished: false
            )
        }

        return AgentLiveSurface(
            agentId: agent.id,
            displayName: name,
            attention: .unknown,
            toolKind: .none,
            activityLine: "",
            usage: usageIfReal(usage),
            needsYou: false,
            isFinished: false
        )
    }

    /// Fleet surfaces for agents that matter in a notch glance.
    ///
    /// Order: needs-you first, then working, then finished, then live idle.
    /// Caps at `limit` so the board stays notch-sized.
    public static func fleet(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date(),
        limit: Int = 4
    ) -> [AgentLiveSurface] {
        let surfaces = agents.map { a in
            resolve(
                agent: a,
                pendingAsks: pendingAsks,
                activity: activity,
                usage: usageByAgent[a.id],
                now: now
            )
        }
        let ranked = surfaces.sorted { lhs, rhs in
            let lp = rank(lhs.attention)
            let rp = rank(rhs.attention)
            if lp != rp { return lp < rp }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        // Drop pure unknown with empty line (noise).
        let useful = ranked.filter {
            $0.attention != .unknown || $0.needsYou || !$0.activityLine.isEmpty
        }
        return Array(useful.prefix(max(0, limit)))
    }

    /// Best single focus line for the collapsed island / menubar scan.
    ///
    /// Only **actionable** attention states — needs-you, working, finished.
    /// Idle / unknown must return `nil` so HubScanLine / host load can still
    /// own the quiet collapsed subtitle (never suppress "Hub ready").
    public static func primaryFocus(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date()
    ) -> String? {
        primarySurface(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: usageByAgent,
            now: now
        )?.collapsedFocus
    }

    /// Top actionable surface (needs-you / working / finished), or nil when quiet.
    public static func primarySurface(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date()
    ) -> AgentLiveSurface? {
        let f = fleet(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: usageByAgent,
            now: now,
            limit: 4
        )
        return f.first(where: {
            switch $0.attention {
            case .needsYou, .working, .finished: return true
            case .idle, .unknown: return false
            }
        })
    }

    /// How many agents currently need a glance (needs-you or working).
    ///
    /// Used for the collapsed multi-agent count chip — never invents busy work.
    public static func activeFleetCount(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date()
    ) -> Int {
        fleet(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: usageByAgent,
            now: now,
            limit: max(4, agents.count)
        ).filter {
            $0.attention == .needsYou || $0.attention == .working
        }.count
    }

    /// Capsule badge text shared by notch + menu-bar (and mobile via ShannonCore).
    ///
    /// Delegates to `AgentAttentionCopy` so Mac / iPhone / iPad / Watch cannot
    /// drift on "needs you" / "working" / "done" / "live" (UX-001).
    public static func badgeLabel(
        surface: AgentLiveSurface,
        fallbackStatusLine: String
    ) -> String {
        let kind: AgentAttentionCopy.Kind
        switch surface.attention {
        case .needsYou: kind = .needsYou
        case .working: kind = .working
        case .finished: kind = .finished
        case .idle: kind = .idle
        case .unknown: kind = .unknown
        }
        let tool = surface.toolKind == .none ? nil : surface.toolKind.rawValue
        return AgentAttentionCopy.badgeLabel(
            kind: kind,
            toolKindRaw: tool,
            fallback: fallbackStatusLine
        )
    }

    /// Rank agents with their surfaces: needs-you → working → finished → idle → unknown.
    ///
    /// **One `resolve` per agent** for the tick (ENH-007). Callers that need both
    /// the snapshot and the surface (roster cards, boards) should use this instead
    /// of `rankedAgents` + re-`resolve`.
    public static func rankedAgentSurfaces(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date(),
        limit: Int = 4
    ) -> [(agent: AgentActivitySnapshot, surface: AgentLiveSurface)] {
        // Last write wins when the same agent id appears more than once.
        var byId: [String: AgentActivitySnapshot] = [:]
        var firstSeenOrder: [String] = []
        byId.reserveCapacity(agents.count)
        for a in agents {
            if byId[a.id] == nil { firstSeenOrder.append(a.id) }
            byId[a.id] = a
        }
        var surfaceById: [String: AgentLiveSurface] = [:]
        surfaceById.reserveCapacity(byId.count)
        for (id, a) in byId {
            surfaceById[id] = resolve(
                agent: a,
                pendingAsks: pendingAsks,
                activity: activity,
                usage: usageByAgent[id],
                now: now
            )
        }
        let rankedSurfaces = firstSeenOrder.compactMap { surfaceById[$0] }.sorted { lhs, rhs in
            let lp = rank(lhs.attention)
            let rp = rank(rhs.attention)
            if lp != rp { return lp < rp }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                == .orderedAscending
        }
        // Fleet-useful first (same filter as `fleet`).
        let useful = rankedSurfaces.filter {
            $0.attention != .unknown || $0.needsYou || !$0.activityLine.isEmpty
        }
        var ordered: [(agent: AgentActivitySnapshot, surface: AgentLiveSurface)] = []
        var seen = Set<String>()
        for s in useful {
            guard let a = byId[s.agentId], !seen.contains(a.id) else { continue }
            ordered.append((a, s))
            seen.insert(a.id)
        }
        // Quiet / unknown remainder keep first-seen input order.
        for id in firstSeenOrder where !seen.contains(id) {
            if let a = byId[id], let s = surfaceById[id] {
                ordered.append((a, s))
                seen.insert(id)
            }
        }
        return Array(ordered.prefix(max(0, limit)))
    }

    /// Rank agents for roster/board: needs-you → working → finished → idle → unknown.
    ///
    /// Returns activity snapshots in glance order so both HUDs share one sort.
    /// Prefer `rankedAgentSurfaces` when the caller also needs the surface.
    public static func rankedAgents(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date(),
        limit: Int = 4
    ) -> [AgentActivitySnapshot] {
        rankedAgentSurfaces(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: usageByAgent,
            now: now,
            limit: limit
        ).map(\.agent)
    }

    // MARK: - Tool / completion classification (pure)

    public static func classifyTool(event: GateDBReader.ActivityEvent?) -> AgentToolKind {
        guard let event else { return .none }
        let t = event.type.lowercased()
        let blob = (event.label + " " + event.output + " " + t).lowercased()

        if t.contains("approval") { return .none }
        if t == "task_complete" || t == "completed" || t == "done" { return .none }

        // Prefer gate-stamped structured kind when present (ENH-017).
        if let structured = toolKindFromStructured(event.toolKind) {
            return structured
        }
        // event_type may itself be a known kind (edit, bash, …).
        if let fromType = toolKindFromStructured(t) {
            return fromType
        }

        if t.contains("tool") || t == "tool_call" || t == "tool_result" {
            return toolKindFromBlob(blob)
        }
        if t == "status" || t == "progress" || t == "message" {
            return toolKindFromBlob(blob)
        }
        return toolKindFromBlob(blob)
    }

    /// Map an explicit structured token to `AgentToolKind`, or nil if unknown.
    public static func toolKindFromStructured(_ raw: String?) -> AgentToolKind? {
        guard let raw else { return nil }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !v.isEmpty else { return nil }
        if let kind = AgentToolKind(rawValue: v), kind != .none {
            return kind
        }
        // Same aliases the gate normalizes (bash → shell).
        if v == "bash" || v == "terminal" {
            return .shell
        }
        return nil
    }

    public static func toolKindFromBlob(_ blob: String) -> AgentToolKind {
        let b = blob.lowercased()
        if b.isEmpty { return .none }
        // Read
        if b.contains("read") || b.contains("grep") || b.contains("glob")
            || b.contains("search") || b.contains("cat ") || b.contains("open file")
            || b.contains("list_dir") || b.contains("find ") {
            return .read
        }
        // Edit
        if b.contains("edit") || b.contains("write") || b.contains("apply_patch")
            || b.contains("strreplace") || b.contains("create file")
            || b.contains("updated ") || b.contains("(+") && b.contains("−") {
            return .edit
        }
        // Shell
        if b.contains("bash") || b.contains("shell") || b.contains("terminal")
            || b.contains("npm ") || b.contains("pnpm ") || b.contains("yarn ")
            || b.contains("cargo ") || b.contains("swift ") || b.contains("pytest")
            || b.contains("xcodebuild") || b.contains("git ") || b.contains("ran ")
            || b.contains("command") {
            // test runners
            if b.contains("test") || b.contains("pytest") || b.contains("jest")
                || b.contains("xcetest") || b.contains("passed") {
                return .test
            }
            return .shell
        }
        if b.contains("test") || b.contains("spec") || b.contains("assert") {
            return .test
        }
        if b.contains("http") || b.contains("fetch") || b.contains("browser")
            || b.contains("url") {
            return .browse
        }
        if b.contains("work") || b.contains("run") || b.contains("tool") {
            return .other
        }
        return .none
    }

    public static func isCompletion(event: GateDBReader.ActivityEvent?, now: Date) -> Bool {
        guard let event else { return false }
        guard now.timeIntervalSince(event.at) <= finishedFreshSeconds else { return false }
        let t = event.type.lowercased()
        let blob = (event.label + " " + event.output).lowercased()
        if t == "task_complete" || t == "completed" || t == "done" || t == "finish" {
            return true
        }
        if t == "approval_response" { return false }
        if blob.contains("ready for review") || blob.contains("all tests passed")
            || blob.contains("finished")
            || (blob.contains("complete") && !blob.contains("incomplete")) {
            return true
        }
        // "13 passed — ready for review" style
        if blob.contains("passed") && (blob.contains("ready") || blob.contains("review")) {
            return true
        }
        return false
    }

    /// Fail-closed: drop empty / all-nil usage.
    public static func usageIfReal(_ usage: AgentUsageSnapshot?) -> AgentUsageSnapshot? {
        guard let usage, usage.hasAny else { return nil }
        return usage
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

    private static func liveWorkLine(
        tool: AgentToolKind,
        event: GateDBReader.ActivityEvent?,
        lastTask: String,
        activityFresh: Bool
    ) -> String {
        if activityFresh, let event {
            let raw = AgentActivitySnapshot.shorten(event.line, max: 36)
            if tool != .none, !tool.verb.isEmpty {
                if raw.isEmpty { return tool.verb }
                // Labels often already carry a past-tense verb ("Edited store.ts").
                // Strip it so we never emit "Editing Edited store.ts".
                let target = stripLeadingToolVerb(raw)
                if target.isEmpty { return tool.verb }
                return "\(tool.verb) \(target)"
            }
            if !raw.isEmpty { return raw }
        }
        let task = AgentActivitySnapshot.shorten(lastTask, max: 42)
        if !task.isEmpty { return task }
        return tool != .none ? tool.verb : "working"
    }

    /// Drop a leading tool verb from an activity label so the live line can
    /// re-prefix with the present-tense `AgentToolKind.verb` once.
    static func stripLeadingToolVerb(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        // Longest-first so "editing " wins over "edit ".
        let prefixes = [
            "editing ", "edited ", "edit ",
            "reading ", "read ",
            "running ", "ran ", "run ",
            "testing ", "tested ", "test ",
            "browsing ", "browsed ", "browse ",
            "writing ", "wrote ", "write ",
            "working on ", "working ", "worked ",
            "applying ", "applied ",
            "creating ", "created ", "create ",
            "updating ", "updated ", "update ",
        ]
        for p in prefixes where lower.hasPrefix(p) {
            return String(trimmed.dropFirst(p.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
