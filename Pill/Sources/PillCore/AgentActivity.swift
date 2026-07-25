import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Snapshot models

/// How much we actually *know* about an agent, as opposed to what a file says.
///
/// The pill has two wildly different sources and used to treat them as equals:
///
///   * the hub gate DB — a process opened `/tmp/shannon.sock` and spoke. Real.
///   * `~/.shannon/pets/*/state.json` + `agents.json` — written by ⌘D from the
///     *frontmost macOS app*. "Working in Ghostty" is a statement about window
///     focus, not about an agent doing work, and nothing ever clears it.
///
/// Only `.live` may be reported as busy. Anything else renders honestly as
/// idle/offline with a "last seen" age.
public enum AgentPresence: String, Sendable, Equatable, CaseIterable {
    /// Gate telemetry, connection open, heard from inside the liveness window.
    case live
    /// Gate telemetry says the agent hung up, or the app behind an observed
    /// pet is no longer running. We know it is *not* working.
    case offline
    /// Foreground observation only. Fine as a label, never proof of work.
    case observed

    public var label: String {
        switch self {
        case .live: return "live"
        case .offline: return "offline"
        case .observed: return "seen"
        }
    }

    /// Only real telemetry is allowed to light the pill up.
    public var canBeBusy: Bool { self == .live }
}

public enum AgentRunStatus: String, Sendable, Equatable {
    case active
    case midTask = "mid_task"
    case idle
    case blocked
    case unknown

    public init(raw: String) {
        switch raw.lowercased() {
        case "active": self = .active
        case "mid_task", "mid-task", "running": self = .midTask
        case "idle": self = .idle
        case "blocked", "waiting", "error": self = .blocked
        default: self = .unknown
        }
    }

    public var isBusy: Bool {
        switch self {
        case .active, .midTask, .blocked: return true
        case .idle, .unknown: return false
        }
    }

    public var label: String {
        switch self {
        case .active: return "active"
        case .midTask: return "working"
        case .idle: return "idle"
        case .blocked: return "blocked"
        case .unknown: return "—"
        }
    }
}

