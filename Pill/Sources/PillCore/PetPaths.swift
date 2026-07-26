// PetPaths.swift — single path policy for both pet systems.
//
// Two on-disk roles, one resolution API:
//
//   packages  Codex-compatible v2 art
//             <root>/<pet-id>/{pet.json,spritesheet.webp}
//
//   agents    Shannon per-agent memory
//             <root>/<agent_id>/{state.json,memory.md,history.jsonl,config.json}
//
// Defaults (back-compat, no env required):
//   packages → ~/.codex/pets
//   agents   → ~/.shannon/pets
//
// Unified home (optional):
//   export SHANNON_PETS=/path/to/pets
//     packages → $SHANNON_PETS  (and $SHANNON_PETS/packages if present)
//     agents   → $SHANNON_PETS/agents
//
// Narrow overrides still work:
//   SHANNON_CODEX_PETS  — packages search only
//   CODEX_HOME          — packages under $CODEX_HOME/pets
//   SHANNON_PETS_AGENTS — agent memory root only
//   SHANNON_LOG_DIR     — Shannon home (agents → $SHANNON_LOG_DIR/pets when
//                         no SHANNON_PETS / SHANNON_PETS_AGENTS)
//
// Agent-memory roots are never searched as spritesheet stores.

import Foundation

/// Unified pet path policy for Codex packages + Shannon agent memory.
public enum PetPaths: Sendable {

    // MARK: - Env keys

    /// Master pets home (packages + agents subdir).
    public static let envUnified = "SHANNON_PETS"
    /// Packages-only override (legacy alias for spritesheet search).
    public static let envPackages = "SHANNON_CODEX_PETS"
    /// Agent-memory-only override.
    public static let envAgents = "SHANNON_PETS_AGENTS"
    public static let envCodexHome = "CODEX_HOME"
    public static let envShannonHome = "SHANNON_LOG_DIR"
    public static let envFlexaidHome = "FLEXAIDDS_LOG_DIR"

    /// Subdirectory name under `SHANNON_PETS` for agent memory.
    public static let agentsSubdir = "agents"
    /// Optional subdirectory under `SHANNON_PETS` for packages only.
    public static let packagesSubdir = "packages"

    // MARK: - Shannon home (logs / registry host)

    /// `~/.shannon` or `$SHANNON_LOG_DIR` / `$FLEXAIDDS_LOG_DIR`.
    public static func shannonHome(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let log = nonEmpty(env[envShannonHome]) {
            return URL(fileURLWithPath: expand(log), isDirectory: true)
        }
        if let log = nonEmpty(env[envFlexaidHome]) {
            return URL(fileURLWithPath: expand(log), isDirectory: true)
        }
        return home.appendingPathComponent(".shannon", isDirectory: true)
    }

    /// Optional unified pets home (`$SHANNON_PETS`).
    public static func unifiedHome(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = nonEmpty(env[envUnified]) else { return nil }
        return URL(fileURLWithPath: expand(raw), isDirectory: true)
    }

    // MARK: - Packages (Codex art)

    /// Default package roots. First existing package hit wins at resolve time.
    ///
    /// Order:
    /// 1. `$SHANNON_CODEX_PETS`
    /// 2. `$SHANNON_PETS/packages` (if that path exists as a directory)
    /// 3. `$SHANNON_PETS` (flat Codex layout — e.g. `~/.codex/pets`)
    /// 4. `$CODEX_HOME/pets`
    /// 5. `~/.codex/pets`
    public static func packageRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            roots.append(url)
        }

        if let extra = nonEmpty(env[envPackages]) {
            append(URL(fileURLWithPath: expand(extra), isDirectory: true))
        }

        if let unified = unifiedHome(env: env) {
            let packagesOnly = unified.appendingPathComponent(packagesSubdir, isDirectory: true)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: packagesOnly.path, isDirectory: &isDir), isDir.boolValue {
                append(packagesOnly)
            }
            append(unified)
        }

        if let codexHome = nonEmpty(env[envCodexHome]) {
            append(
                URL(fileURLWithPath: expand(codexHome), isDirectory: true)
                    .appendingPathComponent("pets", isDirectory: true)
            )
        }

        append(home.appendingPathComponent(".codex/pets", isDirectory: true))
        return roots
    }

    // MARK: - Agents (Shannon memory)

    /// Per-agent memory root (`state.json`, `memory.md`, …).
    ///
    /// Order:
    /// 1. `$SHANNON_PETS_AGENTS`
    /// 2. `$SHANNON_PETS/agents` when `$SHANNON_PETS` is set
    /// 3. `$SHANNON_LOG_DIR/pets` (or `~/.shannon/pets`)
    public static func agentMemoryRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let agents = nonEmpty(env[envAgents]) {
            return URL(fileURLWithPath: expand(agents), isDirectory: true)
        }
        if let unified = unifiedHome(env: env) {
            return unified.appendingPathComponent(agentsSubdir, isDirectory: true)
        }
        return shannonHome(home: home, env: env)
            .appendingPathComponent("pets", isDirectory: true)
    }

    /// True when `url` is the agent-memory root (must not be used as a package store).
    public static func isAgentMemoryRoot(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        url.standardizedFileURL == agentMemoryRoot(home: home, env: env).standardizedFileURL
    }

    /// Package roots with agent-memory path stripped (safety for resolve).
    public static func packageRootsExcludingMemory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        let memory = agentMemoryRoot(home: home, env: env).standardizedFileURL
        return packageRoots(home: home, env: env, fileManager: fileManager)
            .filter { $0.standardizedFileURL != memory }
    }

    /// Diagnostic snapshot for boot logs / tests.
    public static func snapshot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String: String] {
        let packages = packageRoots(home: home, env: env, fileManager: fileManager)
            .map(\.path)
            .joined(separator: ":")
        return [
            "unified": unifiedHome(env: env)?.path ?? "",
            "packages": packages,
            "agents": agentMemoryRoot(home: home, env: env).path,
            "shannonHome": shannonHome(home: home, env: env).path,
        ]
    }

    // MARK: - Internals

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
