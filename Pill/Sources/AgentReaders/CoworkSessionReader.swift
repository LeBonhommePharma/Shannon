import Foundation
import PillCore

// MARK: - Claude Cowork local session reader (AgentNotch works-with #01)

/// Reads Claude Desktop Cowork sessions under
/// `~/Library/Application Support/Claude/local-agent-mode-sessions/**/local_*.json`.
///
/// Fail-closed: missing roots / non-session JSON → empty. Never invents tokens.
/// Status is observational from timestamps + archive flag (no gate Approve).
public struct CoworkSessionReader: SessionProviding {
    public let providerId = "cowork_artifacts"
    public var sessionsRoot: URL
    public var maxSessions: Int
    /// Sessions with `lastActivityAt` older than this are still listed but idle.
    public var recentActivityWindow: TimeInterval

    public init(
        sessionsRoot: URL? = nil,
        maxSessions: Int = 24,
        recentActivityWindow: TimeInterval = 30 * 60
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsRoot = sessionsRoot
            ?? home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        self.maxSessions = max(0, maxSessions)
        self.recentActivityWindow = max(60, recentActivityWindow)
    }

    public func fetchSessions(now: Date) -> [AgentSession] {
        Self.readSessions(
            sessionsRoot: sessionsRoot,
            now: now,
            maxSessions: maxSessions,
            recentActivityWindow: recentActivityWindow
        )
    }

    public static func readSessions(
        sessionsRoot: URL,
        now: Date = Date(),
        maxSessions: Int = 24,
        recentActivityWindow: TimeInterval = 30 * 60
    ) -> [AgentSession] {
        let files = collectSessionFiles(under: sessionsRoot)
        var sessions: [AgentSession] = []
        for file in files {
            if let s = parseSessionFile(url: file, now: now, recentActivityWindow: recentActivityWindow) {
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
            let name = url.lastPathComponent
            guard name.hasSuffix(".json") else { continue }
            // Session blobs: local_<uuid>.json (or local_ditto_…).
            guard name.hasPrefix("local_") else { continue }
            // Skip nested skill/plugin trees.
            if url.path.contains("/skills/") || url.path.contains(".claude-plugin") {
                continue
            }
            out.append(url)
        }
        return out
    }

    public static func parseSessionFile(
        url: URL,
        now: Date,
        recentActivityWindow: TimeInterval
    ) -> AgentSession? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let sessionId = (obj["sessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? url.deletingPathExtension().lastPathComponent
        guard !sessionId.isEmpty else { return nil }

        // Cache / policy files also live as json under the tree — require identity.
        let title = nonEmptyString(obj["title"])
        let processName = nonEmptyString(obj["processName"])
        guard title != nil || processName != nil || sessionId.hasPrefix("local_") else {
            return nil
        }

        let archived = obj["isArchived"] as? Bool ?? false
        let model = nonEmptyString(obj["model"])
        let cwd = nonEmptyString(obj["cwd"])
        let folders = obj["userSelectedFolders"] as? [String] ?? []
        let selected = folders.first.flatMap(nonEmptyString)
        let projectFolder = selected.map { ($0 as NSString).lastPathComponent }
            ?? cwd.map { ($0 as NSString).lastPathComponent }

        let created = epochMillis(obj["createdAt"])
        let lastActivity = epochMillis(obj["lastActivityAt"]) ?? created
        let updated = lastActivity ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate) ?? now

        let age = now.timeIntervalSince(updated)
        let status: AgentRunStatus = {
            if archived { return .idle }
            if age <= recentActivityWindow { return .midTask }
            return .idle
        }()

        let task = title
            ?? nonEmptyString(obj["initialMessage"]).map {
                AgentActivitySnapshot.shorten($0, max: 120)
            }
            ?? processName

        return AgentSession(
            id: "cowork:\(sessionId)",
            agentId: "cowork",
            displayName: "Cowork",
            presence: .observed,
            status: status,
            sourceKind: .artifact,
            updatedAt: updated,
            project: projectFolder,
            cwd: selected ?? cwd,
            stateLabel: archived ? "archived" : (status == .midTask ? "working" : "idle"),
            lastTask: task.map { AgentActivitySnapshot.shorten($0, max: 120) },
            model: model,
            sourcePath: url.path,
            startedAt: created,
            activitySummary: task.map { AgentActivitySnapshot.shorten($0, max: 120) }
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Claude stores epoch **milliseconds** as JSON numbers.
    private static func epochMillis(_ value: Any?) -> Date? {
        let ms: Double?
        if let d = value as? Double {
            ms = d
        } else if let i = value as? Int {
            ms = Double(i)
        } else if let n = value as? NSNumber {
            ms = n.doubleValue
        } else {
            ms = nil
        }
        guard let ms, ms > 1_000_000_000_000 else {
            // Already seconds, or missing.
            if let ms, ms > 1_000_000_000 { return Date(timeIntervalSince1970: ms) }
            return nil
        }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }
}
