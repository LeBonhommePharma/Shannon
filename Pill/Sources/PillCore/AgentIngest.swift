import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Model

/// A known agent kind that can own a pet under `~/.shannon/pets/{id}/`.
public struct AgentKind: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var displayName: String
    public var source: String          // terminal | browser | ide | chat | other
    public var bundleHint: String?     // last-seen bundle id

    public init(id: String, displayName: String, source: String, bundleHint: String? = nil) {
        self.id = Self.sanitizeID(id)
        self.displayName = displayName
        self.source = source
        self.bundleHint = bundleHint
    }

    /// Lowercase snake_case, safe for directory names.
    public static func sanitizeID(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "_"
        }
        var s = String(mapped)
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? "local_test" : String(s.prefix(48))
    }
}

/// Result of one ⌘D / "Add Agent" capture.
public struct AgentIngestResult: Sendable, Equatable {
    public var agent: AgentKind
    public var taskSummary: String
    public var petPath: String
    public var createdPet: Bool
    public var gateNotified: Bool
    public var sourceApp: String
    public var message: String

    public var pillLabel: String {
        "+\(agent.displayName)"
    }
}

// MARK: - Frontmost app tracker

/// Remembers the last non-Shannon app so ⌘D from the status-item menu still
/// targets the app the user was in (Terminal, Claude, browser, …).
@MainActor
public final class FrontmostAppTracker {
    public static let shared = FrontmostAppTracker()

    public private(set) var lastBundleID: String?
    public private(set) var lastAppName: String?
    private var observer: NSObjectProtocol?

    private init() {}

    public func start() {
        #if canImport(AppKit)
        snapshot(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.snapshot(app) }
        }
        #endif
    }

    public func stop() {
        #if canImport(AppKit)
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        #endif
        observer = nil
    }

    #if canImport(AppKit)
    private func snapshot(_ app: NSRunningApplication?) {
        guard let app else { return }
        let bid = app.bundleIdentifier ?? ""
        // Ignore ourselves and the loginwindow / finder-as-desktop noise only when empty.
        if bid.hasPrefix("com.lebonhommepharma.shannon") { return }
        if bid == "com.apple.loginwindow" { return }
        lastBundleID = bid.isEmpty ? nil : bid
        lastAppName = app.localizedName
    }
    #endif
}

// MARK: - Mapping

/// Pure bundle-id → agent mapping. Tested without AppKit.
public enum AgentAppMapper {
    /// Built-in agent ids (aligned with hub/pet_manager ALL_AGENTS + extras).
    public static let knownIDs: Set<String> = [
        "claude_code", "cowork", "dispatch", "science",
        "grok_build", "codex", "dataset_runner", "local_test",
        "chatgpt", "browser", "terminal", "cursor", "vscode",
    ]