/// One agent as currently known from disk (`~/.shannon/pets` + registry).
public struct AgentActivitySnapshot: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var status: AgentRunStatus
    public var lastTask: String
    public var source: String
    /// For gate agents this is `last_seen_ns` — when the agent last spoke.
    /// For observed pets it is when ⌘D captured the app.
    public var updatedAt: Date
    public var resumable: Bool
    public var historyCount: Int
    /// Quality of the evidence behind `status`. See `AgentPresence`.
    public var presence: AgentPresence
    /// When the gate last *proved* this agent's connection was open, if it
    /// could. `nil` means "no such evidence" (a pet/registry observation, or a
    /// hub DB written before `heartbeat_ns` existed) — not "stale".
    ///
    /// This is deliberately separate from `updatedAt`: an agent that is
    /// connected and silent must keep an honest "last seen 20m" while still
    /// being reported live.
    public var heartbeatAt: Date?

    public init(
        id: String,
        displayName: String,
        status: AgentRunStatus,
        lastTask: String,
        source: String,
        updatedAt: Date,
        resumable: Bool,
        historyCount: Int,
        presence: AgentPresence = .observed,
        heartbeatAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.lastTask = lastTask
        self.source = source
        self.updatedAt = updatedAt
        self.resumable = resumable
        self.historyCount = historyCount
        self.presence = presence
        self.heartbeatAt = heartbeatAt
    }

    /// Short line for the collapsed pill.
    public var collapsedLine: String {
        let task = Self.shorten(lastTask, max: 36)
        if task.isEmpty {
            return "\(displayName) · \(status.label)"
        }
        return "\(displayName) · \(task)"
    }

    /// Age of `updatedAt` **as of now**. Deliberately computed on every access
    /// rather than baked into a stored string at snapshot time: the view reads
    /// it while drawing, so a row whose data has not changed still ages
    /// correctly on screen — provided something re-renders it. That "something"
    /// is `AgentActivityMonitor.apply`, which republishes when this string
    /// would change. See `renderSignature(at:)`.
    public var relativeAge: String { Self.age(since: updatedAt) }

    public func relativeAge(at now: Date) -> String { Self.age(since: updatedAt, now: now) }

    public static func age(since date: Date, now: Date = Date()) -> String {
        guard date > .distantPast else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < 5 { return "now" }
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    /// Honest one-liner for a status column: never claims work we cannot prove.
    ///
    ///   live + working  → "working"
    ///   live + quiet    → "idle"
    ///   gate, hung up   → "offline · last seen 2d"
    ///   ⌘D observation  → "seen 13m ago"
    public var statusLine: String { statusLine(at: Date()) }

    public func statusLine(at now: Date) -> String {
        switch presence {
        case .live:
            return status.label
        case .offline:
            return "offline · last seen \(relativeAge(at: now))"
        case .observed:
            return "seen \(relativeAge(at: now)) ago"
        }
    }

    /// Everything a row renders that can change without the underlying data
    /// changing. Used to decide whether a re-render is actually needed.
    public func renderSignature(at now: Date) -> String {
        "\(id)|\(displayName)|\(lastTask)|\(statusLine(at: now))|\(relativeAge(at: now))"
    }

    public static func shorten(_ text: String, max: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop leaked secrets / env blobs from older bad captures.
        if Self.looksLikeSecretOrJunk(cleaned) { return "" }
        guard cleaned.count > max else { return cleaned }
        return String(cleaned.prefix(max - 1)) + "…"
    }

    public static func looksLikeSecretOrJunk(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = [
            "api_key", "apikey", "sk-ant-", "sk-proj-", "bearer ",
            "password=", "secret=", "begin private", "anthropic_api",
            "openai_api", "xai_api", "authorization:",
        ]
        if needles.contains(where: { lower.contains($0) }) { return true }
        if containsBareKeyToken(lower) { return true }
        // Long multi-token paste without agent: prefix → treat as junk for UI.
        if text.count > 140 && !lower.hasPrefix("agent:") { return true }
        return false
    }

    /// A bare `sk-` only means "API key" when it *starts a token* and is
    /// followed by a long opaque run.
    ///
    /// The old filter matched the substring anywhere, so every interaction id
    /// the gate generates — `ask-science-e2e-1784779386`, `approved: ask-hub-ui-…`
    /// — was classified as a leaked secret and silently blanked. The pill was
    /// therefore showing empty prompts and empty activity labels for the exact
    /// rows a human needed to read. "task-42" and "risk-free" hit it too.
    private static func containsBareKeyToken(_ lower: String) -> Bool {
        var searchFrom = lower.startIndex
        while let hit = lower.range(of: "sk-", range: searchFrom..<lower.endIndex) {
            let startsToken: Bool
            if hit.lowerBound == lower.startIndex {
                startsToken = true
            } else {
                let prev = lower[lower.index(before: hit.lowerBound)]
                startsToken = !(prev.isLetter || prev.isNumber)
            }
            if startsToken {
                let tail = lower[hit.upperBound...].prefix {
                    $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
                }
                if tail.count >= 16 { return true }
            }
            searchFrom = hit.upperBound
        }
        return false
    }
}

public struct AgentActivitySummary: Sendable, Equatable {
    public var agents: [AgentActivitySnapshot]
    public var scannedAt: Date

    public init(agents: [AgentActivitySnapshot] = [], scannedAt: Date = Date()) {
        self.agents = agents
        self.scannedAt = scannedAt
    }

