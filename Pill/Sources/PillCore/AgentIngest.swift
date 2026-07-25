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
    ///
    /// Keeps its historical last-resort answer (`local_test`) for callers that
    /// already know *who* they are naming and only need a directory-safe string.
    /// Anything deciding *whose* identity this is must use ``meaningfulID``:
    /// `local_test` is a live gate identity, not a spare slot.
    public static func sanitizeID(_ raw: String) -> String {
        meaningfulID(raw) ?? "local_test"
    }

    /// The sanitized id, or `nil` when nothing survives sanitising ("•••", "   ",
    /// ""). `sanitizeID` answers `local_test` in exactly that case, which is fine
    /// as a folder name and catastrophic as *attribution*: `hub/agent_identity.py`
    /// lists `local_test` in IDENTITIES, the gate derives VALID_AGENTS from it,
    /// and `GateApprovalClient` registers as `local_test` to resolve approvals.
    /// Handing it to an app Shannon could not name rewrites that agent's pet,
    /// appends to its history and POSTs a status message in its name.
    public static func meaningfulID(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "_"
        }
        var s = String(mapped)
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? nil : String(s.prefix(48))
    }
}

/// An app that is emphatically *not* an agent: a macOS system service, a
/// menu-bar meter, a helper process. Capturing one must write nothing.
///
/// This exists because the two previous answers were both wrong. Minting a
/// per-app identity (`window_manager`) invented an agent the gate rejects;
/// routing to `local_test` was worse, because `local_test` is a *real* identity
/// in `hub/agent_identity.py` — it is in the gate's VALID_AGENTS and
/// `GateApprovalClient` registers as `local_test` to resolve approvals. So
/// pressing ⌘D on the Dock overwrote that agent's pet state, put it at the head
/// of the registry, and posted a broadcast message in its name. The only honest
/// third answer is to refuse.
public struct NonAgentApp: Sendable, Equatable {
    /// Human label for the refused app ("WindowManager", "Usage for Claude").
    public var label: String
    public var bundleID: String
    /// Why it was refused, phrased to complete "… is not an agent — it is …".
    public var reason: String

    public init(label: String, bundleID: String, reason: String) {
        self.label = label
        self.bundleID = bundleID
        self.reason = reason
    }

    /// One line the UI can show verbatim.
    public var message: String {
        let where_ = bundleID.isEmpty ? "" : " (\(bundleID))"
        return "\(label)\(where_) is not an agent — \(reason). Nothing captured."
    }
}

/// What a frontmost app maps to. `.notAnAgent` is a first-class verdict, not an
/// error: there is no agent id that may be attributed to a system service.
public enum AgentAppResolution: Sendable, Equatable {
    case agent(AgentKind)
    case notAnAgent(NonAgentApp)

    public var agent: AgentKind? {
        if case .agent(let kind) = self { return kind }
        return nil
    }

    public var refusal: NonAgentApp? {
        if case .notAnAgent(let refusal) = self { return refusal }
        return nil
    }

    public var isAgent: Bool { agent != nil }
}

/// Result of one ⌘D / "Add Agent" capture.
///
/// `agent == nil` means the capture was *refused* — nothing was written to
/// `~/.shannon`, nothing was posted to the gate — and `refusal` says why.
public struct AgentIngestResult: Sendable, Equatable {
    public var agent: AgentKind?
    public var refusal: NonAgentApp?
    public var taskSummary: String
    public var petPath: String
    public var createdPet: Bool
    public var gateNotified: Bool
    public var sourceApp: String
    public var message: String

    /// True only when a pet was actually written for a real agent.
    public var captured: Bool { agent != nil }

