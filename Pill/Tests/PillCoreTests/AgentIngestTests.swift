import XCTest
@testable import PillCore

final class AgentIngestTests: XCTestCase {

    func testSanitizeID() {
        XCTAssertEqual(AgentKind.sanitizeID("Claude Code"), "claude_code")
        XCTAssertEqual(AgentKind.sanitizeID("!!!"), "local_test")
        XCTAssertEqual(AgentKind.sanitizeID("Foo--Bar"), "foo_bar")
    }

    func testMapTerminals() {
        let t = AgentAppMapper.map(bundleID: "com.apple.Terminal", appName: "Terminal")
        XCTAssertEqual(t.id, "terminal")
        XCTAssertEqual(t.source, "terminal")

        let i = AgentAppMapper.map(bundleID: "com.googlecode.iterm2", appName: "iTerm2")
        XCTAssertEqual(i.id, "terminal")
    }

    // MARK: - Terminal contents (⌘D on a terminal must name the agent inside)

    func testTerminalContextResolvesToTheAgentRunningInside() {
        // Ghostty hosting `claude`: the capture must be Claude Code, not the
        // container. Previously every emulator collapsed to id "terminal", so
        // two CLI agents in two windows overwrote each other's pet.
        let inside = TerminalAgentProbe.Context(
            agentID: "claude_code", displayName: "Claude Code",
            executable: "claude", pid: 44534, emulatorName: "Ghostty"
        )
        let k = AgentAppMapper.map(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty", terminal: inside
        )
        XCTAssertEqual(k.id, "claude_code")
        XCTAssertEqual(k.displayName, "Claude Code")
        XCTAssertEqual(k.source, "terminal")
        XCTAssertEqual(k.bundleHint, "com.mitchellh.ghostty")
        XCTAssertEqual(AgentStyleCatalog.style(for: k.id).emoji, "🟠")
    }

    func testTwoTerminalsWithDifferentAgentsDoNotCollide() {
        let ghosttyGrok = AgentAppMapper.map(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty",
            terminal: .init(agentID: "grok_build", displayName: "Grok Build",
                            executable: "grok", pid: 12182, emulatorName: "Ghostty")
        )
        let itermCodex = AgentAppMapper.map(
            bundleID: "com.googlecode.iterm2", appName: "iTerm2",
            terminal: .init(agentID: "codex", displayName: "Codex",
                            executable: "codex", pid: 777, emulatorName: "iTerm")
        )
        XCTAssertEqual(ghosttyGrok.id, "grok_build")
        XCTAssertEqual(itermCodex.id, "codex")
        XCTAssertNotEqual(ghosttyGrok.id, itermCodex.id)
    }

    func testTerminalWithoutAnAgentKeepsTheEmulatorName() {
        // The regression this fixes: lines like ("com.mitchellh.ghostty", …
        // "Ghostty") were dead code because withCatalogStyle overwrote the label
        // with the catalog's generic "Terminal".
        let shellOnly = TerminalAgentProbe.Context(emulatorName: "Ghostty")
        let k = AgentAppMapper.map(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty", terminal: shellOnly
        )
        XCTAssertEqual(k.id, "terminal", "id must stay in the gate's allowlist")
        XCTAssertEqual(k.displayName, "Ghostty", "the emulator label must survive")
        // Icon + colour still come from the catalog, which keys off id.
        XCTAssertEqual(AgentStyleCatalog.style(for: k.id).systemImage, "terminal.fill")
    }

    func testTerminalNamesSurviveWithoutAProbe() {
        for (bid, label) in [
            ("com.mitchellh.ghostty", "Ghostty"),
            ("com.googlecode.iterm2", "iTerm"),
            ("dev.warp.warp-stable", "Warp"),
            ("net.kovidgoyal.kitty", "Kitty"),
            ("com.github.wez.wezterm", "WezTerm"),
        ] {
            let k = AgentAppMapper.map(bundleID: bid, appName: nil)
            XCTAssertEqual(k.id, "terminal", bid)
            XCTAssertEqual(k.displayName, label, bid)
        }
    }

    func testTerminalWindowTitleNeverLeaksIntoBrowserDetection() {
        // A Ghostty window sitting in ~/Projects/claude-notes used to be matched
        // by BrowserAgentDetector's bare title.contains("claude") and registered
        // as Claude Code. Only the process probe is evidence for a terminal.
        let k = AgentAppMapper.map(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty",
            page: BrowserPageContext(title: "~/Projects/claude-notes", url: ""),
            terminal: .init(emulatorName: "Ghostty")
        )
        XCTAssertEqual(k.id, "terminal")
        XCTAssertNotEqual(k.id, "claude_code")
    }

    // MARK: - GUI bundle ids measured on this machine

    func testMapNativeClaudeCodeAndDevtoolsBundles() {
        // /…/Application Support/Claude/claude-code/*/claude.app
        XCTAssertEqual(
            AgentAppMapper.map(bundleID: "com.anthropic.claude-code", appName: nil).id,
            "claude_code"
        )
        // /Applications/claude-devtools.app — previously unmapped, so it minted
        // a bogus "claude_devtools" agent of its own.
        let devtools = AgentAppMapper.map(
            bundleID: "com.claudecode.context", appName: "claude-devtools"
        )
        XCTAssertEqual(devtools.id, "claude_code")
        XCTAssertEqual(devtools.displayName, "Claude Code")
    }