    public static func map(
        bundleID: String?,
        appName: String?,
        page: BrowserPageContext? = nil
    ) -> AgentKind {
        let bid = (bundleID ?? "").lowercased()
        let name = (appName ?? "").lowercased()

        // Browser tab wins over generic "browser" bundle mapping.
        // Science (amber flask) vs SuperGrok/Grok Build (purple sparkles) etc.
        if let page, !page.isEmpty, let web = BrowserAgentDetector.detect(page: page) {
            return withCatalogStyle(web, bundleHint: bid.isEmpty ? (web.bundleHint ?? "") : bid)
        }
        // Even without URL, title-only page context can refine.
        if let page, !page.title.isEmpty, let web = BrowserAgentDetector.detect(page: page) {
            return withCatalogStyle(web, bundleHint: bid)
        }

        // Explicit bundle rules (most specific first).
        let rules: [(String, AgentKind)] = [
            // Terminals
            ("com.apple.terminal", .init(id: "terminal", displayName: "Terminal", source: "terminal")),
            ("com.googlecode.iterm2", .init(id: "terminal", displayName: "iTerm", source: "terminal")),
            ("dev.warp.warp-stable", .init(id: "terminal", displayName: "Warp", source: "terminal")),
            ("dev.warp.warp", .init(id: "terminal", displayName: "Warp", source: "terminal")),
            ("com.github.wez.wezterm", .init(id: "terminal", displayName: "WezTerm", source: "terminal")),
            ("com.mitchellh.ghostty", .init(id: "terminal", displayName: "Ghostty", source: "terminal")),
            ("co.zeit.hyper", .init(id: "terminal", displayName: "Hyper", source: "terminal")),
            ("net.kovidgoyal.kitty", .init(id: "terminal", displayName: "Kitty", source: "terminal")),
            // Chat / agents — Claude Science (operon) BEFORE generic Claude desktop
            ("com.openai.chat", .init(id: "chatgpt", displayName: "ChatGPT", source: "chat")),
            ("com.openai.codex", .init(id: "codex", displayName: "Codex", source: "chat")),
            ("com.anthropic.operon", .init(id: "science", displayName: "Claude Science", source: "chat")),
            ("com.anthropic.claudescience", .init(id: "science", displayName: "Claude Science", source: "chat")),
            ("com.anthropic.claude-science", .init(id: "science", displayName: "Claude Science", source: "chat")),
            ("com.anthropic.claudefordesktop", .init(id: "claude_code", displayName: "Claude Code", source: "chat")),
            ("com.anthropic.claude", .init(id: "claude_code", displayName: "Claude Code", source: "chat")),
            ("com.xai.grok", .init(id: "grok_build", displayName: "Grok Build", source: "chat")),
            ("ai.x.grok", .init(id: "grok_build", displayName: "Grok Build", source: "chat")),
            // IDEs
            ("com.todesktop.", .init(id: "cursor", displayName: "Cursor", source: "ide")), // prefix match below
            ("com.microsoft.vscode", .init(id: "vscode", displayName: "VS Code", source: "ide")),
            ("com.microsoft.VSCode", .init(id: "vscode", displayName: "VS Code", source: "ide")),
            ("com.apple.dt.xcode", .init(id: "claude_code", displayName: "Xcode", source: "ide")),
            // Browsers — only used when tab probe could not identify a web agent.
            ("com.apple.safari", .init(id: "browser", displayName: "Safari", source: "browser")),
            ("com.google.chrome", .init(id: "browser", displayName: "Chrome", source: "browser")),
            ("company.thebrowser.browser", .init(id: "browser", displayName: "Arc", source: "browser")),
            ("com.brave.browser", .init(id: "browser", displayName: "Brave", source: "browser")),
            ("org.mozilla.firefox", .init(id: "browser", displayName: "Firefox", source: "browser")),
            ("com.microsoft.edgemac", .init(id: "browser", displayName: "Edge", source: "browser")),
        ]

        // Native Grok / SuperGrok app → grok_build (purple sparkles, not Science flask)
        // Native Claude Science (com.anthropic.operon) → science above

        for (key, kind) in rules {
            if key.hasSuffix(".") {
                if bid.hasPrefix(key) {
                    return withCatalogStyle(kind, bundleHint: bid)
                }
            } else if bid == key {
                return withCatalogStyle(kind, bundleHint: bid)
            }
        }

        // Name fallbacks (unsigned / electron apps with shifting bundle ids).
        // Science BEFORE generic "claude" — app name is "Claude Science".
        if name.contains("claude science") || name == "claudescience"
            || (name.contains("science") && name.contains("claude"))
            || name.contains("operon") {
            return withCatalogStyle(
                .init(id: "science", displayName: "Claude Science", source: "chat"),
                bundleHint: bid
            )
        }
        if name.contains("claude") {
            return withCatalogStyle(
                .init(id: "claude_code", displayName: "Claude Code", source: "chat"),
                bundleHint: bid
            )
        }
        if name.contains("chatgpt") || name == "chat gpt" {
            return withCatalogStyle(
                .init(id: "chatgpt", displayName: "ChatGPT", source: "chat"),
                bundleHint: bid
            )
        }
        if name.contains("codex") {
            return withCatalogStyle(
                .init(id: "codex", displayName: "Codex", source: "chat"),
                bundleHint: bid
            )
        }
        if name.contains("grok") || name.contains("supergrok") {
            return withCatalogStyle(
                .init(id: "grok_build", displayName: "Grok Build", source: "chat"),
                bundleHint: bid
            )
        }
        if name.contains("cursor") {
            return withCatalogStyle(
                .init(id: "cursor", displayName: "Cursor", source: "ide"),
                bundleHint: bid
            )
        }
        if name.contains("code") || name.contains("vscode") {
            return withCatalogStyle(
                .init(id: "vscode", displayName: "VS Code", source: "ide"),
                bundleHint: bid
            )
        }
        if name.contains("terminal") || name.contains("iterm") || name.contains("warp") || name.contains("ghostty") || name.contains("kitty") {
            return .init(id: "terminal", displayName: appName ?? "Terminal", source: "terminal", bundleHint: bid)
        }
        if name.contains("safari") || name.contains("chrome") || name.contains("firefox") || name.contains("arc") || name.contains("brave") {
            return .init(id: "browser", displayName: appName ?? "Browser", source: "browser", bundleHint: bid)
        }

        // Unknown app → pet named after the app, still works offline.
        let rawID = appName.flatMap { $0.isEmpty ? nil : $0 } ?? (bid.isEmpty ? "local_test" : bid)
        let fallbackID = AgentKind.sanitizeID(rawID)
        let label = appName.flatMap { $0.isEmpty ? nil : $0 } ?? (bid.isEmpty ? "Local" : bid)
        return AgentKind(id: fallbackID, displayName: label, source: "other", bundleHint: bid.isEmpty ? nil : bid)
    }