    public var pillLabel: String {
        guard let agent else { return "⊘ not an agent" }
        return "+\(agent.displayName)"
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

    /// Best-effort identity for an app, or `nil` when the app is not an agent
    /// at all. Callers that need to explain the refusal use ``resolve``.
    public static func map(
        bundleID: String?,
        appName: String?,
        page: BrowserPageContext? = nil,
        terminal: TerminalAgentProbe.Context? = nil
    ) -> AgentKind? {
        resolve(bundleID: bundleID, appName: appName, page: page, terminal: terminal).agent
    }

    /// Full verdict: an agent, or an explicit refusal with a reason.
    public static func resolve(
        bundleID: String?,
        appName: String?,
        page: BrowserPageContext? = nil,
        terminal: TerminalAgentProbe.Context? = nil
    ) -> AgentAppResolution {
        let bid = (bundleID ?? "").lowercased()
        let name = (appName ?? "").lowercased()
        let isTerminalApp = TerminalAgentProbe.isTerminal(bundleID: bid, appName: appName)

        // ── Terminal contents win over the terminal container ──────────────
        // Exactly parallel to the browser path below: the emulator is the
        // container, `terminal` says which agent is actually running in it.
        // Without this every emulator collapses to id "terminal", so two CLI
        // agents in two windows overwrite each other's pet.
        if let terminal, !terminal.isEmpty {
            return withCatalogStyle(
                AgentKind(
                    id: terminal.agentID,
                    displayName: terminal.displayName,
                    source: "terminal",
                    bundleHint: bid.isEmpty ? nil : bid
                ),
                bundleHint: bid
            )
        }
        // A terminal running only a shell keeps the generic identity, but the
        // emulator name survives instead of being flattened to "Terminal".
        if let terminal, isTerminalApp, !terminal.emulatorName.isEmpty {
            return withCatalogStyle(
                AgentKind(
                    id: "terminal",
                    displayName: terminal.emulatorName,
                    source: "terminal",
                    bundleHint: bid.isEmpty ? nil : bid
                ),
                bundleHint: bid
            )
        }

        // Would this app be refused outright, absent any page context? Computed
        // here, before the page branches, because ⌘D NEVER calls resolve without
        // one: `captureFromFrontApp` runs `BrowserPageProbe.probe` for every app
        // and CGWindowList hands back a window title for anything with a window.
        // A Finder window on ~/Projects/claude-notes therefore reached
        // `BrowserAgentDetector`, matched its bare title.contains("claude") and
        // was captured as **claude_code** — rewriting the real agent's pet,
        // appending to its history and POSTing to the gate in its name. That is
        // the same borrowed-identity defect the refusals below exist to stop,
        // and the same title leak the terminal probe already guards against.
        // A window title is not evidence of an agent; for a refused app only the
        // process probe above (or the user typing an id) may override.
        let refusedByBundle: NonAgentApp? = bundleRule(for: bid) == nil
            ? (claudeAdjacentRefusal(bid: bid, name: name, appName: appName)
                ?? appleSystemRefusal(bid: bid, appName: appName))
            : nil

        // Browser tab wins over generic "browser" bundle mapping.
        // Science (amber flask) vs SuperGrok/Grok Build (purple sparkles) etc.
        //
        // Never for terminals: a Ghostty window titled "⠂ claude-notes" is a
        // directory, not an agent, and `BrowserAgentDetector` matches on bare
        // title substrings. The probe above is the only evidence that counts.
        if !isTerminalApp, refusedByBundle == nil, let page, !page.isEmpty,
           let web = BrowserAgentDetector.detect(page: page) {
            return withCatalogStyle(web, bundleHint: bid.isEmpty ? (web.bundleHint ?? "") : bid)
        }
        // Even without URL, title-only page context can refine.
        if !isTerminalApp, refusedByBundle == nil, let page, !page.title.isEmpty,
           let web = BrowserAgentDetector.detect(page: page) {
            return withCatalogStyle(web, bundleHint: bid)
        }

        // Explicit bundle rules (most specific first) — see `bundleRules`.
        //
        // Native Grok / SuperGrok app → grok_build (purple sparkles, not the
        // Science flask); native Claude Science (com.anthropic.operon) → science,
        // matched above.
        if let hit = bundleRule(for: bid) {
            return withCatalogStyle(hit, bundleHint: bid)
        }

        // Claude-adjacent utilities that are emphatically not agents. Without
        // this "Usage for Claude.app" (com.ClaudeUsage) matches the
        // name.contains("claude") fallback below and registers itself as Claude
        // Code, stealing the capture from the real thing.
        if let refusal = claudeAdjacentRefusal(bid: bid, name: name, appName: appName) {
            return .notAnAgent(refusal)
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
        // Dispatch is not installed on every machine and its bundle id is not
        // knowable ahead of time, so the app *name* is the durable hook — and it
        // must beat `name.contains("claude")`, since the app presents itself as
        // "Claude Dispatch" as well as plain "Dispatch".
        if name == "dispatch" || name.contains("claude dispatch")
            || name.contains("dispatch") && name.contains("claude") {
            return withCatalogStyle(
                .init(id: "dispatch", displayName: "Dispatch", source: "chat"),
                bundleHint: bid
            )
        }
        if name.contains("cowork") {
            return withCatalogStyle(
                .init(id: "cowork", displayName: "Cowork", source: "chat"),
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
        if let emulator = TerminalAgentProbe.emulatorName(bundleID: bid, appName: appName) {
            return withCatalogStyle(
                .init(id: "terminal", displayName: emulator, source: "terminal"),
                bundleHint: bid
            )
        }
        if name.contains("safari") || name.contains("chrome") || name.contains("firefox") || name.contains("arc") || name.contains("brave") {
            return .agent(AgentKind(id: "browser", displayName: appName ?? "Browser",
                                    source: "browser", bundleHint: bid))
        }

        // Apple system services are not agents (see `appleSystemRefusal`). They
        // were being adopted purely because they can hold focus:
        // com.apple.windowmanager became an agent called "WindowManager" that
        // then showed as active in the HUD. Routing them to `local_test` instead
        // was not a fix — see `NonAgentApp`. Refuse.
        if let refusal = appleSystemRefusal(bid: bid, appName: appName) {
            return .notAnAgent(refusal)
        }

        // Unknown app → pet named after the app, still works offline.
        //
        // …unless there is nothing to name it with. The old fallback spelled the
        // missing name `local_test` — a live gate identity — so an app with no
        // bundle id and no usable name (`(nil, nil)` from `captureFromFrontApp`
        // when NSWorkspace has no frontmost app, a name like "•••" that
        // sanitises away) silently took over that agent's pet, history and gate
        // messages. `meaningfulID` refuses to invent a name; so do we.
        let rawID = appName.flatMap { $0.isEmpty ? nil : $0 } ?? (bid.isEmpty ? nil : bid)
        guard let rawID, let fallbackID = AgentKind.meaningfulID(rawID) else {
            return .notAnAgent(NonAgentApp(
                label: displayLabel(appName: appName, bundleID: bid),
                bundleID: bid,
                reason: "an app Shannon cannot identify"
            ))
        }
        let label = appName.flatMap { $0.isEmpty ? nil : $0 } ?? (bid.isEmpty ? "Local" : bid)
        return .agent(AgentKind(id: fallbackID, displayName: label, source: "other",
                                bundleHint: bid.isEmpty ? nil : bid))
    }

    /// Explicit bundle rules, most specific first. Hoisted out of ``resolve``
    /// so the refusal verdict can be computed *before* the window-title branch
    /// without duplicating the table.
    static let bundleRules: [(String, AgentKind)] = [
            // Terminals — reached only when the probe found no agent inside.
            ("com.apple.terminal", .init(id: "terminal", displayName: "Terminal", source: "terminal")),
            ("com.googlecode.iterm2", .init(id: "terminal", displayName: "iTerm", source: "terminal")),
            ("dev.warp.warp-stable", .init(id: "terminal", displayName: "Warp", source: "terminal")),
            ("dev.warp.warp", .init(id: "terminal", displayName: "Warp", source: "terminal")),
            ("com.github.wez.wezterm", .init(id: "terminal", displayName: "WezTerm", source: "terminal")),
            ("com.mitchellh.ghostty", .init(id: "terminal", displayName: "Ghostty", source: "terminal")),
            ("co.zeit.hyper", .init(id: "terminal", displayName: "Hyper", source: "terminal")),
            ("net.kovidgoyal.kitty", .init(id: "terminal", displayName: "Kitty", source: "terminal")),
            ("io.alacritty", .init(id: "terminal", displayName: "Alacritty", source: "terminal")),
            ("org.alacritty", .init(id: "terminal", displayName: "Alacritty", source: "terminal")),
            // Chat / agents — Claude Science (operon) BEFORE generic Claude desktop
            ("com.openai.chat", .init(id: "chatgpt", displayName: "ChatGPT", source: "chat")),
            ("com.openai.codex", .init(id: "codex", displayName: "Codex", source: "chat")),
            ("com.anthropic.operon", .init(id: "science", displayName: "Claude Science", source: "chat")),
            ("com.anthropic.claudescience", .init(id: "science", displayName: "Claude Science", source: "chat")),
            ("com.anthropic.claude-science", .init(id: "science", displayName: "Claude Science", source: "chat")),
            // Dispatch BEFORE any generic Claude rule: its window/app name is
            // "Claude Dispatch" in some builds, which the `name.contains("claude")`
            // fallback below would otherwise swallow into claude_code.
            ("com.anthropic.dispatch", .init(id: "dispatch", displayName: "Dispatch", source: "chat")),
            ("com.anthropic.claudedispatch", .init(id: "dispatch", displayName: "Dispatch", source: "chat")),
            ("com.anthropic.claude-dispatch", .init(id: "dispatch", displayName: "Dispatch", source: "chat")),
            ("com.anthropic.claude.dispatch", .init(id: "dispatch", displayName: "Dispatch", source: "chat")),
            // Claude Code — the native macOS app ships as com.anthropic.claude-code
            // (/…/Application Support/Claude/claude-code/*/claude.app), which no
            // rule matched: it only ever resolved via the appName fallback.
            ("com.anthropic.claude-code", .init(id: "claude_code", displayName: "Claude Code", source: "chat")),
            ("com.anthropic.claudecode", .init(id: "claude_code", displayName: "Claude Code", source: "chat")),
            ("com.anthropic.claude-code-url-handler", .init(id: "claude_code", displayName: "Claude Code", source: "chat")),
            // claude-devtools.app — measured on this machine, previously unmapped
            // and therefore minted as its own bogus "claude_devtools" agent.
            ("com.claudecode.context", .init(id: "claude_code", displayName: "Claude Code", source: "ide")),
            ("com.anthropic.claudefordesktop", .init(id: "claude_code", displayName: "Claude Code", source: "chat")),
            ("com.anthropic.claude", .init(id: "claude_code", displayName: "Claude Code", source: "chat")),
            ("com.anthropic.cowork", .init(id: "cowork", displayName: "Cowork", source: "chat")),
            ("com.xai.grok", .init(id: "grok_build", displayName: "Grok Build", source: "chat")),
            ("ai.x.grok", .init(id: "grok_build", displayName: "Grok Build", source: "chat")),
            ("com.x.grok", .init(id: "grok_build", displayName: "Grok Build", source: "chat")),
            ("ai.x.supergrok", .init(id: "grok_build", displayName: "Grok Build", source: "chat")),
            ("com.openai.chatgpt", .init(id: "chatgpt", displayName: "ChatGPT", source: "chat")),
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

    /// First matching bundle rule (`"com.todesktop."` is a prefix rule).
    static func bundleRule(for bid: String) -> AgentKind? {
        for (key, kind) in bundleRules {
            if key.hasSuffix(".") {
                if bid.hasPrefix(key) { return kind }
            } else if bid == key {
                return kind
            }
        }
        return nil
    }

    /// Menu-bar meters and helpers that merely have "Claude" in the name.
    static func claudeAdjacentRefusal(
        bid: String, name: String, appName: String?
    ) -> NonAgentApp? {
        let notAnAgentBundles: Set<String> = [
            "com.claudeusage",
            "com.anthropic.claude-code-url-handler",
        ]
        guard notAnAgentBundles.contains(bid)
            || name.contains("usage for claude") || name.contains("claude usage") else {
            return nil
        }
        // NOT `local_test`: that id is a live gate identity (agent_identity
        // IDENTITIES / VALID_AGENTS, and the id GateApprovalClient registers
        // as), so attributing a menu-bar meter to it clobbers a real agent's
        // pet and speaks in its name. Refuse instead.
        return NonAgentApp(
            label: displayLabel(appName: appName, bundleID: bid),
            bundleID: bid,
            reason: "a Claude-adjacent utility, not an agent"
        )
    }

    /// Apple system services are not agents. Every app Shannon legitimately
    /// recognises under com.apple.* (Terminal, Safari, Xcode) is matched by
    /// ``bundleRules`` first, so anything reaching here is infrastructure —
    /// WindowManager, Dock, Spotlight, controlcenter. These were being adopted
    /// as agents purely because they can hold focus.
    static func appleSystemRefusal(bid: String, appName: String?) -> NonAgentApp? {
        guard bid.hasPrefix("com.apple.") else { return nil }
        return NonAgentApp(
            label: displayLabel(appName: appName, bundleID: bid),
            bundleID: bid,
            reason: "a macOS system service"
        )
    }

    /// Label for a refused app: its own name, else the tail of its bundle id
    /// ("com.apple.windowmanager" → "windowmanager"), else something neutral.
    static func displayLabel(appName: String?, bundleID: String) -> String {
        if let appName, !appName.trimmingCharacters(in: .whitespaces).isEmpty {
            return appName
        }
        if let tail = bundleID.split(separator: ".").last, !tail.isEmpty {
            return String(tail)
        }
        return "This app"
    }

    /// Ids whose catalog entry is a placeholder for a *container*, not for an
    /// agent. "Terminal" and "Browser" are shelves, so the caller's label
    /// (Ghostty, Safari) is strictly more informative — the catalog is still
    /// consulted, but only for the icon and colour, which key off `id`.
    ///
    /// This is what used to make lines like `("com.mitchellh.ghostty", … "Ghostty")`
    /// dead code: every one of them was overwritten with the catalog's
    /// "Terminal" on the way out, so all seven emulators rendered identically.
    static let containerIDs: Set<String> = ["terminal", "browser"]

    /// Prefer catalog displayName (icons/colours key off id; labels stay
    /// consistent) — except for container ids, where a supplied label wins.
    static func applyCatalogStyle(_ kind: AgentKind, bundleHint: String = "") -> AgentKind {
        let style = AgentStyleCatalog.style(for: kind.id)
        let known = AgentStyleCatalog.all.contains(where: { $0.id == kind.id })
        let supplied = kind.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepSupplied = !supplied.isEmpty && containerIDs.contains(kind.id)
        return AgentKind(
            id: kind.id,
            displayName: keepSupplied ? supplied : (known ? style.displayName : kind.displayName),
            source: kind.source,
            bundleHint: bundleHint.isEmpty ? kind.bundleHint : bundleHint
        )
    }

    /// Styling shortcut used by every *agent* branch of `resolve`, so those
    /// branches read as `return withCatalogStyle(…)` and only the two refusal
    /// sites have to spell out `.notAnAgent`.
    private static func withCatalogStyle(_ kind: AgentKind, bundleHint: String) -> AgentAppResolution {
        .agent(applyCatalogStyle(kind, bundleHint: bundleHint))
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
        // `meaningfulID`, not `sanitizeID`: "agent: ***" is not a claim on
        // `local_test`, and sanitizeID's fallback would make it one.
        let id = parts.first.flatMap { AgentKind.meaningfulID(String($0)) }
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
            // "observed", never "active". This record is a ⌘D capture of whatever
            // app happened to be frontmost — it is evidence the user was looking
            // at something, NOT telemetry that an agent is doing work. Writing
            // "active" here (previously `hasTask ? "active" : "idle"`) made every
            // app ever captured claim to be a busy agent forever, because nothing
            // ever writes the status back down. On this machine that surfaced as
            // three "active" agents while the gate had all seven idle with
            // disconnected_at set. The gate is the only authority on liveness.
            "status": "observed",
            "source": "observed",
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
        // Terminal twin of the browser probe: which agent CLI is running *inside*
        // Ghostty/iTerm/Warp. nil for non-terminals; a Context with an empty
        // agentID for a terminal that is only running a shell.
        let terminal: TerminalAgentProbe.Context? =
            TerminalAgentProbe.probe(bundleID: bid, appName: name)
        #else
        let bid: String? = nil
        let name: String? = nil
        let page: BrowserPageContext? = nil
        let terminal: TerminalAgentProbe.Context? = nil
        #endif

        return capture(
            bundleID: bid, appName: name, page: page, terminal: terminal,
            clipboardText: clipboardText, forceAgentID: forceAgentID
        )
    }

    /// The capture itself, with the environment passed in so it is testable
    /// without a frontmost app. `captureFromFrontApp` is the ⌘D wrapper.
    ///
    /// Returns a refusal (`result.captured == false`, `result.agent == nil`)
    /// when the app is not an agent; in that case nothing is written to
    /// `~/.shannon` and the gate is not told anything.
    @discardableResult
    public func capture(
        bundleID: String?,
        appName: String?,
        page: BrowserPageContext? = nil,
        terminal: TerminalAgentProbe.Context? = nil,
        clipboardText: String? = nil,
        forceAgentID: String? = nil
    ) -> AgentIngestResult {
        // Short local names, because the body below quotes them a dozen times.
        let bid = bundleID
        let name = appName

        let clip = clipboardText ?? Self.readClipboard()
        let (clipAgent, clipTask) = AgentAppMapper.parseClipboard(clip)

        let resolution = AgentAppMapper.resolve(
            bundleID: bid, appName: name, page: page, terminal: terminal
        )
        // An id the *user* typed (`agent: science`, or a forced call) is a
        // deliberate identity claim and outranks whatever happened to be
        // frontmost. Nothing else may rescue a refusal.
        //
        // `meaningfulID`, not `sanitizeID`: punctuation is not an identity
        // claim, and sanitizeID's `local_test` fallback would turn `agent: ***`
        // — or a junk `forceAgentID` — into a claim on a live gate identity,
        // reopening the exact hole the refusal closes.
        let forcedID: String? = forceAgentID.flatMap { AgentKind.meaningfulID($0) }
        let explicitID: String? = forcedID ?? clipAgent

        var kind: AgentKind
        switch resolution {
        case .agent(let mapped):
            // Prefer catalog display names / colors for known ids — but not for
            // the container ids, or this re-flattens "Ghostty" back to
            // "Terminal" after resolve() has already made the right call.
            kind = AgentAppMapper.applyCatalogStyle(mapped)
        case .notAnAgent(let refusal):
            guard let explicitID, !explicitID.isEmpty else {
                return record(refusal: refusal, sourceApp: name ?? bid ?? "unknown")
            }
            kind = AgentKind(
                id: explicitID, displayName: refusal.label, source: "other", bundleHint: bid
            )
        }
        if let forcedID {
            let forced = AgentStyleCatalog.style(for: forcedID)
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
            // Terminals first: the evidence that matters is the process found
            // inside, not the window title of the emulator hosting it.
            if let terminal, !terminal.isEmpty {
                let host = terminal.emulatorName.isEmpty
                    ? (name ?? "Terminal") : terminal.emulatorName
                return "\(host) · \(terminal.executable) (pid \(terminal.pid))"
            }
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
                refusal: nil,
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
                refusal: nil,
                taskSummary: task,
                petPath: PetBootstrap.petsRoot.appendingPathComponent(kind.id).path,
                createdPet: false,
                gateNotified: false,
                sourceApp: sourceApp,
                message: "Failed to write pet: \(error.localizedDescription)"
            )
        }

        return publish(result)
    }

    /// A refused capture: no pet, no registry row, no gate message — but it is
    /// still surfaced (and highlighted) so the user gets an explanation instead
    /// of a silent no-op or a green checkmark for something that never happened.
    private func record(refusal: NonAgentApp, sourceApp: String) -> AgentIngestResult {
        publish(AgentIngestResult(
            agent: nil,
            refusal: refusal,
            taskSummary: "",
            petPath: "",
            createdPet: false,
            gateNotified: false,
            sourceApp: sourceApp,
            message: refusal.message
        ))
    }

    @discardableResult
    private func publish(_ result: AgentIngestResult) -> AgentIngestResult {
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

    /// Tell the gate about the capture over HTTP `POST /message`.
    ///
    /// Deliberately *not* the Unix-socket session. ⌘D is an OBSERVATION — "the
    /// user was looking at this app" — not a claim that an agent is connected and
    /// doing work. The socket path registers, which calls `upsert_agent` and
    /// writes connected_at, and then hangs up a millisecond later, writing
    /// disconnected_at. The row that comes back therefore reads
    /// "offline · last seen 0m" the instant the agent is captured, which is worse
    /// than saying nothing: `bootstrapPet` writes status "observed" and the
    /// companion moods gate `.alert` behind `AgentPresence.canBeBusy` precisely so
    /// that nothing claims liveness it cannot back up. A synthetic
    /// connect/disconnect pair undercuts all of it.
    ///
    /// `POST /message` runs the same gate evaluation and audit log but never
    /// touches the `agents` table (hub/shannon_gate.py calls `upsert_agent` only
    /// from the socket registration path), so the UI keeps the honest
    /// observation label. If the hub wants ⌘D-captured agents to be genuinely
    /// live it has to hold a connection open and keep `heartbeat_ns` beating,
    /// which is a daemon's job, not a keystroke's.
    ///
    /// Never throws; loopback-only, so a refused connection fails instantly and
    /// a wedged listener is bounded by the 200 ms receive timeout.
    static func notifyGateBestEffort(agentID: String, task: String) -> Bool {
        #if canImport(Darwin)
        let env = ProcessInfo.processInfo.environment
        let host = env["SHANNON_HTTP_HOST"] ?? "127.0.0.1"
        let port = UInt16(env["SHANNON_HTTP_PORT"] ?? "") ?? 8765

        let body: [String: Any] = [
            "agent_id": agentID,
            "task_id": "ingest",
            "message_type": "status",
            "payload": ["text": task, "event": "ingest", "source": "cmd_d"],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return false
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let converted = host.withCString { inet_addr($0) }
        guard converted != INADDR_NONE else { return false }
        addr.sin_addr.s_addr = converted

        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { return false }

        let head = """
        POST /message HTTP/1.1\r
        Host: \(host):\(port)\r
        Content-Type: application/json\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """
        var request = Array(head.utf8)
        request.append(contentsOf: payload)
        var offset = 0
        while offset < request.count {
            let sent = request[offset...].withUnsafeBufferPointer { buf in
                send(fd, buf.baseAddress, buf.count, 0)
            }
            guard sent > 0 else { return false }
            offset += sent
        }

        // The gate answers 200 with {"decision": …} and 403 with
        // {"error": "unknown_agent:…"} for an id outside VALID_AGENTS. Writing
        // bytes proves nothing, so wait for the verdict.
        var reply = [UInt8](repeating: 0, count: 2048)
        let received = recv(fd, &reply, reply.count, 0)
        guard received > 0,
              let text = String(bytes: reply[0..<received], encoding: .utf8) else {
            return false
        }
        return gateAccepted(httpResponse: text)
        #else
        return false
        #endif
    }

    /// Did the gate take the message? Pure, so the verdict is unit-tested
    /// without a live daemon.
    ///
    /// 200 with a `decision` is a yes — including `"decision": "blocked"`, which
    /// means the gate received and judged the message, exactly what we asked it
    /// to do. 403 `unknown_agent` is the interesting no: it means the id is
    /// outside `VALID_AGENTS`, which `hub/agent_identity.py` owns.
    nonisolated static func gateAccepted(httpResponse: String) -> Bool {
        guard let statusLine = httpResponse.split(
            separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false
        ).first else { return false }
        let fields = statusLine.split(separator: " ")
        guard fields.count >= 2, let code = Int(fields[1]) else { return false }
        guard (200..<300).contains(code) else { return false }
        // A 200 whose body still carries an "error" key is a refusal.
        guard let bodyStart = httpResponse.range(of: "\r\n\r\n") else { return true }
        let body = httpResponse[bodyStart.upperBound...]
        return !body.contains("\"error\"")
    }
}