    func testMapDispatchByNameAndBundle() {
        // Dispatch ships with an unknown-to-us bundle id on some machines, so
        // the app name is the durable hook — and it must beat the generic
        // name.contains("claude") fallback.
        XCTAssertEqual(AgentAppMapper.map(bundleID: "", appName: "Dispatch").id, "dispatch")
        let claudeDispatch = AgentAppMapper.map(
            bundleID: "com.example.unknown", appName: "Claude Dispatch"
        )
        XCTAssertEqual(claudeDispatch.id, "dispatch")
        XCTAssertNotEqual(claudeDispatch.id, "claude_code")
        XCTAssertEqual(
            AgentAppMapper.map(bundleID: "com.anthropic.dispatch", appName: nil).id,
            "dispatch"
        )
        XCTAssertEqual(AgentStyleCatalog.style(for: "dispatch").systemImage, "paperplane.fill")
    }

    func testClaudeAdjacentUtilitiesAreNotAgents() {
        // "Usage for Claude.app" (com.ClaudeUsage) is a menu-bar meter. It used
        // to satisfy name.contains("claude") and steal the Claude Code identity.
        let usage = AgentAppMapper.map(bundleID: "com.ClaudeUsage", appName: "Usage for Claude")
        XCTAssertNotEqual(usage.id, "claude_code")
        XCTAssertEqual(usage.id, "local_test")
    }

    func testAllMappedIDsAreAcceptedByTheGate() {
        // hub/shannon_gate.py derives VALID_AGENTS from agent_identity.IDENTITIES;
        // an id outside that set registers and is rejected.
        let gateValid: Set<String> = [
            "science", "grok_build", "claude_code", "codex", "dispatch", "cowork",
            "chatgpt", "dataset_runner", "local_test", "terminal", "browser",
        ]
        for rule in TerminalAgentProbe.rules {
            XCTAssertTrue(
                gateValid.contains(rule.agentID),
                "TerminalAgentProbe emits \(rule.agentID), which the gate would reject"
            )
        }
    }

    func testMapChatAgents() {
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.openai.chat", appName: "ChatGPT").id, "chatgpt")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.anthropic.claudefordesktop", appName: "Claude").id, "claude_code")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.openai.codex", appName: "Codex").id, "codex")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.xai.grok", appName: "Grok").id, "grok_build")
        XCTAssertEqual(
            AgentAppMapper.map(bundleID: "com.xai.grok", appName: "Grok").displayName,
            "Grok Build"
        )
    }

    func testBrowserTabClaudeScienceNotGrok() {
        let science = BrowserPageContext(
            title: "Claude Science — FlexAID docking",
            url: "https://claude.ai/chat/abc"
        )
        let k = AgentAppMapper.map(
            bundleID: "com.google.chrome",
            appName: "Google Chrome",
            page: science
        )
        XCTAssertEqual(k.id, "science")
        XCTAssertEqual(k.displayName, "Claude Science")
        let style = AgentStyleCatalog.style(for: k.id)
        XCTAssertEqual(style.systemImage, "flask.fill")
        XCTAssertEqual(style.emoji, "🔬")
        // Amber brand (not purple Grok)
        XCTAssertGreaterThan(style.red, 0.9)
        XCTAssertLessThan(style.blue, 0.3)
    }

    func testNativeClaudeScienceAppNotClaudeCode() {
        // Real macOS bundle: /Applications/Claude Science.app → com.anthropic.operon
        let k = AgentAppMapper.map(
            bundleID: "com.anthropic.operon",
            appName: "Claude Science"
        )
        XCTAssertEqual(k.id, "science")
        XCTAssertEqual(k.displayName, "Claude Science")
        XCTAssertEqual(AgentStyleCatalog.style(for: k.id).systemImage, "flask.fill")

        // Name-only (unsigned / shifted bundle)
        let byName = AgentAppMapper.map(bundleID: "com.example.unknown", appName: "Claude Science")
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

    func testBrowserTabSuperGrokNotScience() {
        let grok = BrowserPageContext(
            title: "SuperGrok",
            url: "https://grok.x.ai/"
        )
        let k = AgentAppMapper.map(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            page: grok
        )
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

    func testBrowserTabChatGPTAndCodex() {
        let gpt = AgentAppMapper.map(
            bundleID: "com.google.chrome", appName: "Chrome",
            page: BrowserPageContext(title: "ChatGPT", url: "https://chatgpt.com/")
        )
        XCTAssertEqual(gpt.id, "chatgpt")
        let codex = AgentAppMapper.map(
            bundleID: "com.google.chrome", appName: "Chrome",
            page: BrowserPageContext(title: "Codex", url: "https://chatgpt.com/codex")
        )
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

    func testMapBrowsersAndIDE() {
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.apple.Safari", appName: "Safari").id, "browser")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.google.Chrome", appName: "Chrome").id, "browser")
        XCTAssertEqual(AgentAppMapper.map(bundleID: "com.microsoft.VSCode", appName: "Code").id, "vscode")
        let cursor = AgentAppMapper.map(bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor")
        XCTAssertEqual(cursor.id, "cursor")
    }

    func testNameFallbackWhenBundleUnknown() {
        let k = AgentAppMapper.map(bundleID: "com.example.unknown", appName: "Claude")
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
        print("LIVE GATE accepted=\(ok)")
        XCTAssertTrue(ok, "gate must accept a POST /message observation")

        // An id outside hub/agent_identity.py IDENTITIES must be refused, not
        // silently reported as healthy.
        let bogus = AgentIngestService.notifyGateBestEffort(
            agentID: "claude_devtools", task: "should be refused"
        )
        print("LIVE GATE bogus accepted=\(bogus)")
        XCTAssertFalse(bogus, "unknown agent ids must fail closed")
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
}