    /// Prefer catalog displayName (icons/colours key off id; labels stay consistent).
    private static func withCatalogStyle(_ kind: AgentKind, bundleHint: String) -> AgentKind {
        let style = AgentStyleCatalog.style(for: kind.id)
        let known = AgentStyleCatalog.all.contains(where: { $0.id == kind.id })
        return AgentKind(
            id: kind.id,
            displayName: known ? style.displayName : kind.displayName,
            source: kind.source,
            bundleHint: bundleHint.isEmpty ? kind.bundleHint : bundleHint
        )
    }

    /// Optional clipboard override — **only** when the user is intentional.
    ///
    /// Accepted:
    ///   `agent: science`
    ///   `agent: codex fix docking crash`
    ///   short plain task ≤ 100 chars with no secrets
    ///
    /// Rejected (avoids pasting API keys / docs into pet last_task):
    ///   long blobs, multiline dumps, anything that looks like a secret.
    public static func parseClipboard(_ text: String?) -> (agentID: String?, task: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, nil)
        }
        if AgentActivitySnapshot.looksLikeSecretOrJunk(text) {
            // Still allow explicit agent: lines if the *first line* is clean enough.
            let first = text.split(whereSeparator: \.isNewline).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let lower = first.lowercased()
            guard lower.hasPrefix("agent:") || lower.hasPrefix("agent=") else {
                return (nil, nil)
            }
            // Parse only the agent: line; drop the rest of the junk paste.
            return parseAgentLine(first, restTask: nil)
        }

        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else {
            return (nil, nil)
        }
        let lower = first.lowercased()
        if lower.hasPrefix("agent:") || lower.hasPrefix("agent=") {
            let rest = lines.dropFirst().joined(separator: " ")
            let restTrim = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeRest = (restTrim.isEmpty || AgentActivitySnapshot.looksLikeSecretOrJunk(restTrim))
                ? nil : String(restTrim.prefix(120))
            return parseAgentLine(first, restTask: safeRest)
        }

        // Plain clipboard as task only if short and clean.
        let joined = lines.prefix(2).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count <= 100, !AgentActivitySnapshot.looksLikeSecretOrJunk(joined) else {
            return (nil, nil)
        }
        return (nil, joined.isEmpty ? nil : joined)
    }

    private static func parseAgentLine(_ first: String, restTask: String?) -> (String?, String?) {
        let rest = first.drop(while: { $0 != ":" && $0 != "=" }).dropFirst()
            .trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let id = parts.first.map { AgentKind.sanitizeID(String($0)) }
        var task: String? = parts.count > 1 ? String(parts[1]) : nil
        if task == nil { task = restTask }
        task = task?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = task, t.isEmpty || AgentActivitySnapshot.looksLikeSecretOrJunk(t) {
            task = nil
        } else if let t = task {
            task = String(t.prefix(120))
        }
        return (id, task)
    }
}

// MARK: - Pet filesystem (Swift, no Python required)

public enum PetBootstrap {
    public static var shannonHome: URL {
        if let env = ProcessInfo.processInfo.environment["SHANNON_LOG_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shannon")
    }

    public static var petsRoot: URL { shannonHome.appendingPathComponent("pets", isDirectory: true) }
    public static var registryURL: URL { shannonHome.appendingPathComponent("agents.json") }

