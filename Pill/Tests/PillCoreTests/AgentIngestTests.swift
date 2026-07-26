import XCTest
@testable import PillCore

final class AgentIngestTests: XCTestCase {

    func testSanitizeID() {
        XCTAssertEqual(AgentKind.sanitizeID("Claude Code"), "claude_code")
        XCTAssertEqual(AgentKind.sanitizeID("!!!"), "local_test")
        XCTAssertEqual(AgentKind.sanitizeID("Foo--Bar"), "foo_bar")
    }

    func testMapTerminals() throws {
        let t = try XCTUnwrap(AgentAppMapper.map(bundleID: "com.apple.Terminal", appName: "Terminal"))
        XCTAssertEqual(t.id, "terminal")
        XCTAssertEqual(t.source, "terminal")

        let i = try XCTUnwrap(AgentAppMapper.map(bundleID: "com.googlecode.iterm2", appName: "iTerm2"))
        XCTAssertEqual(i.id, "terminal")
    }

    // MARK: - Terminal contents (⌘D on a terminal must name the agent inside)

    func testTerminalContextResolvesToTheAgentRunningInside() throws {
        // Ghostty hosting `claude`: the capture must be Claude Code, not the
        // container. Previously every emulator collapsed to id "terminal", so
        // two CLI agents in two windows overwrote each other's pet.
        let inside = TerminalAgentProbe.Context(
            agentID: "claude_code", displayName: "Claude Code",
            executable: "claude", pid: 44534, emulatorName: "Ghostty"
        )
        let k = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty", terminal: inside
        ))
        XCTAssertEqual(k.id, "claude_code")
        XCTAssertEqual(k.displayName, "Claude Code")
        XCTAssertEqual(k.source, "terminal")
        XCTAssertEqual(k.bundleHint, "com.mitchellh.ghostty")
        XCTAssertEqual(AgentStyleCatalog.style(for: k.id).emoji, "🟠")
    }

    func testTwoTerminalsWithDifferentAgentsDoNotCollide() throws {
        let ghosttyGrok = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty",
            terminal: .init(agentID: "grok_build", displayName: "Grok Build",
                            executable: "grok", pid: 12182, emulatorName: "Ghostty")
        ))
        let itermCodex = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.googlecode.iterm2", appName: "iTerm2",
            terminal: .init(agentID: "codex", displayName: "Codex",
                            executable: "codex", pid: 777, emulatorName: "iTerm")
        ))
        XCTAssertEqual(ghosttyGrok.id, "grok_build")
        XCTAssertEqual(itermCodex.id, "codex")
        XCTAssertNotEqual(ghosttyGrok.id, itermCodex.id)
    }

    func testTerminalWithoutAnAgentKeepsTheEmulatorName() throws {
        // The regression this fixes: lines like ("com.mitchellh.ghostty", …
        // "Ghostty") were dead code because withCatalogStyle overwrote the label
        // with the catalog's generic "Terminal".
        let shellOnly = TerminalAgentProbe.Context(emulatorName: "Ghostty")
        let k = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty", terminal: shellOnly
        ))
        XCTAssertEqual(k.id, "terminal", "id must stay in the gate's allowlist")
        XCTAssertEqual(k.displayName, "Ghostty", "the emulator label must survive")
        // Icon + colour still come from the catalog, which keys off id.
        XCTAssertEqual(AgentStyleCatalog.style(for: k.id).systemImage, "terminal.fill")
    }

    func testTerminalNamesSurviveWithoutAProbe() throws {
        for (bid, label) in [
            ("com.mitchellh.ghostty", "Ghostty"),
            ("com.googlecode.iterm2", "iTerm"),
            ("dev.warp.warp-stable", "Warp"),
            ("net.kovidgoyal.kitty", "Kitty"),
            ("com.github.wez.wezterm", "WezTerm"),
        ] {
            let k = try XCTUnwrap(AgentAppMapper.map(bundleID: bid, appName: nil), bid)
            XCTAssertEqual(k.id, "terminal", bid)
            XCTAssertEqual(k.displayName, label, bid)
        }
    }

    func testTerminalWindowTitleNeverLeaksIntoBrowserDetection() throws {
        // A Ghostty window sitting in ~/Projects/claude-notes used to be matched
        // by BrowserAgentDetector's bare title.contains("claude") and registered
        // as Claude Code. Only the process probe is evidence for a terminal.
        let k = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty",
            page: BrowserPageContext(title: "~/Projects/claude-notes", url: ""),
            terminal: .init(emulatorName: "Ghostty")
        ))
        XCTAssertEqual(k.id, "terminal")
        XCTAssertNotEqual(k.id, "claude_code")
    }

    // MARK: - GUI bundle ids measured on this machine

    func testMapNativeClaudeCodeAndDevtoolsBundles() throws {
        // /…/Application Support/Claude/claude-code/*/claude.app
        XCTAssertEqual(
            AgentAppMapper.map(bundleID: "com.anthropic.claude-code", appName: nil)?.id,
            "claude_code"
        )
        // /Applications/claude-devtools.app — previously unmapped, so it minted
        // a bogus "claude_devtools" agent of its own.
        let devtools = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.claudecode.context", appName: "claude-devtools"
        ))
        XCTAssertEqual(devtools.id, "claude_code")
        XCTAssertEqual(devtools.displayName, "Claude Code")
    }

    func testMapDispatchByNameAndBundle() throws {
        // Dispatch ships with an unknown-to-us bundle id on some machines, so
        // the app name is the durable hook — and it must beat the generic
        // name.contains("claude") fallback.
        XCTAssertEqual(AgentAppMapper.map(bundleID: "", appName: "Dispatch")?.id, "dispatch")
        let claudeDispatch = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.example.unknown", appName: "Claude Dispatch"
        ))
        XCTAssertEqual(claudeDispatch.id, "dispatch")
        XCTAssertNotEqual(claudeDispatch.id, "claude_code")
        XCTAssertEqual(
            AgentAppMapper.map(bundleID: "com.anthropic.dispatch", appName: nil)?.id,
            "dispatch"
        )
        XCTAssertEqual(AgentStyleCatalog.style(for: "dispatch").systemImage, "paperplane.fill")
    }

    func testClaudeAdjacentUtilitiesAreNotAgents() throws {
        // "Usage for Claude.app" (com.ClaudeUsage) is a menu-bar meter. It used
        // to satisfy name.contains("claude") and steal the Claude Code identity;
        // the first fix moved the theft to `local_test`, which is a *real* gate
        // identity. The only honest answer is a refusal.
        let usage = AgentAppMapper.map(bundleID: "com.ClaudeUsage", appName: "Usage for Claude")
        XCTAssertNil(usage, "a menu-bar meter must not resolve to any agent")
        XCTAssertNotEqual(usage?.id, "claude_code")
        XCTAssertNotEqual(usage?.id, "local_test")

        let refusal = try XCTUnwrap(
            AgentAppMapper.resolve(bundleID: "com.ClaudeUsage", appName: "Usage for Claude").refusal
        )
        XCTAssertEqual(refusal.label, "Usage for Claude")
        XCTAssertTrue(refusal.message.contains("not an agent"), refusal.message)
    }

    // MARK: - Not an agent: refuse, never borrow someone else's identity

    /// `local_test` is not a junk drawer: `hub/agent_identity.py` IDENTITIES
    /// lists it, the gate derives VALID_AGENTS from that list, and
    /// `GateApprovalClient` registers as `local_test` to resolve approvals. So
    /// routing "not an agent" apps there overwrote a live agent's pet and posted
    /// a broadcast message in its name. System services must be refused instead.
    func testAppleSystemServicesAreRefusedNotAttributedToAnAgent() throws {
        for (bid, name) in [
            ("com.apple.windowmanager", "WindowManager"),
            ("com.apple.dock", "Dock"),
            ("com.apple.finder", "Finder"),
            ("com.apple.controlcenter", "ControlCenter"),
            ("com.apple.Spotlight", "Spotlight"),
        ] {
            XCTAssertNil(
                AgentAppMapper.map(bundleID: bid, appName: name),
                "\(bid) must not map to any agent id"
            )
            let resolution = AgentAppMapper.resolve(bundleID: bid, appName: name)
            XCTAssertFalse(resolution.isAgent, bid)
            let refusal = try XCTUnwrap(resolution.refusal, bid)
            // The mapper works in lowercase; the refusal quotes what it matched.
            XCTAssertEqual(refusal.bundleID, bid.lowercased())
            XCTAssertEqual(refusal.label, name)
            XCTAssertTrue(refusal.reason.contains("system service"), refusal.reason)
        }
    }

    /// The refusal must not swallow the com.apple.* apps that genuinely are
    /// agent surfaces — they are matched by explicit rules before it.
    func testAppleAppsThatAreRealAgentSurfacesStillResolve() throws {
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.apple.Terminal", appName: "Terminal")?.id, "terminal")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.apple.Safari", appName: "Safari")?.id, "browser")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.apple.dt.Xcode", appName: "Xcode")?.id, "xcode")
        // …and a system service hosting an agent CLI is still that agent.
        let inside = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.apple.Terminal", appName: "Terminal",
            terminal: .init(agentID: "codex", displayName: "Codex",
                            executable: "codex", pid: 999, emulatorName: "Terminal")
        ))
        XCTAssertEqual(inside.id, "codex")
    }

    func testAllMappedIDsAreAcceptedByTheGate() {
        // hub/shannon_gate.py derives VALID_AGENTS from agent_identity.IDENTITIES;
        // an id outside that set registers and is rejected.
        let gateValid: Set<String> = [
            "science", "grok_build", "claude_code", "design", "codex", "dispatch", "cowork",
            "chatgpt", "dataset_runner", "local_test", "terminal", "browser", "opencode",
            "cursor", "kimi", "vscode", "xcode",
        ]
        for rule in TerminalAgentProbe.rules {
            XCTAssertTrue(
                gateValid.contains(rule.agentID),
                "TerminalAgentProbe emits \(rule.agentID), which the gate would reject"
            )
        }
        // IDE agents must also be gate-valid (⌘D attach path).
        for id in ["grok_build", "cursor", "xcode"] {
            XCTAssertTrue(gateValid.contains(id), "\(id) must be gate-valid")
            XCTAssertTrue(AgentAppMapper.knownIDs.contains(id), "\(id) must be knownIDs")
        }
    }

    /// Grok Build, Cursor, and Xcode are first-class — never collapse into
    /// Claude Code / Science / each other.
    func testFirstClassGrokBuildCursorXcode() throws {
        // ── Grok Build (native app + terminal CLI + browser) ──────────────
        let grokApp = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.xai.grok", appName: "Grok"
        ))
        XCTAssertEqual(grokApp.id, "grok_build")
        XCTAssertEqual(grokApp.displayName, "Grok Build")
        XCTAssertNotEqual(grokApp.id, "science")

        let grokName = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.example.unsigned", appName: "SuperGrok"
        ))
        XCTAssertEqual(grokName.id, "grok_build")

        let grokTerm = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty",
            terminal: .init(
                agentID: "grok_build", displayName: "Grok Build",
                executable: "grok", pid: 42, emulatorName: "Ghostty"
            )
        ))
        XCTAssertEqual(grokTerm.id, "grok_build")
        XCTAssertEqual(TerminalAgentProbe.classify(executable: "grok")?.agentID, "grok_build")

        let grokStyle = AgentStyleCatalog.style(for: "grok_build")
        XCTAssertEqual(grokStyle.displayName, "Grok Build")
        XCTAssertEqual(grokStyle.systemImage, "sparkles")
        XCTAssertEqual(grokStyle.emoji, "🟣")

        // ── Cursor (ToDesktop prefix + name) ───────────────────────────────
        let cursor = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor"
        ))
        XCTAssertEqual(cursor.id, "cursor")
        XCTAssertEqual(cursor.displayName, "Cursor")
        XCTAssertNotEqual(cursor.id, "claude_code")
        XCTAssertNotEqual(cursor.id, "vscode")

        let cursorName = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.example.unknown", appName: "Cursor"
        ))
        XCTAssertEqual(cursorName.id, "cursor")

        let cursorStyle = AgentStyleCatalog.style(for: "cursor")
        XCTAssertEqual(cursorStyle.displayName, "Cursor")
        XCTAssertEqual(cursorStyle.systemImage, "cursorarrow.rays")

        // ── Xcode (must not be Claude Code) ────────────────────────────────
        let xcode = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.apple.dt.Xcode", appName: "Xcode"
        ))
        XCTAssertEqual(xcode.id, "xcode")
        XCTAssertEqual(xcode.displayName, "Xcode")
        XCTAssertNotEqual(xcode.id, "claude_code", "Xcode must never map to Claude Code")
        XCTAssertNotEqual(xcode.id, "vscode", "Xcode must never map to VS Code")
        XCTAssertNotEqual(xcode.id, "science")

        let xcodeName = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.example.unknown", appName: "Xcode"
        ))
        XCTAssertEqual(xcodeName.id, "xcode")
        XCTAssertNotEqual(xcodeName.id, "vscode")

        let xcodeStyle = AgentStyleCatalog.style(for: "xcode")
        XCTAssertEqual(xcodeStyle.displayName, "Xcode")
        XCTAssertEqual(xcodeStyle.systemImage, "hammer.fill")
        XCTAssertEqual(xcodeStyle.emoji, "🛠️")

        // Distinct brand cues across the three.
        XCTAssertNotEqual(grokStyle.systemImage, cursorStyle.systemImage)
        XCTAssertNotEqual(grokStyle.systemImage, xcodeStyle.systemImage)
        XCTAssertNotEqual(cursorStyle.systemImage, xcodeStyle.systemImage)
        XCTAssertNotEqual(grokStyle.emoji, xcodeStyle.emoji)
    }

    /// Claude Design must not collapse into Claude Code (name, bundle, terminal, tab).
    func testMapClaudeDesignNotClaudeCode() throws {
        let byName = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.example.unknown", appName: "Claude Design"
        ))
        XCTAssertEqual(byName.id, "design")
        XCTAssertEqual(byName.displayName, "Claude Design")
        XCTAssertNotEqual(byName.id, "claude_code")

        XCTAssertEqual(
            AgentAppMapper.map(bundleID: "com.anthropic.claude-design", appName: nil)?.id,
            "design"
        )
        XCTAssertEqual(
            AgentAppMapper.map(bundleID: "com.anthropic.claudedesign", appName: "Design")?.id,
            "design"
        )

        let inTerm = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty",
            terminal: .init(
                agentID: "design", displayName: "Claude Design",
                executable: "claude-design", pid: 4242, emulatorName: "Ghostty"
            )
        ))
        XCTAssertEqual(inTerm.id, "design")

        let tab = try XCTUnwrap(BrowserAgentDetector.detect(page: .init(
            title: "Claude Design", url: "https://claude.ai/design/project"
        )))
        XCTAssertEqual(tab.id, "design")

        // Science still wins when both words appear as science product.
        let sci = try XCTUnwrap(BrowserAgentDetector.detect(page: .init(
            title: "Claude Science", url: "https://claude.com/science"
        )))
        XCTAssertEqual(sci.id, "science")

        XCTAssertEqual(AgentStyleCatalog.style(for: "design").systemImage, "paintpalette.fill")
        XCTAssertEqual(AgentStyleCatalog.style(for: "design").emoji, "🎨")
    }

    func testMapChatAgents() {
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.openai.chat", appName: "ChatGPT")?.id, "chatgpt")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.anthropic.claudefordesktop", appName: "Claude")?.id, "claude_code")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.openai.codex", appName: "Codex")?.id, "codex")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.xai.grok", appName: "Grok")?.id, "grok_build")
        XCTAssertEqual(
            AgentAppMapper.map(bundleID: "com.xai.grok", appName: "Grok")?.displayName,
            "Grok Build"
        )
    }

    func testBrowserTabClaudeScienceNotGrok() throws {
        let science = BrowserPageContext(
            title: "Claude Science — FlexAID docking",
            url: "https://claude.ai/chat/abc"
        )
        let k = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.google.chrome",
            appName: "Google Chrome",
            page: science
        ))
        XCTAssertEqual(k.id, "science")
        XCTAssertEqual(k.displayName, "Claude Science")
        let style = AgentStyleCatalog.style(for: k.id)
        XCTAssertEqual(style.systemImage, "flask.fill")
        XCTAssertEqual(style.emoji, "🔬")
        // Amber brand (not purple Grok)
        XCTAssertGreaterThan(style.red, 0.9)
        XCTAssertLessThan(style.blue, 0.3)
    }

    func testNativeClaudeScienceAppNotClaudeCode() throws {
        // Real macOS bundle: /Applications/Claude Science.app → com.anthropic.operon
        let k = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.anthropic.operon",
            appName: "Claude Science"
        ))
        XCTAssertEqual(k.id, "science")
        XCTAssertEqual(k.displayName, "Claude Science")
        XCTAssertEqual(AgentStyleCatalog.style(for: k.id).systemImage, "flask.fill")

        // Name-only (unsigned / shifted bundle)
        let byName = try XCTUnwrap(
            AgentAppMapper.map(bundleID: "com.example.unknown", appName: "Claude Science")
        )
        XCTAssertEqual(byName.id, "science")
        // Must NOT collapse to generic Claude Code
        XCTAssertNotEqual(byName.id, "claude_code")
    }

    func testBrowserClaudeComScienceProductURL() {
        let k = BrowserAgentDetector.detect(page: BrowserPageContext(
            title: "Claude Science",
            url: "https://claude.com/science"
        ))
        XCTAssertEqual(k?.id, "science")
        let product = BrowserAgentDetector.detect(page: BrowserPageContext(
            title: "Get started",
            url: "https://claude.com/product/claude-science"
        ))
        XCTAssertEqual(product?.id, "science")
    }

    func testBrowserTabSuperGrokNotScience() throws {
        let grok = BrowserPageContext(
            title: "SuperGrok",
            url: "https://grok.x.ai/"
        )
        let k = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            page: grok
        ))
        XCTAssertEqual(k.id, "grok_build")
        XCTAssertEqual(k.displayName, "Grok Build")
        let style = AgentStyleCatalog.style(for: k.id)
        XCTAssertEqual(style.systemImage, "sparkles")
        XCTAssertEqual(style.emoji, "🟣")
        // Distinct colours: Science amber ≠ Grok purple
        let sci = AgentStyleCatalog.style(for: "science")
        let grk = AgentStyleCatalog.style(for: "grok_build")
        XCTAssertNotEqual(sci.red, grk.red)
        XCTAssertNotEqual(sci.systemImage, grk.systemImage)
        XCTAssertNotEqual(sci.emoji, grk.emoji)
        XCTAssertGreaterThan(grk.blue, 0.8)
    }

    func testStyleCatalogScienceVsGrokDistinct() {
        let pairs: [(String, String, String)] = [
            ("science", "flask.fill", "🔬"),
            ("grok_build", "sparkles", "🟣"),
            ("claude_code", "bubble.left.and.bubble.right.fill", "🟠"),
            ("codex", "chevron.left.forwardslash.chevron.right", "🔵"),
            ("dispatch", "paperplane.fill", "🟤"),
            ("cowork", "person.2.fill", "🟢"),
        ]
        var seenImages = Set<String>()
        for (id, image, emoji) in pairs {
            let s = AgentStyleCatalog.style(for: id)
            XCTAssertEqual(s.systemImage, image, id)
            XCTAssertEqual(s.emoji, emoji, id)
            XCTAssertFalse(seenImages.contains(s.systemImage), "duplicate icon for \(id)")
            seenImages.insert(s.systemImage)
        }
        // Science vs Grok must never share palette
        let sci = AgentStyleCatalog.style(for: "science")
        let grk = AgentStyleCatalog.style(for: "grok_build")
        XCTAssertNotEqual(sci.red, grk.red)
        XCTAssertNotEqual(sci.blue, grk.blue)
        XCTAssertNotEqual(sci.systemImage, grk.systemImage)
    }

    func testBrowserTabChatGPTAndCodex() throws {
        let gpt = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.google.chrome", appName: "Chrome",
            page: BrowserPageContext(title: "ChatGPT", url: "https://chatgpt.com/")
        ))
        XCTAssertEqual(gpt.id, "chatgpt")
        let codex = try XCTUnwrap(AgentAppMapper.map(
            bundleID: "com.google.chrome", appName: "Chrome",
            page: BrowserPageContext(title: "Codex", url: "https://chatgpt.com/codex")
        ))
        XCTAssertEqual(codex.id, "codex")
    }

    func testBrowserDetectorScienceURL() {
        let k = BrowserAgentDetector.detect(page: BrowserPageContext(
            title: "Project notes",
            url: "https://claude.ai/project/science-flexaid"
        ))
        XCTAssertEqual(k?.id, "science")
    }

    func testBrowserDetectorGrokXCom() {
        let k = BrowserAgentDetector.detect(page: BrowserPageContext(
            title: "Grok / X",
            url: "https://x.com/i/grok"
        ))
        XCTAssertEqual(k?.id, "grok_build")
    }

    func testMapBrowsersAndIDE() throws {
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.apple.Safari", appName: "Safari")?.id, "browser")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.google.Chrome", appName: "Chrome")?.id, "browser")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.microsoft.VSCode", appName: "Code")?.id, "vscode")
        let cursor = try XCTUnwrap(
            AgentAppMapper.map(bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor")
        )
        XCTAssertEqual(cursor.id, "cursor")
    }

    func testNameFallbackWhenBundleUnknown() throws {
        let k = try XCTUnwrap(AgentAppMapper.map(bundleID: "com.example.unknown", appName: "Claude"))
        XCTAssertEqual(k.id, "claude_code")
    }

    // MARK: - Gate notification (observation, not a connection)

    func testGateVerdictParsing() {
        let ok = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        \r
        {"decision": "allowed", "gate_H": 0.0}
        """
        XCTAssertTrue(AgentIngestService.gateAccepted(httpResponse: ok))

        // "blocked" still means the gate received and judged the message.
        let blocked = """
        HTTP/1.1 200 OK\r
        \r
        {"decision": "blocked", "reasons": ["H"]}
        """
        XCTAssertTrue(AgentIngestService.gateAccepted(httpResponse: blocked))

        // An id outside hub/agent_identity.py IDENTITIES.
        let refused = """
        HTTP/1.1 403 Forbidden\r
        \r
        {"error": "unknown_agent:claude_devtools"}
        """
        XCTAssertFalse(AgentIngestService.gateAccepted(httpResponse: refused))

        let malformed = """
        HTTP/1.1 200 OK\r
        \r
        {"error": "invalid_json"}
        """
        XCTAssertFalse(AgentIngestService.gateAccepted(httpResponse: malformed))

        XCTAssertFalse(AgentIngestService.gateAccepted(httpResponse: ""))
        XCTAssertFalse(AgentIngestService.gateAccepted(httpResponse: "garbage"))
    }

    /// End-to-end against the running gate. Opt-in via SHANNON_LIVE_GATE=1
    /// because it posts a real message to the hub's audit log; the assertion
    /// that matters is made by the caller, who diffs the `agents` table around
    /// it and must see no new connect/disconnect pair.
    @MainActor
    func testLiveGatePostIsAnObservationNotAConnection() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SHANNON_LIVE_GATE"] == "1",
            "set SHANNON_LIVE_GATE=1 to exercise the running gate"
        )
        let ok = AgentIngestService.notifyGateBestEffort(
            agentID: "claude_code", task: "ingest probe verification"
        )
        print("LIVE GATE accepted=\(ok.accepted) detail=\(ok.detail)")
        XCTAssertTrue(ok.accepted, "gate must accept a POST /message observation")

        // An id outside hub/agent_identity.py IDENTITIES must be refused, not
        // silently reported as healthy.
        let bogus = AgentIngestService.notifyGateBestEffort(
            agentID: "claude_devtools", task: "should be refused"
        )
        print("LIVE GATE bogus accepted=\(bogus.accepted) detail=\(bogus.detail)")
        XCTAssertFalse(bogus.accepted, "unknown agent ids must fail closed")
    }

    func testClipboardAgentOverride() {
        let (id, task) = AgentAppMapper.parseClipboard("agent: science fix CF.com floor")
        XCTAssertEqual(id, "science")
        XCTAssertEqual(task, "fix CF.com floor")
    }

    func testClipboardBareTask() {
        let (id, task) = AgentAppMapper.parseClipboard("dock 1G9V with soft beta")
        XCTAssertNil(id)
        XCTAssertEqual(task, "dock 1G9V with soft beta")
    }

    func testClipboardEmpty() {
        let (id, task) = AgentAppMapper.parseClipboard("   \n  ")
        XCTAssertNil(id)
        XCTAssertNil(task)
    }

    func testEnsurePetCreatesLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Point home via env is process-global; call ensure on absolute path by
        // writing through the public API then verifying structure under default
        // home would pollute ~/.shannon. Instead test sanitize + write helpers
        // by creating the same layout manually with PetBootstrap after chdir-like
        // SHANNON_LOG_DIR.
        let old = ProcessInfo.processInfo.environment["SHANNON_LOG_DIR"]
        setenv("SHANNON_LOG_DIR", root.path, 1)
        defer {
            if let old { setenv("SHANNON_LOG_DIR", old, 1) }
            else { unsetenv("SHANNON_LOG_DIR") }
        }

        let (url, created) = try PetBootstrap.ensurePet(
            agentID: "terminal", displayName: "Terminal", task: "test task"
        )
        XCTAssertTrue(created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("state.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("memory.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("history.jsonl").path))

        let (_, created2) = try PetBootstrap.ensurePet(
            agentID: "terminal", displayName: "Terminal", task: "again"
        )
        XCTAssertFalse(created2)

        PetBootstrap.updateRegistry(
            agent: AgentKind(id: "terminal", displayName: "Terminal", source: "terminal"),
            task: "again"
        )
        let reg = PetBootstrap.listRegistry()
        XCTAssertEqual(reg.first?["id"] as? String, "terminal")
    }

    /// Re-⌘D without a new pid must not wipe process-attach evidence (stickiness).
    func testEnsurePetPreservesAttachEvidenceOnMerge() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-attach-merge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = ProcessInfo.processInfo.environment["SHANNON_LOG_DIR"]
        setenv("SHANNON_LOG_DIR", root.path, 1)
        defer {
            if let old { setenv("SHANNON_LOG_DIR", old, 1) }
            else { unsetenv("SHANNON_LOG_DIR") }
        }

        let (url, _) = try PetBootstrap.ensurePet(
            agentID: "grok_build",
            displayName: "Grok Build",
            task: "first",
            attachPid: 12345,
            attachBundle: "com.mitchellh.ghostty"
        )
        // Second write without attach fields — must merge prior pid/bundle.
        _ = try PetBootstrap.ensurePet(
            agentID: "grok_build",
            displayName: "Grok Build",
            task: "second"
        )
        let data = try Data(contentsOf: url.appendingPathComponent("state.json"))
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(obj["attach_pid"] as? Int, 12345)
        XCTAssertEqual(obj["attach_bundle"] as? String, "com.mitchellh.ghostty")
        XCTAssertEqual(obj["last_task"] as? String, "second")
    }

    // MARK: - Capture path: a refusal must write nothing at all

    /// Redirect `~/.shannon` into a temp dir and point the gate notifier at a
    /// dead port, so a capture in a test can neither touch the real pets nor
    /// reach the running hub.
    @MainActor
    private func withIsolatedShannonHome(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-ingest-test-\(UUID().uuidString)", isDirectory: true)
        let oldHome = ProcessInfo.processInfo.environment["SHANNON_LOG_DIR"]
        let oldPort = ProcessInfo.processInfo.environment["SHANNON_HTTP_PORT"]
        setenv("SHANNON_LOG_DIR", root.path, 1)
        setenv("SHANNON_HTTP_PORT", "65533", 1)   // nothing listens there
        defer {
            if let oldHome { setenv("SHANNON_LOG_DIR", oldHome, 1) }
            else { unsetenv("SHANNON_LOG_DIR") }
            if let oldPort { setenv("SHANNON_HTTP_PORT", oldPort, 1) }
            else { unsetenv("SHANNON_HTTP_PORT") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    /// ⌘D while WindowManager/Dock/Finder holds focus. The capture must refuse:
    /// no pet, no registry row, no gate message, and — the reason this defect
    /// mattered — `local_test`'s own records must come back byte-identical,
    /// because that id is a live gate identity, not a spare slot.
    @MainActor
    func testCapturingASystemServiceIsRefusedAndLeavesLocalTestAlone() throws {
        for (bid, appName) in [
            ("com.apple.windowmanager", "WindowManager"),
            ("com.apple.dock", "Dock"),
            ("com.apple.finder", "Finder"),
        ] {
            try withIsolatedShannonHome { _ in
                // Seed local_test the way the gate's own identity has it.
                let (petDir, _) = try PetBootstrap.ensurePet(
                    agentID: "local_test", displayName: "Local Test", task: "approve gate asks"
                )
                PetBootstrap.updateRegistry(
                    agent: AgentKind(id: "local_test", displayName: "Local Test", source: "other"),
                    task: "approve gate asks"
                )
                let stateURL = petDir.appendingPathComponent("state.json")
                let historyURL = petDir.appendingPathComponent("history.jsonl")
                let stateBefore = try Data(contentsOf: stateURL)
                let historyBefore = try Data(contentsOf: historyURL)
                let registryBefore = try Data(contentsOf: PetBootstrap.registryURL)

                let service = AgentIngestService()
                let result = service.capture(
                    bundleID: bid, appName: appName, clipboardText: ""
                )

                XCTAssertFalse(result.captured, "\(bid) is not an agent")
                XCTAssertNil(result.agent, bid)
                XCTAssertEqual(result.refusal?.bundleID, bid)
                XCTAssertEqual(result.refusal?.label, appName)
                XCTAssertTrue(result.message.contains("not an agent"), result.message)
                XCTAssertEqual(result.petPath, "", "a refusal has no pet")
                XCTAssertFalse(result.gateNotified, "a refusal tells the gate nothing")
                XCTAssertEqual(result.pillLabel, "⊘ not an agent")
                XCTAssertEqual(service.lastResult?.captured, false)

                // No pet minted for the system service…
                let pets = try FileManager.default
                    .contentsOfDirectory(atPath: PetBootstrap.petsRoot.path)
                XCTAssertEqual(pets.sorted(), ["local_test"], "\(bid) minted a pet")
                // …and local_test's own records are untouched.
                XCTAssertEqual(try Data(contentsOf: stateURL), stateBefore,
                               "\(bid) rewrote local_test's state.json")
                XCTAssertEqual(try Data(contentsOf: historyURL), historyBefore,
                               "\(bid) appended to local_test's history")
                XCTAssertEqual(try Data(contentsOf: PetBootstrap.registryURL), registryBefore,
                               "\(bid) rewrote the agent registry")
            }
        }
    }

    /// The refusal must not cost real captures anything.
    @MainActor
    func testCapturingARealAgentAppStillWritesItsPet() throws {
        try withIsolatedShannonHome { _ in
            let service = AgentIngestService()
            let result = service.capture(
                bundleID: "com.anthropic.claude-code", appName: "Claude Code",
                clipboardText: ""
            )
            XCTAssertTrue(result.captured)
            XCTAssertEqual(result.agent?.id, "claude_code")
            XCTAssertEqual(result.pillLabel, "+Claude Code")
            XCTAssertNil(result.refusal)
            XCTAssertTrue(result.createdPet)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: PetBootstrap.petsRoot
                    .appendingPathComponent("claude_code/state.json").path
            ))
            XCTAssertEqual(PetBootstrap.listRegistry().first?["id"] as? String, "claude_code")
        }
    }

    /// A user who *types* `agent: science` has named an identity, which outranks
    /// whatever happens to be frontmost. A plain clipboard task has not.
    @MainActor
    func testOnlyAnExplicitAgentIDOverridesARefusal() throws {
        try withIsolatedShannonHome { _ in
            let service = AgentIngestService()
            let named = service.capture(
                bundleID: "com.apple.dock", appName: "Dock",
                clipboardText: "agent: science recheck CF floor"
            )
            XCTAssertTrue(named.captured)
            XCTAssertEqual(named.agent?.id, "science")
            XCTAssertEqual(named.taskSummary, "recheck CF floor")

            let plain = service.capture(
                bundleID: "com.apple.dock", appName: "Dock",
                clipboardText: "recheck CF floor"
            )
            XCTAssertFalse(plain.captured, "a bare task is not an identity claim")
            XCTAssertNil(plain.agent)
        }
    }

    // MARK: - The same borrowed identity, reached by the branches the refusal missed

    /// The refusal only covered `com.apple.*` and the Claude-adjacent bundles.
    /// The unknown-app fallback still *spelled* `local_test`: an app that has no
    /// bundle id and no usable name (or a name that sanitises away entirely) was
    /// handed the gate's live `local_test` identity, with exactly the same
    /// consequences the refusal was written to prevent — its `state.json` is
    /// rewritten, its `history.jsonl` appended to, and a status message is POSTed
    /// to the gate in its name.
    func testAnUnidentifiableAppIsRefusedNotHandedLocalTest() throws {
        for (bid, name) in [(nil, nil), ("", ""), ("", nil), (nil, "   "), ("com.example.weird", "•••")]
            as [(String?, String?)] {
            let label = "\(bid ?? "nil")/\(name ?? "nil")"
            XCTAssertNil(
                AgentAppMapper.map(bundleID: bid, appName: name),
                "\(label) borrowed a live gate identity instead of being refused"
            )
            let resolution = AgentAppMapper.resolve(bundleID: bid, appName: name)
            XCTAssertNotEqual(resolution.agent?.id, "local_test", label)
            XCTAssertNotNil(resolution.refusal, label)
        }
        // A name that survives sanitising is still its own pet, as before.
        XCTAssertEqual(
            AgentAppMapper.map(bundleID: "", appName: "Some Tool")?.id, "some_tool"
        )
    }

    @MainActor
    func testCapturingAnUnidentifiableAppLeavesLocalTestAlone() throws {
        try withIsolatedShannonHome { _ in
            let (petDir, _) = try PetBootstrap.ensurePet(
                agentID: "local_test", displayName: "Local Test", task: "approve gate asks"
            )
            let stateURL = petDir.appendingPathComponent("state.json")
            let historyURL = petDir.appendingPathComponent("history.jsonl")
            let stateBefore = try Data(contentsOf: stateURL)
            let historyBefore = try Data(contentsOf: historyURL)

            let service = AgentIngestService()
            let result = service.capture(bundleID: nil, appName: nil, clipboardText: "")

            XCTAssertFalse(result.captured, "an app with no identity is not an agent")
            XCTAssertNil(result.agent)
            XCTAssertEqual(result.petPath, "")
            XCTAssertEqual(try Data(contentsOf: stateURL), stateBefore,
                           "an unidentified app rewrote local_test's state.json")
            XCTAssertEqual(try Data(contentsOf: historyURL), historyBefore,
                           "an unidentified app appended to local_test's history")
        }
    }

    /// `AgentKind.sanitizeID` answers `local_test` for anything that sanitises to
    /// nothing, so `agent: ***` in the clipboard (or a junk `forceAgentID`) was
    /// promoted to a *live gate identity* and used to override a refusal — the
    /// override that exists for `agent: science` also let punctuation through.
    @MainActor
    func testJunkExplicitIDsCannotBorrowALiveGateIdentity() throws {
        XCTAssertNil(AgentAppMapper.parseClipboard("agent: ***").agentID,
                     "punctuation is not an identity claim")
        try withIsolatedShannonHome { _ in
            let service = AgentIngestService()
            let clip = service.capture(
                bundleID: "com.apple.dock", appName: "Dock", clipboardText: "agent: ***"
            )
            XCTAssertNotEqual(clip.agent?.id, "local_test")
            XCTAssertFalse(clip.captured, "junk in the clipboard is not an identity claim")

            let forced = service.capture(
                bundleID: "com.apple.dock", appName: "Dock", clipboardText: "",
                forceAgentID: "***"
            )
            XCTAssertNotEqual(forced.agent?.id, "local_test")
            XCTAssertFalse(forced.captured)

            // The real override still works.
            let named = service.capture(
                bundleID: "com.apple.dock", appName: "Dock", clipboardText: "",
                forceAgentID: "science"
            )
            XCTAssertEqual(named.agent?.id, "science")
        }
    }

    /// ⌘D never calls `resolve` without page context: `captureFromFrontApp`
    /// probes a CGWindowList window title for *every* non-browser app, and
    /// `BrowserAgentDetector` matches on bare title substrings. So a Finder
    /// window on `~/Projects/claude-notes` was resolved to `claude_code` —
    /// the browser branch runs before the system-service refusal — and the
    /// capture rewrote the real Claude Code pet and posted to the gate in its
    /// name. This is the same leak the terminal probe already guards against
    /// (`testTerminalWindowTitleNeverLeaksIntoBrowserDetection`).
    func testAWindowTitleCannotHandARefusedAppSomeoneElsesIdentity() throws {
        let cases: [(String, String, String)] = [
            ("com.apple.finder", "Finder", "claude-notes"),
            ("com.apple.finder", "Finder", "Claude Science"),
            ("com.apple.Spotlight", "Spotlight", "ChatGPT"),
            ("com.ClaudeUsage", "Usage for Claude", "Claude"),
        ]
        for (bid, name, title) in cases {
            let resolution = AgentAppMapper.resolve(
                bundleID: bid, appName: name,
                page: BrowserPageContext(title: title, url: "")
            )
            XCTAssertNil(resolution.agent,
                         "\(bid) titled \"\(title)\" was given \(resolution.agent?.id ?? "-")")
            XCTAssertNotNil(resolution.refusal, bid)
        }

        // …while a real browser still resolves from a title alone.
        XCTAssertEqual(
            AgentAppMapper.map(
                bundleID: "com.google.chrome", appName: "Chrome",
                page: BrowserPageContext(title: "Claude Science — FlexAID", url: "")
            )?.id,
            "science"
        )
        // …and a terminal inside a system-owned emulator is still that agent.
        XCTAssertEqual(
            AgentAppMapper.map(
                bundleID: "com.apple.Terminal", appName: "Terminal",
                page: BrowserPageContext(title: "claude-notes", url: ""),
                terminal: .init(agentID: "codex", displayName: "Codex",
                                executable: "codex", pid: 4242, emulatorName: "Terminal")
            )?.id,
            "codex"
        )
    }

    @MainActor
    func testCapturingFinderOnAClaudeFolderLeavesClaudeCodeAlone() throws {
        try withIsolatedShannonHome { _ in
            let (petDir, _) = try PetBootstrap.ensurePet(
                agentID: "claude_code", displayName: "Claude Code", task: "ship the gate fix"
            )
            let stateURL = petDir.appendingPathComponent("state.json")
            let historyURL = petDir.appendingPathComponent("history.jsonl")
            let stateBefore = try Data(contentsOf: stateURL)
            let historyBefore = try Data(contentsOf: historyURL)

            let service = AgentIngestService()
            let result = service.capture(
                bundleID: "com.apple.finder", appName: "Finder",
                page: BrowserPageContext(title: "claude-notes", url: ""),
                clipboardText: ""
            )

            XCTAssertFalse(result.captured, "Finder is not Claude Code")
            XCTAssertNil(result.agent)
            XCTAssertEqual(try Data(contentsOf: stateURL), stateBefore,
                           "a Finder capture rewrote claude_code's state.json")
            XCTAssertEqual(try Data(contentsOf: historyURL), historyBefore,
                           "a Finder capture appended to claude_code's history")
            XCTAssertEqual(PetBootstrap.listRegistry().count, 0,
                           "a refusal must not touch the registry")
        }
    }
}
