import Foundation
import PillCore

// MARK: - Cursor agent-transcript reader (AgentNotch works-with #06)

/// Reads Cursor agent transcripts under `~/.cursor/projects/*/agent-transcripts/**/*.jsonl`.
///
/// Fail-closed: missing roots and unparseable files yield `[]` — never invents
/// tokens, model, or “needs you”. Cursor approval is hook-driven on AgentNotch;
/// this reader only surfaces session activity from on-disk transcripts.
public struct CursorSessionReader: SessionProviding {
    public let providerId = "cursor_artifacts"
    public var projectsRoot: URL
    public var maxSessions: Int
    public var maxLinesPerFile: Int
    public var resolveBranch: @Sendable (String?) -> String?

    public init(
        projectsRoot: URL? = nil,
        maxSessions: Int = 24,
        maxLinesPerFile: Int = 400,
        resolveBranch: (@Sendable (String?) -> String?)? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsRoot = projectsRoot
            ?? home.appendingPathComponent(".cursor/projects", isDirectory: true)
        self.maxSessions = max(0, maxSessions)
        self.maxLinesPerFile = max(1, maxLinesPerFile)
        self.resolveBranch = resolveBranch ?? { GitBranchProbe.branch(for: $0) }
    }

    public func fetchSessions(now: Date) -> [AgentSession] {
        Self.readSessions(
            projectsRoot: projectsRoot,
            now: now,
            maxSessions: maxSessions,
            maxLinesPerFile: maxLinesPerFile,
            resolveBranch: resolveBranch
        )
    }

    public static func readSessions(
        projectsRoot: URL,
        now: Date = Date(),
        maxSessions: Int = 24,
        maxLinesPerFile: Int = 400,
        resolveBranch: (@Sendable (String?) -> String?)? = nil
    ) -> [AgentSession] {
        let branchOf: @Sendable (String?) -> String? =
            resolveBranch ?? { GitBranchProbe.branch(for: $0) }
        let files = collectTranscripts(under: projectsRoot)
        var sessions: [AgentSession] = []
        var branchCache: [String: String?] = [:]
        for file in files {
            guard var s = parseTranscript(
                url: file,
                now: now,
                maxLines: maxLinesPerFile
            ) else { continue }
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

    /// Top-level agent transcripts only (skip `subagents/` noise).
    public static func collectTranscripts(under root: URL) -> [URL] {
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
            guard url.pathExtension == "jsonl" else { continue }
            // Prefer main conversation files: …/agent-transcripts/<uuid>/<uuid>.jsonl
            if url.path.contains("/subagents/") { continue }
            if !url.path.contains("agent-transcripts") { continue }
            out.append(url)
        }
        return out
    }

    /// Decode project folder name into a best-effort cwd / project label.
    ///
    /// Cursor uses path-like slugs (`Users-lp-more-Projects-Foo`). A naive
    /// replace-all `-` → `/` corrupts dotted usernames (`lp.more` → `lp/more`).
    /// Prefer home-encoded decode (same idea as ClaudeCodeSessionReader); when
    /// home does not match, fail-closed: `cwd = nil`, project = last path segment
    /// of the slug (best-effort basename only).
    public static func projectLabel(
        fromProjectDir name: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> (cwd: String?, project: String?) {
        if name.isEmpty || name == "empty-window" {
            return (nil, name.isEmpty ? nil : name)
        }
        // Home-encoded prefix: /Users/lp.more → Users-lp-more (dots and slashes → -)
        let encodedHome = home
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        if name == encodedHome {
            return (home, (home as NSString).lastPathComponent)
        }
        if name.hasPrefix(encodedHome + "-") {
            let rest = String(name.dropFirst(encodedHome.count + 1))
            // Only restore path separators for the remainder under home — never
            // re-split the username (already consumed as encodedHome).
            let path = home + "/" + rest.replacingOccurrences(of: "-", with: "/")
            let project = (path as NSString).lastPathComponent
            return (path, project.isEmpty ? name : project)
        }
        // Fail-closed cwd: free labels or foreign homes stay display-only.
        // Basename: last `-` segment of the slug (e.g. …-Projects-Shannon → Shannon).
        let basename = name.split(separator: "-").last.map(String.init) ?? name
        return (nil, basename.isEmpty ? name : basename)
    }

    public static func parseTranscript(
        url: URL,
        now: Date,
        maxLines: Int
    ) -> AgentSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }

        let sessionId = url.deletingPathExtension().lastPathComponent
        guard !sessionId.isEmpty else { return nil }

        // …/projects/<project>/agent-transcripts/<id>/<id>.jsonl
        let projectDirName: String? = {
            var parts = url.pathComponents
            if let idx = parts.firstIndex(of: "agent-transcripts"), idx > 0 {
                return parts[idx - 1]
            }
            return nil
        }()
        let labels = projectLabel(fromProjectDir: projectDirName ?? "")

        var lastUser: String?
        var lastAssistant: String?
        var turnEnded = false
        var turnStatus: String?
        var lineCount = 0

        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            lineCount += 1
            if lineCount > maxLines { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if let type = (obj["type"] as? String)?.lowercased(), type == "turn_ended" {
                turnEnded = true
                turnStatus = (obj["status"] as? String)?.lowercased()
                continue
            }
            let role = (obj["role"] as? String)?.lowercased() ?? ""
            let snippet = extractText(from: obj)
            if role == "user", let snippet, !snippet.isEmpty {
                lastUser = snippet
                turnEnded = false
            } else if role == "assistant", let snippet, !snippet.isEmpty {
                lastAssistant = snippet
            }
        }

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate) ?? now
        let task = lastUser ?? lastAssistant
        let status: AgentRunStatus = {
            if turnEnded { return .idle }
            if lastUser != nil, lastAssistant == nil { return .midTask }
            if lastAssistant != nil, !turnEnded { return .midTask }
            return .idle
        }()
        let stateLabel: String = {
            if turnEnded {
                return turnStatus == "success" ? "done" : "artifact"
            }
            return status == .midTask ? "working" : "artifact"
        }()

        return AgentSession(
            id: "cursor:\(sessionId)",
            agentId: "cursor",
            displayName: "Cursor",
            presence: .observed,
            status: status,
            sourceKind: .artifact,
            updatedAt: mtime,
            project: labels.project,
            cwd: labels.cwd,
            stateLabel: stateLabel,
            lastTask: task.map { AgentActivitySnapshot.shorten($0, max: 120) },
            sourcePath: url.path,
            activitySummary: task.map { AgentActivitySnapshot.shorten($0, max: 120) }
        )
    }

    private static func extractText(from obj: [String: Any]) -> String? {
        if let message = obj["message"] as? [String: Any] {
            if let content = message["content"] as? String, !content.isEmpty {
                return content
            }
            if let parts = message["content"] as? [[String: Any]] {
                var texts: [String] = []
                for p in parts {
                    if let t = p["text"] as? String, !t.isEmpty { texts.append(t) }
                }
                if !texts.isEmpty { return texts.joined(separator: " ") }
            }
        }
        if let content = obj["content"] as? String, !content.isEmpty { return content }
        if let text = obj["text"] as? String, !text.isEmpty { return text }
        return nil
    }
}
