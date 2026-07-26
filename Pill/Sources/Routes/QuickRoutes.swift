import Foundation

// MARK: - Quick Routes (per-agent path catalog)

/// One Finder-openable path for an agent. Missing paths are disabled — never created.
public struct QuickRoute: Sendable, Equatable, Identifiable {
    public var id: String
    public var agentId: String
    public var label: String
    public var path: String
    public var exists: Bool

    public init(id: String, agentId: String, label: String, path: String, exists: Bool) {
        self.id = id
        self.agentId = agentId
        self.label = label
        self.path = path
        self.exists = exists
    }

    public var isOpenable: Bool { exists }
}

public enum QuickRouteCatalog {
    public struct Spec: Sendable, Equatable {
        public var key: String
        public var label: String
        public var relativePath: String

        public init(key: String, label: String, relativePath: String) {
            self.key = key
            self.label = label
            self.relativePath = relativePath
        }
    }

    /// Declarative catalog keyed by Shannon agent id.
    public static func specs(for agentId: String) -> [Spec] {
        switch agentId {
        case "claude_code", "science", "design", "cowork", "dispatch":
            return [
                .init(key: "root", label: "Root", relativePath: ".claude"),
                .init(key: "skills", label: "Skills", relativePath: ".claude/skills"),
                .init(key: "agents", label: "Agents", relativePath: ".claude/agents"),
                .init(key: "commands", label: "Commands", relativePath: ".claude/commands"),
                .init(key: "rules", label: "Rules", relativePath: ".claude/CLAUDE.md"),
                .init(key: "settings", label: "Settings", relativePath: ".claude/settings.json"),
                .init(key: "hooks", label: "Hooks", relativePath: ".claude/hooks"),
                .init(key: "mcp", label: "MCP", relativePath: ".claude/mcp.json"),
                .init(key: "projects", label: "Projects / sessions", relativePath: ".claude/projects"),
                .init(key: "logs", label: "Debug logs", relativePath: ".claude/debug"),
            ]
        case "codex", "chatgpt":
            return [
                .init(key: "root", label: "Root", relativePath: ".codex"),
                .init(key: "sessions", label: "Sessions", relativePath: ".codex/sessions"),
                .init(key: "archived", label: "Archived sessions", relativePath: ".codex/archived_sessions"),
                .init(key: "config", label: "Config", relativePath: ".codex/config.toml"),
                .init(key: "rules", label: "Rules", relativePath: ".codex/rules"),
                .init(key: "skills", label: "Skills", relativePath: ".codex/skills"),
                .init(key: "mcp", label: "MCP", relativePath: ".codex/mcp.json"),
            ]
        case "grok_build":
            return [
                .init(key: "root", label: "Root", relativePath: ".grok"),
                .init(key: "skills", label: "Skills", relativePath: ".grok/skills"),
                .init(key: "sessions", label: "Sessions", relativePath: ".grok/sessions"),
                .init(key: "config", label: "Config", relativePath: ".grok/config.toml"),
            ]
        case "cursor":
            return [
                .init(key: "root", label: "Root", relativePath: ".cursor"),
                .init(key: "rules", label: "Rules", relativePath: ".cursor/rules"),
                .init(key: "skills", label: "Skills", relativePath: ".cursor/skills"),
                .init(key: "mcp", label: "MCP", relativePath: ".cursor/mcp.json"),
            ]
        case "xcode":
            return [
                .init(key: "derived", label: "DerivedData", relativePath: "Library/Developer/Xcode/DerivedData"),
                .init(key: "shannon", label: "Shannon pets", relativePath: ".shannon/pets/xcode"),
            ]
        default:
            return [
                .init(key: "shannon", label: "Shannon pets", relativePath: ".shannon/pets/\(agentId)"),
            ]
        }
    }

    /// Resolve routes under `home`. Existence is checked; nothing is created.
    public static func routes(
        for agentId: String,
        home: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [QuickRoute] {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        return specs(for: agentId).map { spec in
            let path = homeURL.appendingPathComponent(spec.relativePath).path
            let exists = fileExists(path)
            return QuickRoute(
                id: "\(agentId):\(spec.key)",
                agentId: agentId,
                label: spec.label,
                path: path,
                exists: exists
            )
        }
    }

    /// All catalog agents we surface by default.
    public static let defaultAgentIds: [String] = [
        "claude_code", "codex", "grok_build", "science", "design", "cursor", "xcode",
    ]

    public static func allRoutes(
        home: String,
        agentIds: [String] = defaultAgentIds,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [QuickRoute] {
        agentIds.flatMap { routes(for: $0, home: home, fileExists: fileExists) }
    }

    /// Panel list: **present first, then missing** — missing routes stay in the
    /// list so the UI can render them dimmed/disabled (never auto-created).
    public static func panelRoutes(
        home: String,
        agentIds: [String] = defaultAgentIds,
        limit: Int = 24,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [QuickRoute] {
        let all = allRoutes(home: home, agentIds: agentIds, fileExists: fileExists)
        let present = all.filter(\.exists)
        let missing = all.filter { !$0.exists }
        return Array((present + missing).prefix(max(0, limit)))
    }
}
