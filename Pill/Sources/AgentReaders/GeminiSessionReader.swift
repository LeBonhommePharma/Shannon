import Foundation
import PillCore

// MARK: - Gemini CLI session reader (ENH-027 / parity G2)

/// Best-effort discovery of Gemini CLI chat transcripts under
/// `~/.gemini/tmp/*/chats/session-*.jsonl`.
///
/// Each project workspace stores a `.project_root` file next to `chats/`.
/// **Fail-closed:** missing roots / unparseable files → `[]`. Never invents
/// tokens, model, or gate Approve. Status is observational only.
public struct GeminiSessionReader: SessionProviding {
    public let providerId = "gemini_artifacts"
    public var sessionRoots: [URL]
    public var maxSessions: Int
    public var maxLinesPerFile: Int
    public var resolveBranch: @Sendable (String?) -> String?

    public init(
        sessionRoots: [URL]? = nil,
        maxSessions: Int = 24,
        maxLinesPerFile: Int = 400,
        resolveBranch: (@Sendable (String?) -> String?)? = nil
    ) {
        if let sessionRoots {
            self.sessionRoots = sessionRoots
        } else {
            self.sessionRoots = Self.defaultSessionRoots()
        }
        self.maxSessions = max(0, maxSessions)
        self.maxLinesPerFile = max(1, maxLinesPerFile)
        self.resolveBranch = resolveBranch ?? { GitBranchProbe.branch(for: $0) }
    }

    public static func defaultSessionRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var roots: [URL] = []
        if let env = environment["SHANNON_GEMINI_SESSIONS"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        // Primary: tmp workspaces with chats/session-*.jsonl
        roots.append(home.appendingPathComponent(".gemini/tmp", isDirectory: true))
        // Some installs keep chats under history/
        roots.append(home.appendingPathComponent(".gemini/history", isDirectory: true))
        roots.append(home.appendingPathComponent(".gemini", isDirectory: true))
        return roots
    }

    public func fetchSessions(now: Date) -> [AgentSession] {
        Self.readSessions(
            roots: sessionRoots,
            now: now,
            maxSessions: maxSessions,
            maxLinesPerFile: maxLinesPerFile,
            resolveBranch: resolveBranch
        )
    }

