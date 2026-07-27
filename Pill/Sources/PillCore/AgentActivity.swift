import Foundation
import ShannonCore
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Snapshot models

/// How much we actually *know* about an agent, as opposed to what a file says.
///
/// Two independent paths can make an agent **live**:
///
///   * **Gate socket** — a process opened `/tmp/shannon.sock` and spoke.
///   * **Process attach** — ⌘D stored an `attach_pid` / `attach_bundle` and
///     that process/app is still running right now (re-checked every poll).
///
/// Only `.live` may be reported busy, and process-attach never invents busy
/// work on its own (status stays `.idle` until the gate reports activity).
/// Dead process / hung-up gate → `.offline`. Capture without process evidence
/// (legacy pets) stays `.observed` ("seen").
public enum AgentPresence: String, Sendable, Equatable, CaseIterable {
    /// Attached and proven present: open gate socket **or** still-running
    /// process from ⌘D attach.
    case live
    /// Gate hung up, or the attached process/app is no longer running.
    case offline
    /// Foreground observation only — no process evidence to re-check.
    case observed

    public var label: String {
        switch self {
        case .live: return "live"
        case .offline: return "offline"
        case .observed: return "seen"
        }
    }

    /// Live agents may be busy (gate activity). Process-attach live stays idle
    /// until the gate says otherwise.
    public var canBeBusy: Bool { self == .live }
}

// MARK: - Process attach (⌘D → live)