    /// Ensure pet directory layout exists. Returns (path, createdNew).
    @discardableResult
    public static func ensurePet(agentID: String, displayName: String, task: String?) throws -> (URL, Bool) {
        let id = AgentKind.sanitizeID(agentID)
        let dir = petsRoot.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        var created = false
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            created = true
        }
        try fm.createDirectory(at: shannonHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let memory = dir.appendingPathComponent("memory.md")
        let history = dir.appendingPathComponent("history.jsonl")
        let config = dir.appendingPathComponent("config.json")
        let state = dir.appendingPathComponent("state.json")

        if !fm.fileExists(atPath: memory.path) {
            let seed = "# \(displayName)\n\nPet memory for agent `\(id)`.\n"
            try seed.write(to: memory, atomically: true, encoding: .utf8)
            created = true
        }
        if !fm.fileExists(atPath: history.path) {
            try Data().write(to: history)
            created = true
        }
        if !fm.fileExists(atPath: config.path) {
            let cfg: [String: Any] = [
                "voice_enabled": true,
                "notify_threshold": 3.5,
                "memory_limit_kb": 256,
                "display_name": displayName,
            ]
            try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
                .write(to: config, options: .atomic)
            created = true
        }

        let now = Date().timeIntervalSince1970
        let hasTask = !(task ?? "").isEmpty
        let stateObj: [String: Any] = [
            "status": hasTask ? "active" : "idle",
            "last_task": task ?? "",
            "last_cf_delta": NSNull(),
            "memory_size": (try? Data(contentsOf: memory).count) ?? 0,
            "history_count": 0,
            "updated_at": now,
            "resumable": hasTask,
        ]
        try JSONSerialization.data(withJSONObject: stateObj, options: [.prettyPrinted, .sortedKeys])
            .write(to: state, options: .atomic)

        // Append history only on real captures (not skeleton bootstrap).
        if hasTask {
            let event: [String: Any] = [
                "event": "ingest",
                "task": task ?? "",
                "ts": now,
                "source": "cmd_d",
            ]
            if let line = String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8) {
                if let handle = try? FileHandle(forWritingTo: history) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data((line + "\n").utf8))
                } else {
                    try? (line + "\n").write(to: history, atomically: true, encoding: .utf8)
                }
            }
        }

        return (dir, created)
    }

    public static func updateRegistry(agent: AgentKind, task: String?) {
        var list: [[String: Any]] = []
        if let data = try? Data(contentsOf: registryURL),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            list = arr.filter { ($0["id"] as? String) != agent.id }
        }
        list.insert([
            "id": agent.id,
            "display_name": agent.displayName,
            "source": agent.source,
            "bundle": agent.bundleHint as Any,
            "last_task": task as Any,
            "updated_at": Date().timeIntervalSince1970,
        ], at: 0)
        // Cap registry
        if list.count > 32 { list = Array(list.prefix(32)) }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: shannonHome, withIntermediateDirectories: true)
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    public static func listRegistry() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: registryURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }
}

// MARK: - Ingest service

/// Captures the frontmost (or last non-Shannon) app and bootstraps its pet.
/// Fully offline-capable; gate notification is best-effort.
@MainActor
public final class AgentIngestService: ObservableObject {
    @Published public private(set) var lastResult: AgentIngestResult?
    @Published public private(set) var recent: [AgentIngestResult] = []
    /// Menu bar shows the agent tag until this date, then reverts to H readout.
    @Published public private(set) var highlightUntil: Date = .distantPast

    public init() {}

    public var isHighlighting: Bool { Date() < highlightUntil }