    public static func readSessions(
        roots: [URL],
        now: Date = Date(),
        maxSessions: Int = 24,
        maxLinesPerFile: Int = 400,
        resolveBranch: (@Sendable (String?) -> String?)? = nil
    ) -> [AgentSession] {
        let branchOf: @Sendable (String?) -> String? =
            resolveBranch ?? { GitBranchProbe.branch(for: $0) }
        var files: [URL] = []
        for root in roots {
            files.append(contentsOf: collectSessionFiles(under: root))
        }
        var seen = Set<String>()
        files = files.filter { seen.insert($0.path).inserted }

        var sessions: [AgentSession] = []
        var branchCache: [String: String?] = [:]
        for file in files {
            guard var s = parseFile(url: file, now: now, maxLines: maxLinesPerFile) else {
                continue
            }
            if let cwd = s.cwd {
                if let cached = branchCache[cwd] {
                    s.branch = cached
                } else {
                    let b = branchOf(cwd)
                    branchCache[cwd] = b
                    s.branch = b
                }
            }
            sessions.append(s)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if sessions.count > maxSessions {
            return Array(sessions.prefix(maxSessions))
        }
        return sessions
    }

    /// `session-*.jsonl` under `chats/` (or any depth when under a known root).
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
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let name = url.lastPathComponent.lowercased()
            // Gemini CLI: session-<timestamp>-<hash>.jsonl
            guard name.hasPrefix("session-") || name.contains("session") else { continue }
            // Skip antigravity/IDE protobuf trees mistakenly under .gemini.
            if url.path.contains("/antigravity") { continue }
            out.append(url)
        }
        return out
    }

    /// Resolve cwd from a sibling `.project_root` walking up from the chat file.
    public static func projectRoot(forSessionFile url: URL) -> String? {
        var dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(".project_root")
            if fm.fileExists(atPath: candidate.path),
               let text = try? String(contentsOf: candidate, encoding: .utf8) {
                let path = text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty { return path }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    public static func parseFile(url: URL, now: Date, maxLines: Int) -> AgentSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }

        var sessionId: String?
        var lastUpdated: Date?
        var startTime: Date?
        var lastUser: String?
        var lastAssistant: String?
        var lineCount = 0
        var sawSessionSignal = false

        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            lineCount += 1
            if lineCount > maxLines { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }

            if let sid = obj["sessionId"] as? String ?? obj["session_id"] as? String,
               !sid.isEmpty {
                sessionId = sid
                sawSessionSignal = true
            }
            if let lu = parseTimestamp(obj["lastUpdated"] ?? obj["last_updated"]) {
                lastUpdated = lu
            }
            if let st = parseTimestamp(obj["startTime"] ?? obj["start_time"]) {
                startTime = st
            }

            // Bulk message replace from Gemini CLI persistence.
            if let set = obj["$set"] as? [String: Any] {
                if let lu = parseTimestamp(set["lastUpdated"] ?? set["last_updated"]) {
                    lastUpdated = lu
                }
                if let messages = set["messages"] as? [[String: Any]] {
                    for msg in messages {
                        applyMessage(msg, lastUser: &lastUser, lastAssistant: &lastAssistant)
                        sawSessionSignal = true
                    }
                }
                continue
            }

            // Standalone message / info lines.
            if obj["type"] != nil || obj["role"] != nil {
                applyMessage(obj, lastUser: &lastUser, lastAssistant: &lastAssistant)
                if obj["type"] as? String != "info" {
                    sawSessionSignal = true
                }
            }
        }

        guard sawSessionSignal || lastUser != nil || lastAssistant != nil else {
            return nil
        }

        let id = sessionId
            ?? url.deletingPathExtension().lastPathComponent
        guard !id.isEmpty else { return nil }

        let cwd = projectRoot(forSessionFile: url)
        let project = cwd.map { ($0 as NSString).lastPathComponent }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate) ?? now
        let updated = lastUpdated ?? mtime
        let task = lastUser ?? lastAssistant
        // User spoke, no assistant yet → agent turn (midTask). Otherwise idle artifact.
        let status: AgentRunStatus = {
            if lastUser != nil, lastAssistant == nil { return .midTask }
            if lastAssistant != nil, lastUser != nil { return .idle }
            return .idle
        }()
        let stateLabel: String = status == .midTask ? "working" : "artifact"

        return AgentSession(
            id: "gemini:\(id)",
            agentId: "gemini",
            displayName: "Gemini CLI",
            presence: .observed,
            status: status,
            sourceKind: .artifact,
            updatedAt: updated,
            project: project,
            cwd: cwd,
            stateLabel: stateLabel,
            lastTask: task.map { AgentActivitySnapshot.shorten($0, max: 120) },
            sourcePath: url.path,
            startedAt: startTime,
            activitySummary: task.map { AgentActivitySnapshot.shorten($0, max: 120) }
        )
    }

    private static func applyMessage(
        _ obj: [String: Any],
        lastUser: inout String?,
        lastAssistant: inout String?
    ) {
        let role = (obj["role"] as? String)?.lowercased() ?? ""
        let type = (obj["type"] as? String)?.lowercased() ?? ""
        let textBit = extractText(obj)
        guard let textBit, !textBit.isEmpty else { return }

        let isUser = role == "user" || type == "user" || type == "human"
        let isAssistant = role == "assistant" || role == "model"
            || type == "assistant" || type == "model" || type == "gemini"
            || type == "response"
        // Skip CLI update banners and other info noise as tasks.
        if type == "info" { return }

        if isUser {
            lastUser = textBit
        } else if isAssistant {
            lastAssistant = textBit
        }
    }

    private static func extractText(_ obj: [String: Any]) -> String? {
        if let c = obj["content"] as? String, !c.isEmpty { return c }
        if let t = obj["text"] as? String, !t.isEmpty { return t }
        if let parts = obj["content"] as? [[String: Any]] {
            let texts = parts.compactMap { part -> String? in
                if let t = part["text"] as? String, !t.isEmpty { return t }
                if let t = part["content"] as? String, !t.isEmpty { return t }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        if let parts = obj["content"] as? [String] {
            let joined = parts.filter { !$0.isEmpty }.joined(separator: " ")
            if !joined.isEmpty { return joined }
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
