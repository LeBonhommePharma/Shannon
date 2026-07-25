import Foundation
import PillCore

// MARK: - Codex on-disk session reader

/// Reads Codex rollout JSONL under `~/.codex/sessions/**` (and optional archived).
///
/// Fail-closed: missing store → empty list. Never invents token/quota numbers.
public struct CodexSessionReader: SessionProviding {
    public let providerId = "codex_artifacts"
    public var sessionsRoot: URL
    public var archivedRoot: URL?
    public var maxSessions: Int
    public var maxLinesPerFile: Int

    public init(
        sessionsRoot: URL? = nil,
        archivedRoot: URL? = nil,
        maxSessions: Int = 24,
        maxLinesPerFile: Int = 300
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsRoot = sessionsRoot
            ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.archivedRoot = archivedRoot
        self.maxSessions = max(0, maxSessions)
        self.maxLinesPerFile = max(1, maxLinesPerFile)
    }

    public func fetchSessions(now: Date) -> [AgentSession] {
        Self.readSessions(
            sessionsRoot: sessionsRoot,
            archivedRoot: archivedRoot,
            now: now,
            maxSessions: maxSessions,
            maxLinesPerFile: maxLinesPerFile
        )
    }

    public static func readSessions(
        sessionsRoot: URL,
        archivedRoot: URL? = nil,
        now: Date = Date(),
        maxSessions: Int = 24,
        maxLinesPerFile: Int = 300
    ) -> [AgentSession] {
        var files: [URL] = []
        files.append(contentsOf: collectJSONL(under: sessionsRoot))
        if let archivedRoot {
            files.append(contentsOf: collectJSONL(under: archivedRoot))
        }
        var sessions: [AgentSession] = []
        for file in files {
            if let s = parseRollout(
                url: file,
                now: now,
                maxLines: maxLinesPerFile
            ) {
                sessions.append(s)
            }
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if sessions.count > maxSessions {
            return Array(sessions.prefix(maxSessions))
        }
        return sessions
    }

    public static func collectJSONL(under root: URL) -> [URL] {
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
            if url.pathExtension == "jsonl" {
                out.append(url)
            }
        }
        return out
    }

    public static func parseRollout(
        url: URL,
        now: Date,
        maxLines: Int
    ) -> AgentSession? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var sessionId: String?
        var cwd: String?
        var model: String?
        var lastTask: String?
        var lastEvent: String?
        var startedAt: Date?
        var updatedAt: Date?
        var completed = false
        var started = false
        var lineCount = 0

        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            lineCount += 1
            if lineCount > maxLines { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if let ts = parseTimestamp(obj["timestamp"]) {
                if startedAt == nil { startedAt = ts }
                updatedAt = ts
            }
            let type = (obj["type"] as? String)?.lowercased() ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]

            switch type {
            case "session_meta":
                if let id = payload["id"] as? String ?? payload["session_id"] as? String {
                    sessionId = id
                }
                if let c = payload["cwd"] as? String, !c.isEmpty { cwd = c }
                if let m = payload["model"] as? String, !m.isEmpty { model = m }
            case "turn_context":
                if let c = payload["cwd"] as? String, !c.isEmpty { cwd = c }
                if let m = payload["model"] as? String, !m.isEmpty { model = m }
            case "event_msg":
                let et = (payload["type"] as? String)?.lowercased() ?? ""
                if et == "task_started" { started = true }
                if et == "task_complete" || et == "task_completed" { completed = true }
                if let msg = payload["message"] as? String, !msg.isEmpty {
                    lastTask = msg
                    lastEvent = msg
                } else if !et.isEmpty {
                    lastEvent = et
                }
            case "response_item":
                if let role = payload["role"] as? String, role == "assistant",
                   let content = payload["content"] as? [[String: Any]] {
                    for part in content {
                        if let t = part["text"] as? String, !t.isEmpty {
                            lastTask = AgentActivitySnapshot.shorten(t, max: 100)
                            break
                        }
                    }
                }
            default:
                break
            }
        }

        // Identity from payload or filename `rollout-…-UUID.jsonl`
        if sessionId == nil {
            sessionId = sessionIdFromFilename(url.lastPathComponent)
        }
        guard let sid = sessionId, !sid.isEmpty else { return nil }

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate)
        let updated = updatedAt ?? mtime ?? now
        let project = cwd.map { ($0 as NSString).lastPathComponent }
        let status: AgentRunStatus = {
            if completed { return .idle }
            if started { return .midTask }
            return .idle
        }()
        let stateLabel: String = {
            if completed { return "finished" }
            if started { return "executing" }
            return "artifact"
        }()

        return AgentSession(
            id: "codex:\(sid)",
            agentId: "codex",
            displayName: "Codex",
            presence: .observed,
            status: status,
            sourceKind: .artifact,
            updatedAt: updated,
            project: project,
            cwd: cwd,
            stateLabel: stateLabel,
            lastTask: (lastTask ?? lastEvent).map { AgentActivitySnapshot.shorten($0, max: 120) },
            model: model,
            sourcePath: url.path,
            startedAt: startedAt,
            activitySummary: lastTask.map { AgentActivitySnapshot.shorten($0, max: 120) }
        )
    }

    public static func sessionIdFromFilename(_ name: String) -> String? {
        // rollout-2026-07-01T10-00-00-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl
        let base = (name as NSString).deletingPathExtension
        guard base.hasPrefix("rollout-") else {
            // bare uuid.jsonl
            if base.count >= 8 { return base }
            return nil
        }
        let parts = base.split(separator: "-")
        // uuid is last 5 hyphen groups: 8-4-4-4-12
        guard parts.count >= 6 else { return String(base.dropFirst("rollout-".count)) }
        let uuidParts = parts.suffix(5)
        return uuidParts.joined(separator: "-")
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        return nil
    }
}
