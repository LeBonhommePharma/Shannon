import Foundation
import PillCore

// MARK: - Kimi CLI session reader (AgentNotch works-with #03)

/// Best-effort discovery of Kimi CLI session artifacts.
///
/// AgentNotch documents session files without requiring config. Shannon looks
/// under well-known roots (`~/.kimi`, `~/.moonshot`, `SHANNON_KIMI_SESSIONS`)
/// for `*.jsonl` / session JSON. **Fail-closed:** missing roots → `[]`.
///
/// Needs-you honesty: Kimi has no safe permission-hold API for remote Approve.
/// This reader never sets gate-answerable state; status is observational only.
public struct KimiSessionReader: SessionProviding {
    public let providerId = "kimi_artifacts"
    public var sessionRoots: [URL]
    public var maxSessions: Int
    public var maxLinesPerFile: Int

    public init(
        sessionRoots: [URL]? = nil,
        maxSessions: Int = 24,
        maxLinesPerFile: Int = 300
    ) {
        if let sessionRoots {
            self.sessionRoots = sessionRoots
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var roots: [URL] = [
                home.appendingPathComponent(".kimi/sessions", isDirectory: true),
                home.appendingPathComponent(".kimi", isDirectory: true),
                home.appendingPathComponent(".moonshot/sessions", isDirectory: true),
                home.appendingPathComponent(".moonshot", isDirectory: true),
            ]
            if let env = ProcessInfo.processInfo.environment["SHANNON_KIMI_SESSIONS"],
               !env.isEmpty {
                roots.insert(URL(fileURLWithPath: env, isDirectory: true), at: 0)
            }
            self.sessionRoots = roots
        }
        self.maxSessions = max(0, maxSessions)
        self.maxLinesPerFile = max(1, maxLinesPerFile)
    }

    public func fetchSessions(now: Date) -> [AgentSession] {
        Self.readSessions(
            roots: sessionRoots,
            now: now,
            maxSessions: maxSessions,
            maxLinesPerFile: maxLinesPerFile
        )
    }

