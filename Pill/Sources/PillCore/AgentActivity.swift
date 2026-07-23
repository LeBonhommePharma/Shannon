import Foundation

// MARK: - Snapshot models

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
    public var updatedAt: Date
    public var resumable: Bool
    public var historyCount: Int

    public init(
        id: String,
        displayName: String,
        status: AgentRunStatus,
        lastTask: String,
        source: String,
        updatedAt: Date,
        resumable: Bool,
        historyCount: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.lastTask = lastTask
        self.source = source
        self.updatedAt = updatedAt
        self.resumable = resumable
        self.historyCount = historyCount
    }

    /// Short line for the collapsed pill.
    public var collapsedLine: String {
        let task = Self.shorten(lastTask, max: 36)
        if task.isEmpty {
            return "\(displayName) · \(status.label)"
        }
        return "\(displayName) · \(task)"
    }

    public var relativeAge: String {
        let s = Date().timeIntervalSince(updatedAt)
        if s < 5 { return "now" }
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
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
            "api_key", "apikey", "sk-ant-", "sk-proj-", "sk-", "bearer ",
            "password=", "secret=", "begin private", "anthropic_api",
            "openai_api", "xai_api", "authorization:",
        ]
        if needles.contains(where: { lower.contains($0) }) { return true }
        // Long multi-token paste without agent: prefix → treat as junk for UI.
        if text.count > 140 && !lower.hasPrefix("agent:") { return true }
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

    public var busy: [AgentActivitySnapshot] {
        agents.filter { $0.status.isBusy }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public var primary: AgentActivitySnapshot? {
        busy.first ?? agents.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    public var busyCount: Int { busy.count }

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

    public static func load(
        petsRoot: URL = PetBootstrap.petsRoot,
        registryURL: URL = PetBootstrap.registryURL,
        gateDB: URL? = defaultGateDB,
        now: Date = Date(),
        staleAfter: TimeInterval = 45 * 60
    ) -> AgentActivitySummary {
        let fm = FileManager.default
        var byID: [String: AgentActivitySnapshot] = [:]

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
                byID[id] = AgentActivitySnapshot(
                    id: id,
                    displayName: name,
                    status: .idle,
                    lastTask: AgentActivitySnapshot.shorten(task, max: 120),
                    source: source,
                    updatedAt: updated,
                    resumable: false,
                    historyCount: 0
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

                let statusRaw = obj["status"] as? String ?? "idle"
                var status = AgentRunStatus(raw: statusRaw)
                let taskRaw = obj["last_task"] as? String ?? ""
                let task = AgentActivitySnapshot.looksLikeSecretOrJunk(taskRaw)
                    ? ""
                    : AgentActivitySnapshot.shorten(taskRaw, max: 120)
                let ts = obj["updated_at"] as? Double ?? 0
                let updated = ts > 0 ? Date(timeIntervalSince1970: ts) : .distantPast
                let resumable = obj["resumable"] as? Bool ?? false
                let hist = obj["history_count"] as? Int ?? 0

                if status.isBusy, now.timeIntervalSince(updated) > staleAfter {
                    status = .idle
                }

                let existing = byID[id]
                let display = existing?.displayName
                    ?? displayName(for: id, config: dir.appendingPathComponent("config.json"))
                let source = existing?.source ?? guessSource(id)

                byID[id] = AgentActivitySnapshot(
                    id: id,
                    displayName: display,
                    status: status,
                    lastTask: task.isEmpty ? (existing?.lastTask ?? "") : task,
                    source: source,
                    updatedAt: updated,
                    resumable: resumable,
                    historyCount: hist
                )
            }
        }

        // 3) Live hub gate DB (Claude: agents table) wins for status/entropy when fresher.
        if let gateDB {
            for row in loadGateAgents(dbURL: gateDB) {
                let existing = byID[row.id]
                var status = row.status
                if status.isBusy, now.timeIntervalSince(row.updatedAt) > staleAfter {
                    status = .idle
                }
                // Prefer gate when it has a newer timestamp or is actively connected.
                let preferGate = existing == nil
                    || row.updatedAt >= (existing?.updatedAt ?? .distantPast)
                    || status.isBusy
                if preferGate {
                    byID[row.id] = AgentActivitySnapshot(
                        id: row.id,
                        displayName: existing?.displayName ?? displayName(for: row.id, config: petsRoot.appendingPathComponent(row.id).appendingPathComponent("config.json")),
                        status: status,
                        lastTask: row.lastTask.isEmpty ? (existing?.lastTask ?? "") : row.lastTask,
                        source: existing?.source ?? guessSource(row.id),
                        updatedAt: row.updatedAt,
                        resumable: existing?.resumable ?? status.isBusy,
                        historyCount: max(existing?.historyCount ?? 0, row.historyCount)
                    )
                }
            }
        }

        let agents = byID.values.sorted { lhs, rhs in
            if lhs.status.isBusy != rhs.status.isBusy { return lhs.status.isBusy && !rhs.status.isBusy }
            return lhs.updatedAt > rhs.updatedAt
        }
        return AgentActivitySummary(agents: agents, scannedAt: now)
    }

    /// Merge pure helper for tests: pets/registry map + gate rows → summary.
    public static func merge(
        base: [AgentActivitySnapshot],
        gate: [AgentActivitySnapshot],
        now: Date = Date(),
        staleAfter: TimeInterval = 45 * 60
    ) -> AgentActivitySummary {
        var byID: [String: AgentActivitySnapshot] = [:]
        for a in base { byID[a.id] = a }
        for row in gate {
            var status = row.status
            if status.isBusy, now.timeIntervalSince(row.updatedAt) > staleAfter {
                status = .idle
            }
            let existing = byID[row.id]
            let preferGate = existing == nil
                || row.updatedAt >= (existing?.updatedAt ?? .distantPast)
                || status.isBusy
            if preferGate {
                byID[row.id] = AgentActivitySnapshot(
                    id: row.id,
                    displayName: existing?.displayName ?? row.displayName,
                    status: status,
                    lastTask: row.lastTask.isEmpty ? (existing?.lastTask ?? "") : row.lastTask,
                    source: existing?.source ?? row.source,
                    updatedAt: row.updatedAt,
                    resumable: existing?.resumable ?? status.isBusy,
                    historyCount: max(existing?.historyCount ?? 0, row.historyCount)
                )
            }
        }
        let agents = byID.values.sorted { lhs, rhs in
            if lhs.status.isBusy != rhs.status.isBusy { return lhs.status.isBusy && !rhs.status.isBusy }
            return lhs.updatedAt > rhs.updatedAt
        }
        return AgentActivitySummary(agents: agents, scannedAt: now)
    }

    /// Read `agents` table from hub SQLite (best-effort; empty if missing/locked).
    public static func loadGateAgents(dbURL: URL) -> [AgentActivitySnapshot] {
        GateDBReader.readAgents(path: dbURL.path)
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

    private var timer: Timer?
    private let interval: TimeInterval

    public init(interval: TimeInterval = 1.5) {
        self.interval = interval
    }

    public func start() {
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        summary = AgentActivityReader.load()
    }
}