    /// Primary entry for ⌘D / menu.
    @discardableResult
    public func captureFromFrontApp(
        clipboardText: String? = nil,
        forceAgentID: String? = nil
    ) -> AgentIngestResult {
        #if canImport(AppKit)
        let tracked = FrontmostAppTracker.shared
        let front = NSWorkspace.shared.frontmostApplication
        let bid = tracked.lastBundleID
            ?? front?.bundleIdentifier
        let name = tracked.lastAppName
            ?? front?.localizedName
        // Browser tab title/URL distinguishes Claude Science vs SuperGrok, etc.
        let page: BrowserPageContext? = {
            if BrowserPageProbe.isBrowser(bundleID: bid) {
                return BrowserPageProbe.probe(bundleID: bid, appName: name)
            }
            // Still probe window title for non-browser apps that embed webviews.
            let t = BrowserPageProbe.probe(bundleID: bid, appName: name)
            return t.isEmpty ? nil : t
        }()
        #else
        let bid: String? = nil
        let name: String? = nil
        let page: BrowserPageContext? = nil
        #endif

        let clip = clipboardText ?? Self.readClipboard()
        let (clipAgent, clipTask) = AgentAppMapper.parseClipboard(clip)

        var kind = AgentAppMapper.map(bundleID: bid, appName: name, page: page)
        // Prefer catalog display names / colors for known ids.
        let style = AgentStyleCatalog.style(for: kind.id)
        if AgentStyleCatalog.all.contains(where: { $0.id == kind.id }) {
            kind = AgentKind(
                id: kind.id,
                displayName: style.displayName,
                source: kind.source,
                bundleHint: kind.bundleHint
            )
        }
        if let force = forceAgentID, !force.isEmpty {
            let forced = AgentStyleCatalog.style(for: AgentKind.sanitizeID(force))
            kind = AgentKind(
                id: forced.id,
                displayName: forced.displayName,
                source: kind.source,
                bundleHint: bid
            )
        } else if let clipAgent {
            let forced = AgentStyleCatalog.style(for: clipAgent)
            kind = AgentKind(
                id: forced.id,
                displayName: forced.displayName,
                source: kind.source,
                bundleHint: bid
            )
        }

        // Prefer intentional clipboard task; else tab title; else short app label.
        let pageTitle = page?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let taskFromTitle: String? = {
            guard !pageTitle.isEmpty else { return nil }
            if AgentActivitySnapshot.looksLikeSecretOrJunk(pageTitle) { return nil }
            return AgentActivitySnapshot.shorten(pageTitle, max: 80)
        }()
        let task = clipTask
            ?? taskFromTitle
            ?? "Working in \(name ?? kind.displayName)"
        let sourceApp = {
            if let page, !page.url.isEmpty { return "\(name ?? "Browser") · \(page.url)" }
            if !pageTitle.isEmpty { return "\(name ?? "App") · \(pageTitle)" }
            return name ?? bid ?? "unknown"
        }()

        let result: AgentIngestResult
        do {
            let (url, created) = try PetBootstrap.ensurePet(
                agentID: kind.id, displayName: kind.displayName, task: task
            )
            PetBootstrap.updateRegistry(agent: kind, task: task)
            let gateOK = Self.notifyGateBestEffort(agentID: kind.id, task: task)
            result = AgentIngestResult(
                agent: kind,
                taskSummary: task,
                petPath: url.path,
                createdPet: created,
                gateNotified: gateOK,
                sourceApp: sourceApp,
                message: created
                    ? "New pet for \(kind.displayName) · \(kind.id)"
                    : "Updated \(kind.displayName) · \(kind.id)"
            )
        } catch {
            // Absolute failsafe: still return a result so UI can show the error.
            result = AgentIngestResult(
                agent: kind,
                taskSummary: task,
                petPath: PetBootstrap.petsRoot.appendingPathComponent(kind.id).path,
                createdPet: false,
                gateNotified: false,
                sourceApp: sourceApp,
                message: "Failed to write pet: \(error.localizedDescription)"
            )
        }

        lastResult = result
        highlightUntil = Date().addingTimeInterval(8)
        recent.insert(result, at: 0)
        if recent.count > 12 { recent = Array(recent.prefix(12)) }
        return result
    }

    private static func readClipboard() -> String? {
        #if canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }

    /// Best-effort: if hub gate is listening on /tmp/shannon.sock, send a status.
    /// Never throws; never blocks more than ~200ms.
    private static func notifyGateBestEffort(agentID: String, task: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["SHANNON_GATE_SOCKET"]
            ?? "/tmp/shannon.sock"
        // Use a short-lived Python-less raw Unix socket via Foundation is painful;
        // try connecting with Darwin sockets inline.
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBufferPointer { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        src.baseAddress!, pathBytes.count)
            }
        }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { return false }

        // Minimal frame: register-ish status JSON (gate may ignore unknown fields).
        let payload: [String: Any] = [
            "from": agentID,
            "message_type": "status",
            "payload": ["text": task, "event": "ingest"],
            "task_id": "ingest",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return false }
        line.append("\n")
        let bytes = Array(line.utf8)
        let sent = bytes.withUnsafeBufferPointer { buf in
            send(fd, buf.baseAddress, buf.count, 0)
        }
        return sent > 0
        #else
        return false
        #endif
    }
}