    public static func readSessions(
        roots: [URL],
        now: Date = Date(),
        maxSessions: Int = 24,
        maxLinesPerFile: Int = 300
    ) -> [AgentSession] {
        var files: [URL] = []
        for root in roots {
            files.append(contentsOf: collectSessionFiles(under: root))
        }
        // De-dupe by path
        var seen = Set<String>()
        files = files.filter { seen.insert($0.path).inserted }

        var sessions: [AgentSession] = []
        for file in files {
            if let s = parseFile(url: file, now: now, maxLines: maxLinesPerFile) {
                sessions.append(s)
            }
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if sessions.count > maxSessions {
            return Array(sessions.prefix(maxSessions))
        }
        return sessions
    }

    public static func collectSessionFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "jsonl" || ext == "json" else { continue }
            let name = url.lastPathComponent.lowercased()
            // Skip obvious non-session config.
            if name == "config.json" || name == "settings.json" { continue }
            out.append(url)
        }
        return out
    }

    public static func parseFile(url: URL, now: Date, maxLines: Int) -> AgentSession? {
        if url.pathExtension.lowercased() == "jsonl" {
            return parseJSONL(url: url, now: now, maxLines: maxLines)
        }
        return parseJSONSession(url: url, now: now)
    }

    private static func parseJSONL(url: URL, now: Date, maxLines: Int) -> AgentSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }

        let sessionId = url.deletingPathExtension().lastPathComponent
        var lastUser: String?
        var lastAssistant: String?
        var model: String?
        var cwd: String?
        var lineCount = 0
        var lastTs: Date?
        /// Explicit "your turn" from session status — not inferred from message order alone.
        /// Survives user+assistant history when a later line marks wait/ask/needs_input.
        var waitingOnYou = false
        var waitPrompt: String?

        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            lineCount += 1
            if lineCount > maxLines { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if let m = obj["model"] as? String, !m.isEmpty { model = m }
            if let c = obj["cwd"] as? String ?? obj["working_directory"] as? String, !c.isEmpty {
                cwd = c
            }
            if let ts = parseTimestamp(obj["timestamp"] ?? obj["ts"] ?? obj["created_at"]) {
                lastTs = ts
            }
            let role = (obj["role"] as? String)?.lowercased()
                ?? (obj["type"] as? String)?.lowercased()
                ?? ""
            let textBit = extractText(obj)
            if role.contains("user") || role == "human", let textBit {
                lastUser = textBit
                // New user message after a wait clears the wait (agent may have continued).
                waitingOnYou = false
                waitPrompt = nil
            } else if role.contains("assistant") || role == "model", let textBit {
                lastAssistant = textBit
            }
            // Waiting-on-user markers from various CLIs (observational only).
            // Explicit flag — do NOT rely on lastUser ?? after assistant already spoke.
            if let status = (obj["status"] as? String)?.lowercased(),
               status.contains("wait") || status.contains("ask") || status == "needs_input"
                || status.contains("needs_you") || status == "paused_for_user" {
                waitingOnYou = true
                waitPrompt = textBit ?? lastAssistant ?? lastUser ?? "waiting on you"
            }
            // Assistant left an unanswered question (common Kimi/Claude-style end).
            if (role.contains("assistant") || role == "model"),
               let textBit,
               textBit.contains("?")
                || textBit.lowercased().contains("choose")
                || textBit.lowercased().contains("confirm") {
                // Only sticky if no later user reply (user branch clears waitingOnYou).
                waitingOnYou = true
                waitPrompt = textBit
            }
        }

        guard lastUser != nil || lastAssistant != nil || lineCount > 0 || waitingOnYou else {
            return nil
        }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate) ?? now
        let updated = lastTs ?? mtime
        // Prefer wait prompt when waiting so the row shows the question, not stale user text.
        let task = waitingOnYou
            ? (waitPrompt ?? lastAssistant ?? lastUser)
            : (lastUser ?? lastAssistant)
        let waiting = waitingOnYou || (lastUser != nil && lastAssistant == nil)

        return AgentSession(
            id: "kimi:\(sessionId)",
            agentId: "kimi",
            displayName: "Kimi",
            presence: .observed,
            status: waiting ? .blocked : .idle,
            sourceKind: .artifact,
            updatedAt: updated,
            project: cwd.map { ($0 as NSString).lastPathComponent },
            cwd: cwd,
            // Honest: surface wait; do not claim gate can Approve (AgentNotch policy).
            stateLabel: waiting ? "waiting (answer in terminal)" : "artifact",
            lastTask: task.map { AgentActivitySnapshot.shorten($0, max: 120) },
            model: model,
            sourcePath: url.path,
            activitySummary: task.map { AgentActivitySnapshot.shorten($0, max: 120) }
        )
    }

    private static func parseJSONSession(url: URL, now: Date) -> AgentSession? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let sessionId = (obj["session_id"] as? String)
            ?? (obj["sessionId"] as? String)
            ?? (obj["id"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        guard !sessionId.isEmpty else { return nil }

        // Require a session-ish signal so config.json is skipped.
        let title = (obj["title"] as? String) ?? (obj["name"] as? String)
        let messages = obj["messages"] as? [Any]
        guard title != nil || messages != nil || obj["model"] != nil else { return nil }

        let model = obj["model"] as? String
        let cwd = (obj["cwd"] as? String) ?? (obj["working_directory"] as? String)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate) ?? now
        let updated = parseTimestamp(obj["updated_at"] ?? obj["updatedAt"] ?? obj["lastActivityAt"])
            ?? mtime
        let task = title
            ?? (messages?.last as? [String: Any]).flatMap { extractText($0) }

        return AgentSession(
            id: "kimi:\(sessionId)",
            agentId: "kimi",
            displayName: "Kimi",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: updated,
            project: cwd.map { ($0 as NSString).lastPathComponent },
            cwd: cwd,
            stateLabel: "artifact",
            lastTask: task.map { AgentActivitySnapshot.shorten($0, max: 120) },
            model: model,
            sourcePath: url.path,
            activitySummary: task.map { AgentActivitySnapshot.shorten($0, max: 120) }
        )
    }

    private static func extractText(_ obj: [String: Any]) -> String? {
        if let c = obj["content"] as? String, !c.isEmpty { return c }
        if let t = obj["text"] as? String, !t.isEmpty { return t }
        if let parts = obj["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        return nil
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let s = value as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
        if let d = value as? Double {
            if d > 1_000_000_000_000 { return Date(timeIntervalSince1970: d / 1000) }
            if d > 1_000_000_000 { return Date(timeIntervalSince1970: d) }
        }
        if let i = value as? Int {
            let d = Double(i)
            if d > 1_000_000_000_000 { return Date(timeIntervalSince1970: d / 1000) }
            if d > 1_000_000_000 { return Date(timeIntervalSince1970: d) }
        }
        return nil
    }
}
