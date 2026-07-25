import Foundation

// MARK: - Clean-room live agent surface (AgentNotch-class outcomes)

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

/// Optional usage metrics — only populated when a real local source provided them.
public struct AgentUsageSnapshot: Sendable, Equatable {
    public var tokensUsed: Int?
    public var tokensLimit: Int?
    public var contextPercent: Double?
    public var planLabel: String?

    public init(
        tokensUsed: Int? = nil,
        tokensLimit: Int? = nil,
        contextPercent: Double? = nil,
        planLabel: String? = nil
    ) {
        self.tokensUsed = tokensUsed.flatMap { $0 >= 0 ? $0 : nil }
        self.tokensLimit = tokensLimit.flatMap { $0 > 0 ? $0 : nil }
        self.contextPercent = contextPercent.flatMap {
            $0.isFinite ? min(100, max(0, $0)) : nil
        }
        let p = planLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.planLabel = (p?.isEmpty == false) ? p : nil
    }

    public var hasAny: Bool {
        tokensUsed != nil || tokensLimit != nil || contextPercent != nil || planLabel != nil
    }

    public var shortLabel: String? {
        if let pct = contextPercent {
            return String(format: "ctx %.0f%%", pct)
        }
        if let u = tokensUsed, let lim = tokensLimit, lim > 0 {
            return "\(u)/\(lim)"
        }
        if let u = tokensUsed {
            return "\(u) tok"
        }
        if let plan = planLabel {
            return plan
        }
        return nil
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
        let needs = pendingAsks.contains { $0.agentId == agent.id }
        let mine = activity.filter { $0.agentId == agent.id }
        let latest = mine.max(by: { $0.at < $1.at })
        let tool = classifyTool(event: latest)
        let finished = isCompletion(event: latest, now: now)
        let workingBusy = agent.status.isBusy && agent.presence.canBeBusy
        let taskFresh = !agent.lastTask.isEmpty
            && now.timeIntervalSince(agent.updatedAt) <= taskFreshSeconds
        let activityFresh = latest.map {
            now.timeIntervalSince($0.at) <= activityFreshSeconds
        } ?? false

        // ── Attention priority: needs you > working > finished > idle/unknown
        if needs {
            let prompt = pendingAsks.first(where: { $0.agentId == agent.id })?.prompt ?? ""
            let short = AgentActivitySnapshot.shorten(prompt, max: 40)
            return AgentLiveSurface(
                agentId: agent.id,
                displayName: name,
                attention: .needsYou,
                toolKind: .none,
                activityLine: short.isEmpty ? "Waiting for approval" : short,
                usage: usageIfReal(usage),
                needsYou: true,
                isFinished: false
            )
        }

        if workingBusy || (activityFresh && tool != .none && !finished) {
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

    /// Best single focus line for the collapsed island.
    public static func primaryFocus(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date()
    ) -> String? {
        let f = fleet(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: usageByAgent,
            now: now,
            limit: 1
        )
        guard let top = f.first else { return nil }
        if top.attention == .unknown, top.activityLine.isEmpty { return nil }
        return top.collapsedFocus
    }

    // MARK: - Tool / completion classification (pure)

    public static func classifyTool(event: GateDBReader.ActivityEvent?) -> AgentToolKind {
        guard let event else { return .none }
        let t = event.type.lowercased()
        let blob = (event.label + " " + event.output + " " + t).lowercased()

        if t.contains("approval") { return .none }
        if t == "task_complete" || t == "completed" || t == "done" { return .none }

        if t.contains("tool") || t == "tool_call" || t == "tool_result" {
            return toolKindFromBlob(blob)
        }
        if t == "status" || t == "progress" || t == "message" {
            return toolKindFromBlob(blob)
        }
        return toolKindFromBlob(blob)
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
            let target = AgentActivitySnapshot.shorten(event.line, max: 36)
            if tool != .none, !tool.verb.isEmpty {
                if target.isEmpty { return tool.verb }
                // "Editing store.ts" style
                return "\(tool.verb) \(target)"
            }
            if !target.isEmpty { return target }
        }
        let task = AgentActivitySnapshot.shorten(lastTask, max: 42)
        if !task.isEmpty { return task }
        return tool != .none ? tool.verb : "working"
    }
}
