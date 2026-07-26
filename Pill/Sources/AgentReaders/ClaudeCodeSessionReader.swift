import Foundation
import PillCore

// MARK: - Claude Code on-disk session reader

/// Reads `~/.claude/projects/<encoded-cwd>/*.jsonl` without requiring a gate socket.
///
/// Fail-closed: missing roots and unparseable lines yield empty results — never
/// invents token/quota fields.
public struct ClaudeCodeSessionReader: SessionProviding {
    public let providerId = "claude_code_artifacts"
    public var projectsRoot: URL
    public var maxSessions: Int
    public var maxLinesPerFile: Int

    public init(
        projectsRoot: URL? = nil,
        maxSessions: Int = 24,
        maxLinesPerFile: Int = 400
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsRoot = projectsRoot
            ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        self.maxSessions = max(0, maxSessions)
        self.maxLinesPerFile = max(1, maxLinesPerFile)
    }

    public func fetchSessions(now: Date) -> [AgentSession] {
        Self.readSessions(
            projectsRoot: projectsRoot,
            now: now,
            maxSessions: maxSessions,
            maxLinesPerFile: maxLinesPerFile
        )
    }

    public static func readSessions(
        projectsRoot: URL,
        now: Date = Date(),
        maxSessions: Int = 24,
        maxLinesPerFile: Int = 400
    ) -> [AgentSession] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectsRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [AgentSession] = []
        for dir in projectDirs {
            var dirFlag: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &dirFlag), dirFlag.boolValue else {
                continue
            }
            let cwd = decodeProjectDirectoryName(dir.lastPathComponent)
            let projectName = (cwd as NSString).lastPathComponent
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                if let session = parseSessionFile(
                    url: file,
                    cwd: cwd,
                    projectName: projectName,
                    now: now,
                    maxLines: maxLinesPerFile
                ) {
                    sessions.append(session)
                }
            }
        }

        sessions.sort { $0.updatedAt > $1.updatedAt }
        if sessions.count > maxSessions {
            return Array(sessions.prefix(maxSessions))
        }
        return sessions
    }

    /// Claude encodes cwd as absolute path with `/` and `.` replaced by `-`
    /// (e.g. `/Users/lp.more/Docs/App` → `-Users-lp-more-Docs-App`).
    /// Prefer matching the current home prefix so dots in the username survive.
    public static func decodeProjectDirectoryName(
        _ name: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let encodedHome = home
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        if name == encodedHome { return home }
        if name.hasPrefix(encodedHome + "-") {
            let rest = String(name.dropFirst(encodedHome.count + 1))
            return home + "/" + rest.replacingOccurrences(of: "-", with: "/")
        }
        // Fixtures / other users: best-effort slash restore.
        if name.hasPrefix("-") {
            return "/" + String(name.dropFirst()).replacingOccurrences(of: "-", with: "/")
        }
        return name
    }

    public static func parseSessionFile(
        url: URL,
        cwd: String?,
        projectName: String?,
        now: Date,
        maxLines: Int
    ) -> AgentSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }

        let sessionIdFromFile = url.deletingPathExtension().lastPathComponent
        var sessionId = sessionIdFromFile
        var customTitle: String?
        var lastPrompt: String?
        var lastTimestamp: Date?
        var firstTimestamp: Date?
        var lastAssistantSnippet: String?
        var tokensIn: Int?
        var tokensOut: Int?
        var lineCount = 0

        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            lineCount += 1
            if lineCount > maxLines { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if let sid = obj["sessionId"] as? String, !sid.isEmpty {
                sessionId = sid
            }
            if let ts = parseTimestamp(obj["timestamp"]) {
                if firstTimestamp == nil { firstTimestamp = ts }
                lastTimestamp = ts
            }
            // Latest known usage wins; missing/malformed stays nil (fail-closed).
            if let usage = extractUsage(from: obj) {
                if let tin = usage.tokensIn { tokensIn = tin }
                if let tout = usage.tokensOut { tokensOut = tout }
            }
            let type = (obj["type"] as? String)?.lowercased() ?? ""
            switch type {
            case "custom-title":
                if let t = obj["customTitle"] as? String, !t.isEmpty { customTitle = t }
            case "last-prompt":
                if let p = obj["lastPrompt"] as? String, !p.isEmpty { lastPrompt = p }
            case "queue-operation":
                if let c = obj["content"] as? String, !c.isEmpty { lastPrompt = c }
            case "assistant":
                if let snippet = extractText(from: obj) {
                    lastAssistantSnippet = AgentActivitySnapshot.shorten(snippet, max: 80)
                }
            case "user":
                if let snippet = extractText(from: obj), lastPrompt == nil {
                    lastPrompt = snippet
                }
            default:
                break
            }
        }

        // Require at least an identity signal.
        guard sessionId.isEmpty == false else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate)
        let updated = lastTimestamp ?? mtime ?? now
        let task = customTitle ?? lastPrompt ?? lastAssistantSnippet
        let activity = lastPrompt ?? lastAssistantSnippet ?? customTitle

        return AgentSession(
            id: "claude_code:\(sessionId)",
            agentId: "claude_code",
            displayName: "Claude Code",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: updated,
            project: projectName,
            cwd: cwd,
            stateLabel: "artifact",
            lastTask: task.map { AgentActivitySnapshot.shorten($0, max: 120) },
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            sourcePath: url.path,
            startedAt: firstTimestamp,
            activitySummary: activity.map { AgentActivitySnapshot.shorten($0, max: 120) }
        )
    }

    /// Extract token usage from a Claude Code JSONL line.
    ///
    /// Prefers `message.usage`, then top-level `usage`.
    /// - `tokensOut` = non-negative `output_tokens` when present
    /// - `tokensIn` = sum of present non-negative ints among
    ///   `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`
    ///   (only keys that exist; no invented fields)
    /// Returns nil when no usage dict or no usable token keys.
    public static func extractUsage(from obj: [String: Any]) -> (tokensIn: Int?, tokensOut: Int?)? {
        let usage: [String: Any]?
        if let message = obj["message"] as? [String: Any],
           let nested = message["usage"] as? [String: Any] {
            usage = nested
        } else if let top = obj["usage"] as? [String: Any] {
            usage = top
        } else {
            return nil
        }
        guard let usage else { return nil }

        let inputKeys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
        var inSum: Int?
        for key in inputKeys {
            guard usage[key] != nil, let v = nonNegativeInt(usage[key]) else { continue }
            inSum = (inSum ?? 0) + v
        }
        let out = usage["output_tokens"] != nil ? nonNegativeInt(usage["output_tokens"]) : nil
        if inSum == nil && out == nil { return nil }
        return (tokensIn: inSum, tokensOut: out)
    }

    /// Fail-closed non-negative integer from JSONSerialization values.
    public static func nonNegativeInt(_ value: Any?) -> Int? {
        if let i = value as? Int {
            return i >= 0 ? i : nil
        }
        if let n = value as? NSNumber {
            // Bool is an NSNumber subclass on Apple platforms — reject.
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            guard d >= 0, d == floor(d), d <= Double(Int.max) else { return nil }
            return n.intValue
        }
        if let d = value as? Double {
            guard d >= 0, d == floor(d), d <= Double(Int.max) else { return nil }
            return Int(d)
        }
        return nil
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = value as? Double {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        if let n = value as? Int {
            let d = Double(n)
            return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d)
        }
        return nil
    }

    private static func extractText(from obj: [String: Any]) -> String? {
        if let content = obj["content"] as? String, !content.isEmpty { return content }
        if let message = obj["message"] as? [String: Any] {
            if let content = message["content"] as? String, !content.isEmpty { return content }
            if let parts = message["content"] as? [[String: Any]] {
                for part in parts {
                    if let t = part["text"] as? String, !t.isEmpty { return t }
                }
            }
        }
        return nil
    }
}
