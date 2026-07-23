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
