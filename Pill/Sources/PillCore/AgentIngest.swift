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
    /// Where the gate notification stands *for this capture*.
    ///
    /// `capture()` returns while the POST is still in flight off the main
    /// actor, so the value it hands back is `.pending` on the success path.
    /// `AgentIngestService` rewrites `lastResult`/`recent[0]` in place when the
    /// verdict lands (see `gateNotifyTask`), which republishes through
    /// `ObservableObject` and re-renders any view bound to `ingest.lastResult`.
    public var gateStatus: GateNotifyStatus
    public var sourceApp: String
    public var message: String

    /// True only once the gate has *confirmed* it took the message. `.pending`
    /// is deliberately false: a capture whose POST has not answered yet must
    /// never read as a notified gate.
    public var gateNotified: Bool { gateStatus == .accepted }

    /// True only when a pet was actually written for a real agent.
    public var captured: Bool { agent != nil }

    /// What the pill shows. The `+name` claims the *capture* (pet written,
    /// registry updated) — that part is confirmed synchronously and is not
    /// contingent on the gate. A gate refusal adds a visible marker, because a
    /// silent failure is the thing that lets a wedged gate go unnoticed; a
    /// pending POST adds nothing, because "not yet known" is not a failure.
    public var pillLabel: String {
        guard let agent else { return "⊘ not an agent" }
        switch gateStatus {
        case .refused: return "+\(agent.displayName) ⚠︎gate"
        case .accepted, .pending, .notAttempted: return "+\(agent.displayName)"
        }
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
        "claude_code", "cowork", "dispatch", "science", "design",
        "grok_build", "codex", "dataset_runner", "local_test",
        "chatgpt", "browser", "terminal", "cursor", "vscode", "opencode",
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
        // Claude Design BEFORE bare "claude" — same ordering as Dispatch/Science.
        if name == "design" || name.contains("claude design")
            || (name.contains("design") && name.contains("claude")) {
            return withCatalogStyle(
                .init(id: "design", displayName: "Claude Design", source: "chat"),
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
            // Claude Design BEFORE generic Claude / Code (same ordering as Science/Dispatch).
            ("com.anthropic.claudedesign", .init(id: "design", displayName: "Claude Design", source: "chat")),
            ("com.anthropic.claude-design", .init(id: "design", displayName: "Claude Design", source: "chat")),
            ("com.anthropic.claude.design", .init(id: "design", displayName: "Claude Design", source: "chat")),
            ("com.anthropic.design", .init(id: "design", displayName: "Claude Design", source: "chat")),
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
    ///
    /// - Parameters:
    ///   - attachPid: optional process id of the attached CLI / host app. When
    ///     set, each activity poll re-checks liveness so a quit process goes
    ///     offline instead of lingering as "seen" forever.
    ///   - attachBundle: optional host app bundle id for the same purpose.
    @discardableResult
    public static func ensurePet(
        agentID: String,
        displayName: String,
        task: String?,
        attachPid: Int32? = nil,
        attachBundle: String? = nil
    ) throws -> (URL, Bool) {
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
        // Process-attach evidence. AgentActivityReader re-checks pid/bundle each
        // poll: still running → presence **live** (attached); quit → offline.
        // Status on disk stays non-busy — only the gate may claim active work.
        var stateObj: [String: Any] = [
            "status": "observed",
            "source": "process",
            "last_task": task ?? "",
            "last_cf_delta": NSNull(),
            "memory_size": (try? Data(contentsOf: memory).count) ?? 0,
            "history_count": 0,
            "updated_at": now,
            "resumable": hasTask,
        ]
        if let attachPid, attachPid > 0 {
            stateObj["attach_pid"] = Int(attachPid)
        }
        if let attachBundle, !attachBundle.isEmpty {
            stateObj["attach_bundle"] = attachBundle
        }
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

    /// The in-flight gate notification for the most recent capture, or nil.
    ///
    /// Held so a rapid second ⌘D can cancel the first rather than queue another
    /// socket behind it. Awaiting `.value` is also how a caller (or a test) gets
    /// the *confirmed* verdict without polling a clock: when it completes,
    /// `lastResult.gateStatus` has left `.pending`.
    public private(set) var gateNotifyTask: Task<Void, Never>?

    /// Monotonic capture id. A verdict whose token no longer matches belongs to
    /// a superseded capture and is discarded rather than applied to a newer row.
    private var gateToken: UInt64 = 0

    private let gateNotifier: GateNotifier

    /// What performs one gate notification. Injected so tests can stand in a
    /// deterministic (blocking, refusing, accepting) notifier with no daemon,
    /// no socket and no clock.
    ///
    /// `env` is passed in rather than read by the notifier: the work now runs
    /// later, on another thread, and a notifier that read the *live* process
    /// environment would see whatever it had become by then. Snapshotting at
    /// dispatch time is what keeps the endpoint deterministic.
    public typealias GateNotifier = @Sendable (
        _ agentID: String, _ task: String, _ env: [String: String]
    ) -> GateNotifyOutcome

    /// The shipping notifier: bounded, off-actor, loopback-by-default HTTP POST.
    ///
    /// `nonisolated` so the default argument below is evaluable from any
    /// context and so this closure cannot quietly re-acquire main-actor
    /// isolation — the exact mistake being fixed.
    public nonisolated static let liveGateNotifier: GateNotifier = { agentID, task, env in
        AgentIngestService.notifyGateBestEffort(agentID: agentID, task: task, env: env)
    }

    public init(gateNotifier: @escaping GateNotifier = AgentIngestService.liveGateNotifier) {
        self.gateNotifier = gateNotifier
    }

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
        let hostPid = front?.processIdentifier
        #else
        let bid: String? = nil
        let name: String? = nil
        let page: BrowserPageContext? = nil
        let terminal: TerminalAgentProbe.Context? = nil
        let hostPid: Int32? = nil
        #endif

        return capture(
            bundleID: bid, appName: name, page: page, terminal: terminal,
            hostPid: hostPid,
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
        hostPid: Int32? = nil,
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
            // Prefer the terminal CLI pid (real agent process) over the host
            // app pid so tracking follows `claude`/`codex` under Ghostty.
            // For IDEs (Cursor / VS Code) use the host app pid so process-attach
            // can report **live** while the app is open.
            let attachPid: Int32? = {
                if let terminal, terminal.pid > 0 { return terminal.pid }
                if let hostPid, hostPid > 0 { return hostPid }
                return nil
            }()
            let (url, created) = try PetBootstrap.ensurePet(
                agentID: kind.id,
                displayName: kind.displayName,
                task: task,
                attachPid: attachPid,
                attachBundle: bid
            )
            PetBootstrap.updateRegistry(agent: kind, task: task)
            result = AgentIngestResult(
                agent: kind,
                refusal: nil,
                taskSummary: task,
                petPath: url.path,
                createdPet: created,
                gateStatus: .pending,
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
                gateStatus: .notAttempted,
                sourceApp: sourceApp,
                message: "Failed to write pet: \(error.localizedDescription)"
            )
        }

        let published = publish(result)
        // Dispatched AFTER publish, so `lastResult` and `recent[0]` already hold
        // the row the verdict will rewrite. Only the success path notifies: a
        // failed pet write has nothing honest to report to the gate.
        if published.gateStatus == .pending {
            startGateNotify(agentID: kind.id, task: task)
        }
        return published
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
            gateStatus: .notAttempted,
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

    /// Kick off the gate notification for a just-published capture.
    ///
    /// Off-actor by construction. `notifyGateBestEffort` does blocking BSD
    /// socket work, and doing that inside `capture()` — which is `@MainActor` —
    /// froze the UI for as long as the kernel took to answer. The pattern is
    /// `GateApprovalClient.resolveAsync`'s: `Task.detached`, "precisely to leave
    /// the caller's actor (usually @MainActor)".
    ///
    /// Rapid ⌘D cancels the previous notify rather than piling up sockets; a
    /// verdict whose token has been superseded is dropped instead of rewriting
    /// a newer capture's row.
    private func startGateNotify(agentID: String, task: String) {
        gateNotifyTask?.cancel()
        gateToken &+= 1
        let token = gateToken
        let notifier = gateNotifier
        // Snapshot HERE, synchronously, while we still are the ⌘D that read it.
        let env = ProcessInfo.processInfo.environment
        gateNotifyTask = Task.detached(priority: .utility) { [weak self] in
            if Task.isCancelled { return }
            // Nothing here touches actor-isolated state; that is the point.
            let outcome = notifier(agentID, task, env)
            if Task.isCancelled { return }
            guard let service = self else { return }
            await MainActor.run { service.applyGateOutcome(token: token, outcome: outcome) }
        }
    }

    /// Fold an asynchronous verdict back into the published capture.
    ///
    /// Rewrites the *same* row in `lastResult` and `recent[0]`, so the pill and
    /// any other `ObservableObject` observer re-render with the real answer.
    /// A plain acceptance says nothing (silence means it worked); a refusal —
    /// or an acceptance that only happened because the host policy is
    /// observe-only — appends its reason, and a refusal also puts `⚠︎gate` in
    /// `pillLabel`.
    ///
    /// Timing: the notify is bounded by `SHANNON_GATE_NOTIFY_TIMEOUT_MS`
    /// (250 ms default, 5 s ceiling) and `highlightUntil` runs for 8 s, so the
    /// verdict always lands while the pill is still showing this capture.
    private func applyGateOutcome(token: UInt64, outcome: GateNotifyOutcome) {
        guard token == gateToken else { return }          // a newer ⌘D owns the row
        guard var result = lastResult, result.gateStatus == .pending else { return }
        result.gateStatus = outcome.status
        if outcome.detail != GateNotifyOutcome.accepted.detail {
            result.message += " · gate: \(outcome.detail)"
        }
        lastResult = result
        if !recent.isEmpty { recent[0] = result }
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
    /// **`nonisolated` is load-bearing.** This blocks; it must be callable from
    /// a background executor without hopping to the main actor. Removing the
    /// keyword re-creates the freeze, and `AgentIngestTests` will stop
    /// compiling — deliberately.
    ///
    /// Never throws. Every failure path — disabled, unparseable endpoint,
    /// non-loopback under `enforce`, connect/send/recv timeout, oversized or
    /// unparseable reply, non-2xx, 2xx carrying an `"error"` key — returns
    /// `.refused` with a reason. There is no path that returns `.accepted`
    /// without a parsed 2xx response in hand.
    nonisolated static func notifyGateBestEffort(
        agentID: String,
        task: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        transport: GateNotifyTransport = .bsdSocket
    ) -> GateNotifyOutcome {
        let plan: GateNotifyPlan
        switch GateEndpointPolicy.resolve(env: env) {
        case .refuse(let why): return .refused(why)
        case .go(let p): plan = p
        }

        let body: [String: Any] = [
            "agent_id": agentID,
            "task_id": "ingest",
            "message_type": "status",
            "payload": ["text": task, "event": "ingest", "source": "cmd_d"],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .refused("could not encode the observation")
        }

        guard let text = transport.post(plan.endpoint, payload, plan.timeout) else {
            return .refused("no answer from \(plan.endpoint.host):\(plan.endpoint.port) "
                            + "within \(Int(plan.timeout * 1000)) ms")
        }
        guard gateAccepted(httpResponse: text) else {
            return .refused("gate rejected the observation")
        }
        if let note = plan.observeOnlyNote { return .init(status: .accepted, detail: note) }
        return .accepted
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

// MARK: - Gate notification: status, endpoint policy, transport
//
// OPERATOR SURFACE — every knob on the ⌘D gate-notification path.
//
//   SHANNON_GATE_NOTIFY            on (default) | off
//       Kill switch. "off"/"0"/"false"/"no" (case-insensitive) stops ⌘D from
//       contacting the gate at all. Captures still write the pet and the
//       registry; the pill shows "⚠︎gate" with the reason. Use this first if
//       the notify ever misbehaves — do not patch it out.
//
//   SHANNON_HTTP_HOST              127.0.0.1 (default)
//       IPv4 literal only. "localhost" is accepted as a literal alias for
//       127.0.0.1; nothing else is resolved, because a DNS lookup on the ⌘D
//       path is a stall waiting to happen. A hostname, an IPv6 address or any
//       unparseable value is REFUSED, not guessed.
//
//   SHANNON_HTTP_PORT              8765 (default)
//       1…65535. Unset or empty means the default. A value that is present but
//       not a valid port is REFUSED — a typo must not silently post the
//       observation to whatever happens to be on 8765.
//
//   SHANNON_GATE_HOST_POLICY       enforce (default) | observe
//       What to do when SHANNON_HTTP_HOST is not loopback. `enforce` refuses.
//       `observe` sends anyway and records "would be refused under enforce" in
//       the capture's message, so a deployment that suspects it depends on an
//       off-box gate can MEASURE that before the restriction bites.
//
//   SHANNON_GATE_ALLOW_REMOTE      unset (default) | 1
//       Permanent opt-in for a non-loopback gate. Set this when an off-box gate
//       is intended; `observe` is for finding out, this is for committing.
//
//   SHANNON_GATE_NOTIFY_TIMEOUT_MS 250 (default), clamped to 20…5000
//       Hard ceiling on the WHOLE notification — connect, send and receive
//       together, measured against one deadline. A value that is present but
//       unparseable is REFUSED rather than silently defaulted.

/// Where one ⌘D gate notification stands.
public enum GateNotifyStatus: String, Sendable, Equatable, CaseIterable {
    /// Nothing was sent and nothing will be — a refused capture, or a pet write
    /// that failed. Distinct from `.refused`: no claim was ever made.
    case notAttempted
    /// Dispatched off the main actor; the verdict has not come back yet.
    case pending
    /// The gate answered 2xx and the body carried no `"error"`.
    case accepted
    /// Everything else. Unreachable, timed out, disabled, policy-refused,
    /// malformed, or an explicit rejection. Always carries a reason.
    case refused
}

/// A verdict plus the one line an operator needs to act on it.
public struct GateNotifyOutcome: Sendable, Equatable {
    public var status: GateNotifyStatus
    public var detail: String

    public init(status: GateNotifyStatus, detail: String) {
        self.status = status
        self.detail = detail
    }

    /// True only for a parsed 2xx. Never true for `.pending`.
    public var accepted: Bool { status == .accepted }

    public static let accepted = GateNotifyOutcome(status: .accepted, detail: "accepted")
    public static func refused(_ why: String) -> GateNotifyOutcome {
        GateNotifyOutcome(status: .refused, detail: why)
    }
}

/// A validated IPv4 endpoint. Constructing one is the *only* way past the host
/// policy, so there is no path from a raw env string to a socket.
public struct GateEndpoint: Sendable, Equatable {
    /// Dotted-quad IPv4 literal, already proven parseable by `inet_pton`.
    public var host: String
    public var port: UInt16
    /// 127.0.0.0/8.
    public var isLoopback: Bool

    public init(host: String, port: UInt16, isLoopback: Bool) {
        self.host = host
        self.port = port
        self.isLoopback = isLoopback
    }
}

/// An approved notification: where to send it and how long it may take.
public struct GateNotifyPlan: Sendable, Equatable {
    public var endpoint: GateEndpoint
    /// Seconds. Bounds connect + send + recv against a single deadline.
    public var timeout: TimeInterval
    /// Non-nil when this plan survived only because the host policy is
    /// `observe`. The text is exactly what `enforce` would have refused with.
    public var observeOnlyNote: String?

    public init(endpoint: GateEndpoint, timeout: TimeInterval, observeOnlyNote: String? = nil) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.observeOnlyNote = observeOnlyNote
    }
}

/// Turns the environment into either a plan or a refusal. Pure — no sockets, no
/// DNS, no clock — so every branch is unit-tested on a clean machine.
public enum GateEndpointPolicy {
    public enum Resolution: Sendable, Equatable {
        case go(GateNotifyPlan)
        case refuse(String)
    }

    public static let defaultHost = "127.0.0.1"
    public static let defaultPort: UInt16 = 8765
    public static let defaultTimeoutMS = 250
    public static let minTimeoutMS = 20
    public static let maxTimeoutMS = 5000

    /// See the OPERATOR SURFACE block above for every variable read here.
    ///
    /// Fail-closed by construction: the function returns `.refuse` for a
    /// disabled switch, an empty/hostname/IPv6/garbage host, an unparseable
    /// port, an unparseable timeout, and a non-loopback host under the default
    /// `enforce` policy. `.go` is only reachable with a validated IPv4 literal.
    public static func resolve(env: [String: String]) -> Resolution {
        if let raw = env["SHANNON_GATE_NOTIFY"] {
            let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if ["off", "0", "false", "no"].contains(v) {
                return .refuse("disabled by SHANNON_GATE_NOTIFY=\(raw)")
            }
        }

        let timeoutMS: Int
        if let raw = env["SHANNON_GATE_NOTIFY_TIMEOUT_MS"]?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            guard let parsed = Int(raw) else {
                return .refuse("SHANNON_GATE_NOTIFY_TIMEOUT_MS=\(raw) is not a number")
            }
            timeoutMS = min(max(parsed, minTimeoutMS), maxTimeoutMS)
        } else {
            timeoutMS = defaultTimeoutMS
        }

        let port: UInt16
        if let raw = env["SHANNON_HTTP_PORT"]?.trimmingCharacters(in: .whitespaces),
           !raw.isEmpty {
            guard let parsed = UInt16(raw), parsed > 0 else {
                return .refuse("SHANNON_HTTP_PORT=\(raw) is not a port in 1…65535")
            }
            port = parsed
        } else {
            port = defaultPort
        }

        let rawHost = env["SHANNON_HTTP_HOST"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let host = rawHost.isEmpty ? defaultHost
            : (rawHost.lowercased() == "localhost" ? defaultHost : rawHost)
        guard let loopback = ipv4IsLoopback(host) else {
            return .refuse("SHANNON_HTTP_HOST=\(rawHost) is not an IPv4 literal "
                           + "(names are never resolved on this path)")
        }

        let endpoint = GateEndpoint(host: host, port: port, isLoopback: loopback)
        let timeout = TimeInterval(timeoutMS) / 1000.0
        if loopback { return .go(GateNotifyPlan(endpoint: endpoint, timeout: timeout)) }

        let complaint = "\(host) is not loopback; set SHANNON_GATE_ALLOW_REMOTE=1 to allow it"
        if truthy(env["SHANNON_GATE_ALLOW_REMOTE"]) {
            return .go(GateNotifyPlan(endpoint: endpoint, timeout: timeout))
        }
        let policy = (env["SHANNON_GATE_HOST_POLICY"] ?? "enforce")
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch policy {
        case "observe":
            return .go(GateNotifyPlan(
                endpoint: endpoint, timeout: timeout,
                observeOnlyNote: "observe-only: \(complaint)"
            ))
        case "enforce":
            return .refuse(complaint)
        default:
            // An unrecognised policy is not a licence to pick the permissive one.
            return .refuse("SHANNON_GATE_HOST_POLICY=\(policy) is not enforce|observe")
        }
    }

    private static func truthy(_ raw: String?) -> Bool {
        guard let v = raw?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(v)
    }

    /// `nil` when `host` is not a strict dotted-quad IPv4 literal.
    ///
    /// `inet_pton`, not `inet_addr`: `inet_addr` also accepts "10", "0x7f.1" and
    /// other legacy forms, which would let a typo become a *different* host.
    public static func ipv4IsLoopback(_ host: String) -> Bool? {
        #if canImport(Darwin)
        var addr = in_addr()
        let ok = host.withCString { inet_pton(AF_INET, $0, &addr) }
        guard ok == 1 else { return nil }
        return (UInt32(bigEndian: addr.s_addr) >> 24) == 127
        #else
        return nil
        #endif
    }
}

/// How the notification actually reaches the wire. Injected so a test can make
/// "the gate is blackholed" mean "this closure blocks", with no network at all.
public struct GateNotifyTransport: Sendable {
    /// Send `body` to `endpoint` and return the raw HTTP response text, or nil
    /// on any failure. MUST return within roughly `timeout` seconds.
    public var post: @Sendable (_ endpoint: GateEndpoint, _ body: Data, _ timeout: TimeInterval)
        -> String?

    public init(
        post: @escaping @Sendable (GateEndpoint, Data, TimeInterval) -> String?
    ) {
        self.post = post
    }

    /// The shipping transport: non-blocking fd + `poll(2)` against one deadline.
    public static let bsdSocket = GateNotifyTransport { endpoint, body, timeout in
        GateSocketIO.post(endpoint: endpoint, body: body, timeout: timeout)
    }

    /// Contacts nothing and always refuses. The fail-closed stand-in for tests
    /// and for any context that must not touch a live gate.
    public static let refuseAll = GateNotifyTransport { _, _, _ in nil }
}

/// The bounded socket client.
///
/// Exists because `SO_SNDTIMEO` does **not** bound `connect()` on Darwin: with
/// the option reading back as 0.200000 s, `connect()` to a blackholed address
/// still blocked for 75,000.3 ms — the `TCPTV_KEEP_INIT` default, not the socket
/// option. The only thing that bounds a connect here is a non-blocking fd plus
/// an explicit `poll(2)` deadline, which is what this does.
public enum GateSocketIO {
    /// Result of one readiness wait.
    public enum WaitOutcome: Sendable, Equatable {
        case ready
        case timedOut
        case failed(Int32)
    }

    /// Refuse a reply larger than this. A gate answering a status POST with
    /// more than this is not our gate, and we will not grow a buffer for it.
    public static let maxResponseBytes = 64 * 1024

    /// Block until `fd` is ready for `events`, or `deadline` passes.
    ///
    /// This is the mechanism the whole fix rests on, so it is tested directly
    /// against a pipe: an empty pipe is never readable, so the wait must return
    /// `.timedOut` at the deadline and not at some kernel default.
    /// `EINTR` is retried against the *remaining* budget, never a fresh one.
    public static func wait(fd: Int32, events: Int16, deadline: Date) -> WaitOutcome {
        #if canImport(Darwin)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timedOut }
            let ms = Int32(min(Double(Int32.max), (remaining * 1000).rounded(.up)))
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let rc = poll(&pfd, 1, ms)
            if rc > 0 { return .ready }
            if rc == 0 { return .timedOut }
            if errno == EINTR { continue }
            return .failed(errno)
        }
        #else
        return .failed(ENOTSUP)
        #endif
    }

    /// A TCP socket that is non-blocking from birth and will not raise SIGPIPE.
    ///
    /// The `O_NONBLOCK` is not decoration: without it `connect()` ignores every
    /// timeout we can set and the caller's thread is the kernel's to keep.
    public static func makeSocket() -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            return -1
        }
        var on: Int32 = 1
        // A half-closed gate must fail the send, not kill the app.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
        #else
        return -1
        #endif
    }

    /// One short-lived `POST /message`. Returns the raw response text, or nil on
    /// any failure — including the deadline expiring in connect, send or recv.
    public static func post(
        endpoint: GateEndpoint,
        body: Data,
        timeout: TimeInterval
    ) -> String? {
        #if canImport(Darwin)
        let deadline = Date().addingTimeInterval(timeout)
        let fd = makeSocket()
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        guard endpoint.host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            return nil
        }

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { return nil }
            // THE fix: a blackholed peer now costs `timeout`, not TCPTV_KEEP_INIT.
            guard wait(fd: fd, events: Int16(POLLOUT), deadline: deadline) == .ready else {
                return nil
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0, soError == 0 else {
                return nil
            }
        }

        let head = """
        POST /message HTTP/1.1\r
        Host: \(endpoint.host):\(endpoint.port)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var request = Array(head.utf8)
        request.append(contentsOf: body)
        var offset = 0
        while offset < request.count {
            let sent = request[offset...].withUnsafeBufferPointer { buf in
                send(fd, buf.baseAddress, buf.count, 0)
            }
            if sent > 0 { offset += sent; continue }
            guard sent < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return nil }
            guard wait(fd: fd, events: Int16(POLLOUT), deadline: deadline) == .ready else {
                return nil
            }
        }

        // The gate answers 200 with {"decision": …} and 403 with
        // {"error": "unknown_agent:…"} for an id outside VALID_AGENTS. Writing
        // bytes proves nothing, so wait for the verdict.
        var response = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let got = recv(fd, &chunk, chunk.count, 0)
            if got > 0 {
                response.append(contentsOf: chunk[0..<got])
                // Oversized reply: refuse rather than keep growing a buffer.
                if response.count > maxResponseBytes { return nil }
                if responseIsComplete(response) { break }
                continue
            }
            if got == 0 { break }   // peer closed — Connection: close
            guard errno == EAGAIN || errno == EWOULDBLOCK else { return nil }
            guard wait(fd: fd, events: Int16(POLLIN), deadline: deadline) == .ready else {
                return nil
            }
        }
        guard !response.isEmpty else { return nil }
        return String(bytes: response, encoding: .utf8)
        #else
        return nil
        #endif
    }

    /// Have we got the whole head, plus a `Content-Length` body if one was
    /// declared? Lets a well-behaved gate answer in one round trip instead of
    /// burning the remaining budget waiting for the peer to close.
    static func responseIsComplete(_ bytes: [UInt8]) -> Bool {
        guard let text = String(bytes: bytes, encoding: .utf8),
              let headEnd = text.range(of: "\r\n\r\n") else { return false }
        let head = text[text.startIndex..<headEnd.lowerBound]
        let bodyBytes = bytes.count - head.utf8.count - 4
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
                  let want = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            return bodyBytes >= want
        }
        return true
    }
}