/// Re-check whether a ⌘D-attached process/app is still around.
///
/// When evidence says yes → **`.live`** (attached). When evidence says no →
/// **`.offline`**. When there is no evidence at all → **`.observed`** (legacy
/// "seen" capture). Pure and injectable for tests.
public enum ProcessAttach: Sendable {
    /// Signal 0 existence probe. `EPERM` still means the process exists
    /// (we just cannot signal it).
    public static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        #if canImport(Darwin)
        let rc = kill(pid, 0)
        if rc == 0 { return true }
        return errno == EPERM
        #else
        return false
        #endif
    }

    /// Presence for a ⌘D attachment given optional process evidence.
    ///
    /// - Parameters:
    ///   - attachPid: stored pid from capture (0 / nil = unknown).
    ///   - attachBundle: host app bundle id.
    ///   - runningBundleIDs: lowercased set of currently running apps, or nil
    ///     to skip the bundle check.
    ///   - pidAlive: injectable pid check (tests).
    /// - Returns:
    ///   - `.live` when pid is alive **or** (pid dead/unknown but host bundle still running)
    ///   - `.offline` when evidence proves both process and host app are gone
    ///   - `.observed` when we have no process evidence to re-check
    ///
    /// Electron/IDE hosts restart often (new PID, same bundle). Treating a dead
    /// attach PID as hard offline while Cursor/Ghostty is still open made ⌘D
    /// agents flap offline→live and thrash the menu bar every full scan.
    public static func presence(
        attachPid: Int32?,
        attachBundle: String?,
        runningBundleIDs: Set<String>?,
        pidAlive: (Int32) -> Bool = ProcessAttach.isProcessAlive
    ) -> AgentPresence {
        let pidLive: Bool? = {
            guard let pid = attachPid, pid > 0 else { return nil }
            return pidAlive(pid)
        }()
        if pidLive == true { return .live }

        let bundle = attachBundle?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBundle = !(bundle ?? "").isEmpty
        if let running = runningBundleIDs, let bundle, hasBundle {
            if running.contains(bundle) { return .live }
            // Host quit (and pid dead or unknown) → offline.
            return .offline
        }
        // Pid was known and is dead, but we cannot re-check the host bundle
        // (nil running set) — fail closed only when we *know* the process died
        // and have no bundle to fall back on.
        if pidLive == false, !hasBundle { return .offline }
        if pidLive == false, runningBundleIDs == nil {
            // Bundle known but no running set this tick: keep observed so we
            // do not thrash offline until the next NSWorkspace sample.
            return hasBundle ? .observed : .offline
        }
        // No process evidence — cannot claim live or offline.
        return .observed
    }
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
    /// ⌘D process evidence — carried so gate-only polls can re-check liveness
    /// without a full pets disk walk (keeps attach sticky between full scans).
    public var attachPid: Int32?
    public var attachBundle: String?

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
        heartbeatAt: Date? = nil,
        attachPid: Int32? = nil,
        attachBundle: String? = nil
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
        self.attachPid = attachPid
        self.attachBundle = attachBundle
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
        // UX-011: single source with widget / companions (`SharedRelativeAge.fine`).
        SharedRelativeAge.fine(since: date, now: now)
    }

    /// Coarse age for **publish gating only** — not drawn in the UI.
    ///
    /// Fine ages (`"12s"` → `"13s"`) thrash the monitor every poll while an
    /// ask is open or an agent was just seen, which re-laid-out the notch
    /// pill and menu-bar popover and looked like a pop in/out. Buckets keep
    /// ages eventually live (resource ticks + other data still re-render)
    /// without forcing a structural invalidation every second.
    ///
    /// **UX-011:** delegates to `SharedRelativeAge.bucketed` so Mac cannot drift
    /// from the widget glance buckets (UX-008).
    public static func signatureAge(since date: Date, now: Date = Date()) -> String {
        SharedRelativeAge.bucketed(since: date, now: now)
    }

    /// Honest one-liner for a status column: never claims work we cannot prove.
    ///
    ///   live + working  → "working" / "active" / …
    ///   live + quiet    → "live" (attached; process or socket, not inventing work)
    ///   offline         → "offline · last seen 2d"
    ///   observed only   → "seen 13m ago" (no process evidence)
    public var statusLine: String { statusLine(at: Date()) }

    public func statusLine(at now: Date) -> String {
        switch presence {
        case .live:
            // Quiet attach: say "live", not "idle" — idle looked like "not
            // attached" after ⌘D. Busy gate statuses keep their real labels.
            return status.isBusy ? status.label : "live"
        case .offline:
            return "offline · last seen \(relativeAge(at: now))"
        case .observed:
            return "seen \(relativeAge(at: now)) ago"
        }
    }

    /// Status line using coarse ages — for publish signatures only.
    public func signatureStatusLine(at now: Date) -> String {
        switch presence {
        case .live:
            return status.isBusy ? status.label : "live"
        case .offline:
            return "offline · last seen \(Self.signatureAge(since: updatedAt, now: now))"
        case .observed:
            return "seen \(Self.signatureAge(since: updatedAt, now: now)) ago"
        }
    }

    /// Everything a row renders that can change without the underlying data
    /// changing. Used to decide whether a re-render is actually needed.
    /// Ages use `signatureAge` so sub-minute second ticks do not thrash UI.
    public func renderSignature(at now: Date) -> String {
        "\(id)|\(displayName)|\(lastTask)|\(signatureStatusLine(at: now))|\(Self.signatureAge(since: updatedAt, now: now))"
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
        gateRows: [AgentActivitySnapshot]? = nil,
        /// When true, skip pets directory + registry disk scan. Seed from
        /// `previousAgents` (if any) so process-attach liveness from the last
        /// full scan is preserved while the gate path still refreshes every tick.
        skipPetsScan: Bool = false,
        previousAgents: [AgentActivitySnapshot]? = nil
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

        if skipPetsScan {
            // Gate-only path: seed from last full scan, but re-check process
            // attach every tick so dead apps drop and host restarts stay live
            // without waiting for the pets interval (avoids thrash lag).
            // When no running-bundle sample is available this tick, keep prior
            // presence — demoting to `.observed` would thrash the menu bar.
            if let previousAgents {
                for var a in previousAgents {
                    if let runningLower,
                       a.attachPid != nil || a.attachBundle != nil {
                        let p = ProcessAttach.presence(
                            attachPid: a.attachPid,
                            attachBundle: a.attachBundle,
                            runningBundleIDs: runningLower
                        )
                        a.presence = p
                        if p == .live { a.updatedAt = now }
                        if p != .live { a.status = .idle }
                    }
                    byID[a.id] = a
                }
            }
        } else {
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
                    let bundle = (entry["bundle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    if let bundle { bundleByID[id] = bundle }
                    let presence = ProcessAttach.presence(
                        attachPid: nil,
                        attachBundle: bundle,
                        runningBundleIDs: runningLower
                    )
                    byID[id] = AgentActivitySnapshot(
                        id: id,
                        displayName: name,
                        status: .idle,
                        lastTask: AgentActivitySnapshot.shorten(task, max: 120),
                        source: source,
                        // Live process-attach is current; refresh the clock so ages
                        // do not freeze at the original ⌘D timestamp.
                        updatedAt: presence == .live ? now : updated,
                        resumable: false,
                        historyCount: 0,
                        presence: presence,
                        attachPid: nil,
                        attachBundle: bundle
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

                    // Process-attach re-check: attach_pid (terminal CLI / host app)
                    // wins, then attach_bundle / registry bundle. Alive → **live**;
                    // dead → offline. Status stays idle (no invented busy work).
                    let statePid = (obj["attach_pid"] as? Int).map { Int32($0) }
                        ?? (obj["attach_pid"] as? Int32)
                    let stateBundle = (obj["attach_bundle"] as? String)
                        .flatMap { $0.isEmpty ? nil : $0 }
                        ?? bundleByID[id]
                    if let b = stateBundle { bundleByID[id] = b }

                    let presence = ProcessAttach.presence(
                        attachPid: statePid,
                        attachBundle: stateBundle,
                        runningBundleIDs: runningLower
                    )
                    let trackingUpdated: Date = presence == .live ? now : updated

                    byID[id] = AgentActivitySnapshot(
                        id: id,
                        displayName: display,
                        status: .idle,
                        lastTask: task.isEmpty ? (existing?.lastTask ?? "") : task,
                        source: source,
                        updatedAt: trackingUpdated,
                        resumable: resumable,
                        historyCount: hist,
                        presence: presence,
                        attachPid: (statePid ?? 0) > 0 ? statePid : nil,
                        attachBundle: stateBundle
                    )
                }
            }
        }

        // 3) Hub gate DB — authoritative for busy/status when the socket is
        //    live. Process-attach liveness is preserved when the gate row is
        //    offline (socket hung up but Cursor is still open).
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

    /// Gate row + optional local process-attach knowledge → one truthful snapshot.
    ///
    /// - Gate **live** (fresh heartbeat) wins for presence, busy status, task.
    /// - Gate **offline** / stale does **not** demote a process-attach that is
    ///   still live (⌘D + Cursor still open after the socket closed).
    /// - Process-attach never supplies busy on its own — status stays idle
    ///   unless the gate itself is live and busy.
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
        var gateStillLive = false
        if presence == .live {
            if let beat = row.heartbeatAt {
                // The gate stamps this while the connection is open, so silence
                // is not evidence of death: an agent that has said nothing for
                // an hour is still live if the hub saw it 5 s ago. Only a stale
                // beat — hub killed, machine slept — means offline.
                if now.timeIntervalSince(beat) > heartbeatWindow {
                    presence = .offline
                } else {
                    gateStillLive = true
                }
            } else if age > liveWindow {
                // No heartbeat evidence at all (pre-migration hub DB): the best
                // available signal is still the age of the last message.
                presence = .offline
            } else {
                gateStillLive = true
            }
        }

        // Process-attach outranks a hung-up gate socket — only when we have
        // attach_pid / attach_bundle evidence. Pure socket agents must demote
        // to offline when the gate hangs up (no ghost-live after disconnect).
        let attachPid = existing?.attachPid ?? row.attachPid
        let attachBundle = existing?.attachBundle ?? row.attachBundle
        let hasAttachEvidence =
            (attachPid ?? 0) > 0 || !(attachBundle ?? "").isEmpty
        if !gateStillLive, hasAttachEvidence,
           let existing, existing.presence == .live {
            // runningBundleIDs not available inside reconcile; load() re-checks
            // pid/bundle before calling us. Keep prior live attach until then.
            presence = .live
        }

        var status = row.status
        if !gateStillLive {
            // Only a live gate may claim busy; process-attach is quiet-live.
            status = .idle
        } else if status.isBusy, age > staleAfter {
            status = .idle
        }

        let updatedAt: Date = {
            if gateStillLive { return row.updatedAt }
            if presence == .live { return existing?.updatedAt ?? now }
            return row.updatedAt
        }()

        return AgentActivitySnapshot(
            id: row.id,
            displayName: existing?.displayName ?? fallbackName(),
            status: status,
            lastTask: row.lastTask.isEmpty ? (existing?.lastTask ?? "") : row.lastTask,
            source: existing?.source ?? fallbackSource(),
            updatedAt: updatedAt,
            resumable: status.isBusy || (existing?.resumable ?? false),
            historyCount: max(existing?.historyCount ?? 0, row.historyCount),
            presence: presence,
            heartbeatAt: gateStillLive ? row.heartbeatAt : existing?.heartbeatAt,
            attachPid: attachPid,
            attachBundle: attachBundle
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
        /// FlexAIDdS / DatasetRunner progress from gate `benchmark_state`.
        public var benchmark: BenchmarkRunSnapshot?

        public init(
            summary: AgentActivitySummary = AgentActivitySummary(),
            pendingAsks: [GateDBReader.PendingAsk] = [],
            staleAsks: [GateDBReader.PendingAsk] = [],
            activity: [GateDBReader.ActivityEvent] = [],
            gateDBAvailable: Bool = false,
            agentEntropy: [EntropyMeasurement] = [],
            benchmark: BenchmarkRunSnapshot? = nil
        ) {
            self.summary = summary
            self.pendingAsks = pendingAsks
            self.staleAsks = staleAsks
            self.activity = activity
            self.gateDBAvailable = gateDBAvailable
            self.agentEntropy = agentEntropy
            self.benchmark = benchmark
        }

        /// Everything on screen whose text depends on the clock: agent rows,
        /// "waiting 3m" on an open approval, "5m ago" in the activity feed.
        /// The monitor republishes exactly when this changes.
        ///
        /// Sub-minute ages use `signatureAge` (15 s buckets) so a pending ask
        /// does not force pill/popover layout every poll ("pop" on refresh).
        public func renderSignature(at now: Date) -> String {
            var parts = [summary.renderSignature(at: now)]
            parts += pendingAsks.map {
                "\($0.interactionId)|\(AgentActivitySnapshot.signatureAge(since: $0.createdAt, now: now))"
            }
            parts += activity.map {
                "\($0.id)|\(AgentActivitySnapshot.signatureAge(since: $0.at, now: now))"
            }
            if let b = benchmark {
                parts.append("bench|\(b.taskId)|\(b.completed)/\(b.total)|\(b.activeTarget ?? "")")
            }
            return parts.joined(separator: "\n")
        }
    }

    /// - Parameter skipPetsScan: When true, do not walk `~/.shannon/pets` or
    ///   the registry — only open the gate DB (asks / entropy / agents). Seed
    ///   from `previousAgents` so process-attach rows from the last full scan
    ///   survive. The monitor uses this every 1.5 s tick; full pets+registry
    ///   scans run on a longer interval (see `fullScanInterval`).
    public static func loadFull(
        petsRoot: URL = PetBootstrap.petsRoot,
        registryURL: URL = PetBootstrap.registryURL,
        gateDB: URL? = defaultGateDB,
        now: Date = Date(),
        staleAfter: TimeInterval = defaultStaleAfter,
        liveWindow: TimeInterval = 5 * 60,
        heartbeatWindow: TimeInterval = defaultHeartbeatWindow,
        runningBundleIDs: Set<String>? = nil,
        skipPetsScan: Bool = false,
        previousAgents: [AgentActivitySnapshot]? = nil
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
            gateRows: gate?.agents,
            skipPetsScan: skipPetsScan,
            previousAgents: previousAgents
        )
        return FullSnapshot(
            summary: summary,
            pendingAsks: gate?.pendingAsks ?? [],
            staleAsks: gate?.staleAsks ?? [],
            activity: gate?.activity ?? [],
            gateDBAvailable: gate?.available ?? false,
            agentEntropy: gate?.agentEntropy ?? [],
            benchmark: gate?.benchmark
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
        case "cursor", "vscode", "xcode": return "ide"
        case "claude_code", "chatgpt", "codex", "grok_build", "science", "design": return "chat"
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

    /// Rolling multi-agent entropy series (independent per agent id).
    /// Updating one agent never clears another. Offline samples stay as
    /// history but are not claimed current — see `AgentEntropyMemory`.
    @Published public private(set) var entropyMemory = AgentEntropyMemory()

    /// Last equality-gated joint snapshot for HUD + menu-bar co-consumers.
    /// Updated only when telemetry fields change (not pure clock).
    @Published public private(set) var lastSharedTelemetry = SharedTelemetrySnapshot()

    /// Latest FlexAIDdS / DatasetRunner benchmark progress from the gate (nil if none).
    @Published public private(set) var benchmark: BenchmarkRunSnapshot?

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
    /// Full pets+registry disk scan cadence (gate DB / asks still every tick).
    /// `nonisolated` so pure cadence tests can read it without MainActor.
    public nonisolated static var fullScanInterval: TimeInterval {
        UICadence.agentFullScanInterval
    }
    private var lastFullScanAt: Date = .distantPast
    /// Last seen mtime of `agent_hub.db`. When it advances we force a full
    /// apply so pending asks surface without waiting for the pets interval.
    private var lastDBMtime: Date?
    /// Previous pending-ask count — notifications fire only on increases.
    private var lastPendingCount = 0

    public init(interval: TimeInterval = UICadence.agentHubInterval) {
        self.interval = UICadence.clampAgentHubInterval(interval)
    }

    public func start() {
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = min(0.2, interval * 0.3)   // coalesce with resource ticks
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
    /// Poll split (P1.9 / P0.6):
    /// - **Every tick (`UICadence.agentHubInterval`):** gate DB — agents, asks, entropy.
    /// - **Every `fullScanInterval`:** pets + registry disk scan +
    ///   process-attach re-check.
    /// - **DB mtime change:** force a full scan so asks appear immediately when
    ///   the gate writes, without waiting for the pets interval.
    ///
    /// NSWorkspace running-app enumeration and SQLite / pets I/O run on a
    /// utility detached task — never on the MainActor timer callback — so the
    /// menu bar / notch stay responsive under load.
    ///
    /// Assignments stay equality-gated so SwiftUI does not thrash on identical data.
    public func refresh() {
        guard !isPaused, !refreshing else { return }
        refreshing = true

        let socket = gateSocketPath
        let now = Date()
        let dbURL = AgentActivityReader.defaultGateDB
        let mtime = Self.modificationDate(of: dbURL)
        let mtimeChanged = mtime != nil && mtime != lastDBMtime
        if let mtime { lastDBMtime = mtime }

        let dueFull = now.timeIntervalSince(lastFullScanAt) >= Self.fullScanInterval
        let doFull = dueFull || mtimeChanged || lastFullScanAt == .distantPast
        if doFull { lastFullScanAt = now }

        let skipPets = !doFull
        let previous = skipPets ? summary.agents : nil
        let cachedBundles = runningBundleIDs
        let needBundleRefresh = now.timeIntervalSince(runningBundleIDsAt) > runningBundleTTL
            || runningBundleIDs.isEmpty

        Task.detached(priority: .utility) {
            // Host app roster is the expensive AppKit call — never on MainActor.
            let bundles: Set<String> = needBundleRefresh
                ? Self.enumerateRunningBundleIDs()
                : cachedBundles
            let full = AgentActivityReader.loadFull(
                runningBundleIDs: bundles,
                skipPetsScan: skipPets,
                previousAgents: previous
            )
            let socketUp = FileManager.default.fileExists(atPath: socket)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if needBundleRefresh {
                    self.runningBundleIDs = bundles
                    self.runningBundleIDsAt = now
                }
                self.apply(full, socketUp: socketUp)
            }
        }
    }

    /// Enumerate running app bundle ids off the main thread (AppKit-safe read).
    nonisolated public static func enumerateRunningBundleIDs() -> Set<String> {
        #if canImport(AppKit)
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        #else
        []
        #endif
    }

    private static func modificationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
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
        // Retain simultaneous per-agent series from this poll’s measurements.
        // Ingest only mutates agents present in the batch — never wipes others.
        if !full.agentEntropy.isEmpty {
            var mem = entropyMemory
            mem.ingest(full.agentEntropy, now: full.summary.scannedAt)
            if mem != entropyMemory { entropyMemory = mem }
        }
        if benchmark != full.benchmark { benchmark = full.benchmark }

        // Notify co-consumers (menu bar, cloud) that shared telemetry advanced
        // without each re-polling SQLite. Equality-gated — pure clock is not dirty.
        let joint = SharedTelemetrySnapshot.capture(
            agents: summary.agents,
            pendingAsks: pendingAsks,
            recentActivity: recentActivity,
            agentEntropy: agentEntropy,
            bridgeConnected: false, // bridge is a separate object; consumers merge
            bridgeStatus: nil,
            entropyMemory: entropyMemory,
            gateAvailable: gateAvailable,
            scannedAt: full.summary.scannedAt
        )
        if SharedTelemetryBinding.shouldPublish(previous: lastSharedTelemetry, next: joint) {
            lastSharedTelemetry = joint
        }
        // Drop stale in-flight state for asks the gate has since cleared.
        let live = Set(full.pendingAsks.map(\.interactionId))
        if !resolving.isSubset(of: live) { resolving.formIntersection(live) }

        // Notify only when the open-ask count *increases* (a newly arrived ask),
        // not on every poll while the same card sits open.
        let newCount = full.pendingAsks.count
        if newCount > lastPendingCount, let newest = full.pendingAsks.first {
            ShannonNotifier.notifyAsk(prompt: newest.prompt, agentId: newest.agentId)
        }
        lastPendingCount = newCount
    }

    /// Cached running-bundle set for tests / callers that already hold MainActor.
    /// Production refresh enumerates via `enumerateRunningBundleIDs` off-main.
    private func currentRunningBundleIDs() -> Set<String> {
        let now = Date()
        if now.timeIntervalSince(runningBundleIDsAt) > runningBundleTTL
            || runningBundleIDs.isEmpty {
            runningBundleIDs = Self.enumerateRunningBundleIDs()
            runningBundleIDsAt = now
        }
        return runningBundleIDs
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
            lastResolveError = Self.describeResolveError(error)
        }
    }

    /// Maps gate resolve failures to the status line shown on gate cards.
    ///
    /// **UX-042:** `.socketUnavailable` shares `GateAskActionCopy.macGateOffline`
    /// with pre-disable chrome (`macGateAffordance`) — one shipping string for
    /// the same hub-offline meaning (no dual “then retry” vs “approve from here”).
    /// Pure / nonisolated so tests and off-main resolve paths share one mapper.
    nonisolated static func describeResolveError(_ error: Error) -> String {
        guard let e = error as? GateApprovalClient.ApprovalError else {
            return "Couldn't reach the gate — \(error.localizedDescription)"
        }
        switch e {
        case .socketUnavailable: return GateAskActionCopy.macGateOffline
        case .connectFailed:     return "Gate refused the connection — retry"
        case .writeFailed:       return "Write to gate failed — retry"
        case .timedOut:          return "Gate not responding — retry"
        }
    }
}