    /// Agents we can *prove* are working: live gate telemetry only.
    ///
    /// The reader already refuses to mark anything else busy, so the extra
    /// `presence.canBeBusy` here is a belt-and-braces guard for snapshots built
    /// by hand (previews, tests, older call sites).
    public var busy: [AgentActivitySnapshot] {
        agents
            .filter { $0.status.isBusy && $0.presence.canBeBusy }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public var primary: AgentActivitySnapshot? {
        busy.first ?? agents.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    public var busyCount: Int { busy.count }

    /// What the agent board would draw right now, as one string.
    ///
    /// The rows themselves are static data; the *ages* in them are a function
    /// of wall-clock time. Comparing this — rather than the rows alone — is how
    /// the monitor knows a re-render is due even though nothing in the hub
    /// changed, which is what stops "last seen 7m" from sitting there while
    /// eleven minutes go by.
    public func renderSignature(at now: Date) -> String {
        agents.map { $0.renderSignature(at: now) }.joined(separator: "\n")
    }

    /// Agents currently connected to the hub, working or not.
    public var connected: [AgentActivitySnapshot] {
        agents.filter { $0.presence == .live }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public var collapsedText: String {
        let b = busy
        if b.isEmpty {
            if let recent = agents.sorted(by: { $0.updatedAt > $1.updatedAt }).first,
               Date().timeIntervalSince(recent.updatedAt) < 300,
               !recent.lastTask.isEmpty {
                return recent.collapsedLine
            }
            return "No active agents"
        }
        if b.count == 1 {
            return b[0].collapsedLine
        }
        // "Claude +2 · fixing CF floor"
        let head = b[0]
        let rest = b.count - 1
        let task = AgentActivitySnapshot.shorten(head.lastTask, max: 28)
        if task.isEmpty {
            return "\(head.displayName) +\(rest) active"
        }
        return "\(head.displayName) +\(rest) · \(task)"
    }
}

// MARK: - Disk reader (pure, testable)

public enum AgentActivityReader {
    /// Path to the hub SQLite DB written by `hub/shannon_gate.py` (Claude enhancements).
    public static var defaultGateDB: URL {
        PetBootstrap.shannonHome.appendingPathComponent("agent_hub.db")
    }

    /// How long a "working" claim survives silence. Matches the gate's own
    /// `IDLE_AFTER_S`, which demotes a quiet connected agent to `idle` in the
    /// DB — this is the local backstop for the window before that write lands.
    ///
    /// It used to be 45 minutes, which was moot (presence aged out at 5) and
    /// wrong on its own terms: nobody wants to read "working" about an agent
    /// that has been silent since lunch.
    public static let defaultStaleAfter: TimeInterval = 5 * 60

    /// Tolerance for the gate's proof-of-connection. The gate beats every 15 s
    /// (`HEARTBEAT_INTERVAL_S`), so this allows three misses.
    public static let defaultHeartbeatWindow: TimeInterval = 60

    /// Build the agent list the UI renders.
    ///
    /// Accuracy contract (this is the whole point of the type):
    ///
    ///  1. A pet / registry entry is a **foreground observation**. It supplies a
    ///     name, a source and a "last task" label — never a busy state. `⌘D` on
    ///     Ghostty wrote `status: "active"` and nothing ever wrote it back to
    ///     idle, which is why the pill used to insist three agents were working
    ///     when one of them was `com.apple.windowmanager`.
    ///  2. The **gate DB is authoritative** for any agent it knows. Its row wins
    ///     on status, presence, message count and `last_seen`, even when a pet
    ///     file is newer — a fresher lie is still a lie.
    ///  3. Busy decays. A live agent that has not been heard from in
    ///     `staleAfter` drops to idle; a disconnected one drops immediately.
    ///
    /// - Parameters:
    ///   - runningBundleIDs: bundle ids of currently running apps. When
    ///     supplied, an observed pet whose app has quit is reported `.offline`
    ///     instead of lingering as "seen". Pass `nil` to skip the check (tests).
    ///   - staleAfter: how long after `last_seen` a *busy* claim stops being
    ///     believed. Nothing has spoken for this long, so "working" is a guess.
    ///   - liveWindow: fallback only — how long after `last_seen` a connected
    ///     agent still counts as `.live` when the hub gives us no heartbeat.
    ///   - heartbeatWindow: how stale the gate's proof-of-connection may get
    ///     before the agent is reported offline. The gate stamps it every 15 s,
    ///     so this tolerates three missed beats.
    public static func load(
        petsRoot: URL = PetBootstrap.petsRoot,
        registryURL: URL = PetBootstrap.registryURL,
        gateDB: URL? = defaultGateDB,
        now: Date = Date(),
        staleAfter: TimeInterval = defaultStaleAfter,
        liveWindow: TimeInterval = 5 * 60,
        heartbeatWindow: TimeInterval = defaultHeartbeatWindow,
        runningBundleIDs: Set<String>? = nil,
        gateRows: [AgentActivitySnapshot]? = nil
    ) -> AgentActivitySummary {
        let fm = FileManager.default
        var byID: [String: AgentActivitySnapshot] = [:]
        var bundleByID: [String: String] = [:]
        // Bundle ids are case-insensitive as identity but *not* as strings:
        // NSWorkspace hands back `com.microsoft.VSCode` verbatim while the
        // registry stores what `AgentAppMapper.map` lowercased. Comparing them
        // raw made every mixed-case app look permanently quit, so anything
        // captured from VS Code, IntelliJ, iTerm2… was reported offline while
        // it was running. Fold both sides once, here.
        let runningLower = runningBundleIDs.map { Set($0.map { $0.lowercased() }) }

        // 1) Registry first (display names / sources from ⌘D).
        if let data = try? Data(contentsOf: registryURL),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in arr {
                guard let id = entry["id"] as? String, !id.isEmpty else { continue }
                let name = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
                let source = entry["source"] as? String ?? "other"
                let taskRaw = entry["last_task"] as? String ?? ""
                let task = AgentActivitySnapshot.looksLikeSecretOrJunk(taskRaw) ? "" : taskRaw
                let ts = entry["updated_at"] as? Double ?? 0
                let updated = ts > 0 ? Date(timeIntervalSince1970: ts) : .distantPast
                if let bundle = entry["bundle"] as? String, !bundle.isEmpty {
                    bundleByID[id] = bundle
                }
                byID[id] = AgentActivitySnapshot(
                    id: id,
                    displayName: name,
                    status: .idle,
                    lastTask: AgentActivitySnapshot.shorten(task, max: 120),
                    source: source,
                    updatedAt: updated,
                    resumable: false,
                    historyCount: 0,
                    presence: .observed
                )
            }
        }

        // 2) Pets override with live state.json (offline path).
        if let kids = try? fm.contentsOfDirectory(
            at: petsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in kids {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let id = dir.lastPathComponent
                let stateURL = dir.appendingPathComponent("state.json")
                guard let data = try? Data(contentsOf: stateURL),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let taskRaw = obj["last_task"] as? String ?? ""
                let task = AgentActivitySnapshot.looksLikeSecretOrJunk(taskRaw)
                    ? ""
                    : AgentActivitySnapshot.shorten(taskRaw, max: 120)
                let ts = obj["updated_at"] as? Double ?? 0
                let updated = ts > 0 ? Date(timeIntervalSince1970: ts) : .distantPast
                let resumable = obj["resumable"] as? Bool ?? false
                let hist = obj["history_count"] as? Int ?? 0

                let existing = byID[id]
                let display = existing?.displayName
                    ?? displayName(for: id, config: dir.appendingPathComponent("config.json"))
                let source = existing?.source ?? guessSource(id)

                // `state.json` "status" is written by ⌘D as `hasTask ? active : idle`
                // (AgentIngest.bootstrapPet) and is never written back — it says
                // nothing about whether an agent is running. Treat it as a label
                // only: presence `.observed`, status `.idle`. If we can see the
                // app it was captured from is gone, say so outright.
                var presence: AgentPresence = .observed
                if let runningLower,
                   let bundle = bundleByID[id],
                   !runningLower.contains(bundle.lowercased()) {
                    presence = .offline
                }

                byID[id] = AgentActivitySnapshot(
                    id: id,
                    displayName: display,
                    status: .idle,
                    lastTask: task.isEmpty ? (existing?.lastTask ?? "") : task,
                    source: source,
                    updatedAt: updated,
                    resumable: resumable,
                    historyCount: hist,
                    presence: presence
                )
            }
        }

        // 3) Hub gate DB — the only real telemetry. Authoritative for every
        //    agent it knows about, regardless of how fresh the pet file looks.
        let rows = gateRows ?? gateDB.map { loadGateAgents(dbURL: $0) }
        if let rows {
            for row in rows {
                let existing = byID[row.id]
                byID[row.id] = reconcile(
                    gate: row,
                    with: existing,
                    now: now,
                    staleAfter: staleAfter,
                    liveWindow: liveWindow,
                    heartbeatWindow: heartbeatWindow,
                    fallbackName: {
                        displayName(
                            for: row.id,
                            config: petsRoot.appendingPathComponent(row.id)
                                .appendingPathComponent("config.json")
                        )
                    },
                    fallbackSource: { guessSource(row.id) }
                )
            }
        }

        return AgentActivitySummary(agents: sortForDisplay(byID.values), scannedAt: now)
    }

    /// Gate row + optional local knowledge → one truthful snapshot.
    ///
    /// The gate wins on everything it can prove (status, presence, last seen,
    /// message count); the local entry only fills gaps (display name, source,
    /// a task label when the gate has none).
    private static func reconcile(
        gate row: AgentActivitySnapshot,
        with existing: AgentActivitySnapshot?,
        now: Date,
        staleAfter: TimeInterval,
        liveWindow: TimeInterval,
        heartbeatWindow: TimeInterval,
        fallbackName: () -> String,
        fallbackSource: () -> String
    ) -> AgentActivitySnapshot {
        let age = now.timeIntervalSince(row.updatedAt)
        // `.observed` from the gate means a legacy schema with no
        // `disconnected_at` — unproven, so it may not be reported busy either.
        var presence = row.presence
        if presence == .live {
            if let beat = row.heartbeatAt {
                // The gate stamps this while the connection is open, so silence
                // is not evidence of death: an agent that has said nothing for
                // an hour is still live if the hub saw it 5 s ago. Only a stale
                // beat — hub killed, machine slept — means offline.
                if now.timeIntervalSince(beat) > heartbeatWindow { presence = .offline }
            } else if age > liveWindow {
                // No heartbeat evidence at all (pre-migration hub DB): the best
                // available signal is still the age of the last message.
                presence = .offline
            }
        }

        var status = row.status
        if status.isBusy, presence != .live || age > staleAfter { status = .idle }

        return AgentActivitySnapshot(
            id: row.id,
            displayName: existing?.displayName ?? fallbackName(),
            status: status,
            lastTask: row.lastTask.isEmpty ? (existing?.lastTask ?? "") : row.lastTask,
            source: existing?.source ?? fallbackSource(),
            updatedAt: row.updatedAt,
            resumable: status.isBusy || (existing?.resumable ?? false),
            historyCount: max(existing?.historyCount ?? 0, row.historyCount),
            presence: presence,
            heartbeatAt: row.heartbeatAt
        )
    }

    /// Busy first, then live-but-quiet, then most recently seen.
    private static func sortForDisplay(
        _ values: some Collection<AgentActivitySnapshot>
    ) -> [AgentActivitySnapshot] {
        values.sorted { lhs, rhs in
            let lb = lhs.status.isBusy && lhs.presence.canBeBusy
            let rb = rhs.status.isBusy && rhs.presence.canBeBusy
            if lb != rb { return lb }
            let ll = lhs.presence == .live
            let rl = rhs.presence == .live
            if ll != rl { return ll }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Merge pure helper for tests: pets/registry map + gate rows → summary.
    ///
    /// Everything in `gate` is treated as hub telemetry (that is what the
    /// parameter means), so a row that does not carry an explicit `.offline`
    /// presence is taken as connected and then aged normally. `base` entries are
    /// local observations and can never come out busy.
    public static func merge(
        base: [AgentActivitySnapshot],
        gate: [AgentActivitySnapshot],
        now: Date = Date(),
        staleAfter: TimeInterval = defaultStaleAfter,
        liveWindow: TimeInterval = 5 * 60,
        heartbeatWindow: TimeInterval = defaultHeartbeatWindow
    ) -> AgentActivitySummary {
        var byID: [String: AgentActivitySnapshot] = [:]
        for a in base {
            var local = a
            if local.presence == .live { local.presence = .observed }
            if local.status.isBusy { local.status = .idle }
            byID[local.id] = local
        }
        for row in gate {
            var telemetry = row
            if telemetry.presence == .observed { telemetry.presence = .live }
            let existing = byID[row.id]
            byID[row.id] = reconcile(
                gate: telemetry,
                with: existing,
                now: now,
                staleAfter: staleAfter,
                liveWindow: liveWindow,
                heartbeatWindow: heartbeatWindow,
                fallbackName: { row.displayName },
                fallbackSource: { row.source }
            )
        }
        return AgentActivitySummary(agents: sortForDisplay(byID.values), scannedAt: now)
    }

    /// Read `agents` table from hub SQLite (best-effort; empty if missing/locked).
    public static func loadGateAgents(dbURL: URL) -> [AgentActivitySnapshot] {
        GateDBReader.readAgents(path: dbURL.path)
    }

    /// Everything one poll needs, with the hub DB opened exactly once.
    public struct FullSnapshot: Sendable, Equatable {
        public var summary: AgentActivitySummary
        public var pendingAsks: [GateDBReader.PendingAsk]
        public var staleAsks: [GateDBReader.PendingAsk]
        public var activity: [GateDBReader.ActivityEvent]
        /// The hub DB opened. False means "no telemetry at all", which the UI
        /// should say out loud rather than implying everything is merely quiet.
        public var gateDBAvailable: Bool
        /// Gate-measured entropy per scored agent. Feeds
        /// `EntropyProvenance.resolve` so the pill can show a *real* H when no
        /// detector socket is attached, instead of a fabricated one.
        public var agentEntropy: [EntropyMeasurement]

        public init(
            summary: AgentActivitySummary = AgentActivitySummary(),
            pendingAsks: [GateDBReader.PendingAsk] = [],
            staleAsks: [GateDBReader.PendingAsk] = [],
            activity: [GateDBReader.ActivityEvent] = [],
            gateDBAvailable: Bool = false,
            agentEntropy: [EntropyMeasurement] = []
        ) {
            self.summary = summary
            self.pendingAsks = pendingAsks
            self.staleAsks = staleAsks
            self.activity = activity
            self.gateDBAvailable = gateDBAvailable
            self.agentEntropy = agentEntropy
        }

        /// Everything on screen whose text depends on the clock: agent rows,
        /// "waiting 3m" on an open approval, "5m ago" in the activity feed.
        /// The monitor republishes exactly when this changes.
        public func renderSignature(at now: Date) -> String {
            var parts = [summary.renderSignature(at: now)]
            parts += pendingAsks.map { "\($0.interactionId)|\($0.waitingFor(at: now))" }
            parts += activity.map { "\($0.id)|\($0.relativeAge(at: now))" }
            return parts.joined(separator: "\n")
        }
    }

    public static func loadFull(
        petsRoot: URL = PetBootstrap.petsRoot,
        registryURL: URL = PetBootstrap.registryURL,
        gateDB: URL? = defaultGateDB,
        now: Date = Date(),
        staleAfter: TimeInterval = defaultStaleAfter,
        liveWindow: TimeInterval = 5 * 60,
        heartbeatWindow: TimeInterval = defaultHeartbeatWindow,
        runningBundleIDs: Set<String>? = nil
    ) -> FullSnapshot {
        let gate = gateDB.map { GateDBReader.readSnapshot(path: $0.path, now: now) }
        let summary = load(
            petsRoot: petsRoot,
            registryURL: registryURL,
            gateDB: gateDB,
            now: now,
            staleAfter: staleAfter,
            liveWindow: liveWindow,
            heartbeatWindow: heartbeatWindow,
            runningBundleIDs: runningBundleIDs,
            gateRows: gate?.agents
        )
        return FullSnapshot(
            summary: summary,
            pendingAsks: gate?.pendingAsks ?? [],
            staleAsks: gate?.staleAsks ?? [],
            activity: gate?.activity ?? [],
            gateDBAvailable: gate?.available ?? false,
            agentEntropy: gate?.agentEntropy ?? []
        )
    }

    private static func displayName(for id: String, config: URL) -> String {
        if let data = try? Data(contentsOf: config),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = obj["display_name"] as? String, !name.isEmpty {
            return name
        }
        return AgentStyleCatalog.style(for: id).displayName
    }

    private static func guessSource(_ id: String) -> String {
        switch id {
        case "terminal": return "terminal"
        case "browser": return "browser"
        case "cursor", "vscode": return "ide"
        case "claude_code", "chatgpt", "codex", "grok_build", "science": return "chat"
        default: return "other"
        }
    }
}

// MARK: - Live publisher

/// Polls pet/registry state for the notch pill. Pure disk I/O — no network.
@MainActor
public final class AgentActivityMonitor: ObservableObject {
    @Published public private(set) var summary = AgentActivitySummary()
    /// Open human approvals the gate is blocked on.
    /// Source: agent_interactions rows with status = 'pending'.
    /// Only asks a human can still act on — see `GateDBReader.PendingAsk`.
    @Published public private(set) var pendingAsks: [GateDBReader.PendingAsk] = []

    /// Rows still marked `pending` whose asking agent has since disconnected, or
    /// that aged past the backstop. Surfaced separately so the menu bar stops
    /// pulsing amber for an approval nobody is waiting on, while the popover can
    /// still show "2 abandoned approvals" if it wants to.
    @Published public private(set) var staleAsks: [GateDBReader.PendingAsk] = []

    /// Real `agent_activity` rows from the hub, newest first — what agents
    /// actually did, as opposed to the agent list re-labelled as events.
    @Published public private(set) var recentActivity: [GateDBReader.ActivityEvent] = []

    /// Whether the gate's Unix socket is present. Drives the pill's graceful
    /// "hub offline" state instead of letting approvals fail invisibly.
    @Published public private(set) var gateAvailable = false

    /// Whether `~/.shannon/agent_hub.db` could be read at all. When false the
    /// pill has *no* telemetry and everything it lists is a local observation.
    @Published public private(set) var gateDBAvailable = false

    /// Gate-measured entropy per scored agent, newest-usable first.
    ///
    /// Empty means nothing has been measured — never "measured as zero". Feed
    /// this to `EntropyProvenance.resolve` rather than reading `.first?.bits`
    /// directly; the resolver is what decides whether a value is current.
    @Published public private(set) var agentEntropy: [EntropyMeasurement] = []

    /// Interaction ids whose approval is currently being written to the gate.
    /// The banner shows a spinner for these instead of tappable buttons, so a
    /// second tap can't fire a duplicate resolution.
    @Published public private(set) var resolving: Set<String> = []

    /// Last approval failure, surfaced inline in the banner. Cleared on the next
    /// successful resolve or when the offending ask disappears.
    @Published public private(set) var lastResolveError: String?

    /// Suspends polling. Real state: while true, `refresh` does no disk or
    /// SQLite work at all, so "Pause monitoring" in the pill's context menu
    /// genuinely stops this app reading. It does not pause the agents — the gate
    /// exposes no such control.
    @Published public var isPaused = false {
        didSet { if !isPaused { refresh() } }
    }

    private var timer: Timer?
    private let interval: TimeInterval
    /// One poll in flight at a time — a slow disk must not queue up work.
    private var refreshing = false
    /// Running-app bundle ids, refreshed lazily: NSWorkspace enumeration is far
    /// more expensive than the file reads and rarely changes between polls.
    private var runningBundleIDs: Set<String> = []
    private var runningBundleIDsAt: Date = .distantPast
    private let runningBundleTTL: TimeInterval = 5

    public init(interval: TimeInterval = 1.5) {
        self.interval = interval
    }

    public func start() {
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = interval * 0.25   // let the run loop coalesce fires
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Path to the gate socket. Injectable for tests; defaults to the live gate.
    public var gateSocketPath: String = GateApprovalClient.defaultSocketPath

    /// Rendered form of the last published snapshot, so `apply` can tell "the
    /// screen is still correct" from "the data is unchanged but the clock has
    /// moved on". Ages are drawn from `Date()` at render time, so the latter
    /// still needs a publish or the row silently freezes.
    private var lastRenderSignature = ""

    /// Poll disk + hub DB off the main thread and publish only what changed.
    ///
    /// Previously this ran a pets directory scan, a dozen JSON parses and three
    /// separate SQLite opens *synchronously on the main thread* every 1.5 s, and
    /// reassigned every `@Published` property whether or not the value differed
    /// — so SwiftUI re-rendered the pill 40 times a minute over identical data.
    /// Now: one DB open, background thread, and assignments guarded by equality.
    public func refresh() {
        guard !isPaused, !refreshing else { return }
        refreshing = true

        let socket = gateSocketPath
        let bundles = currentRunningBundleIDs()
        Task.detached(priority: .utility) {
            let full = AgentActivityReader.loadFull(runningBundleIDs: bundles)
            let socketUp = FileManager.default.fileExists(atPath: socket)
            await MainActor.run { [weak self] in
                self?.apply(full, socketUp: socketUp)
            }
        }
    }

    private func apply(_ full: AgentActivityReader.FullSnapshot, socketUp: Bool) {
        refreshing = false
        // Two reasons to republish: the data changed, or enough time passed
        // that a rendered age changed ("6m" → "7m"). Comparing whole summaries
        // would technically catch both — `scannedAt` differs on every poll —
        // but only by never skipping anything, which is how the pill ended up
        // re-rendering 40×/min over identical data. Comparing the *rendered*
        // form skips the no-op polls and still keeps the clock running.
        //
        // Publishing `summary` is what re-renders the views, so the signature
        // deliberately covers the ask and activity ages too: they live on the
        // same object and would otherwise freeze whenever the agent rows
        // happened to be quiet.
        let signature = full.renderSignature(at: full.summary.scannedAt)
        if summary.agents != full.summary.agents || signature != lastRenderSignature {
            summary = full.summary
            lastRenderSignature = signature
        }
        if pendingAsks != full.pendingAsks { pendingAsks = full.pendingAsks }
        if staleAsks != full.staleAsks { staleAsks = full.staleAsks }
        if recentActivity != full.activity { recentActivity = full.activity }
        if gateDBAvailable != full.gateDBAvailable { gateDBAvailable = full.gateDBAvailable }
        if gateAvailable != socketUp { gateAvailable = socketUp }
        if agentEntropy != full.agentEntropy { agentEntropy = full.agentEntropy }
        // Drop stale in-flight state for asks the gate has since cleared.
        let live = Set(full.pendingAsks.map(\.interactionId))
        if !resolving.isSubset(of: live) { resolving.formIntersection(live) }
    }

    private func currentRunningBundleIDs() -> Set<String> {
        #if canImport(AppKit)
        let now = Date()
        if now.timeIntervalSince(runningBundleIDsAt) > runningBundleTTL {
            runningBundleIDs = Set(
                NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            )
            runningBundleIDsAt = now
        }
        return runningBundleIDs
        #else
        return []
        #endif
    }

    /// Drop a resolved ask immediately so the pill stops pulsing before the next
    /// poll observes the gate's own update.
    public func clearAsk(_ interactionId: String) {
        pendingAsks.removeAll { $0.interactionId == interactionId }
        resolving.remove(interactionId)
    }

    /// The whole approve/deny flow, owned in one place so the view never blocks.
    ///
    /// Runs the socket write off the main thread, and — crucially — always
    /// reaches a terminal state the UI can see: on success the ask is cleared;
    /// on any failure the ask stays put and `lastResolveError` is populated, so
    /// the pill shows an actionable error instead of freezing on a dead socket.
    public func resolve(_ ask: GateDBReader.PendingAsk, approved: Bool) async {
        let iid = ask.interactionId
        guard !resolving.contains(iid) else { return }
        resolving.insert(iid)
        lastResolveError = nil
        defer { resolving.remove(iid) }

        do {
            try await GateApprovalClient.resolveAsync(
                interactionId: iid,
                agentId: ask.agentId,
                approved: approved,
                socketPath: gateSocketPath
            )
            clearAsk(iid)
        } catch {
            lastResolveError = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? GateApprovalClient.ApprovalError else {
            return "Couldn't reach the gate — \(error.localizedDescription)"
        }
        switch e {
        case .socketUnavailable: return "Hub offline — start the gate, then retry"
        case .connectFailed:     return "Gate refused the connection — retry"
        case .writeFailed:       return "Write to gate failed — retry"
        case .timedOut:          return "Gate not responding — retry"
        }
    }
}
