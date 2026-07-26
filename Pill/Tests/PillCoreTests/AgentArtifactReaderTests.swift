import XCTest
@testable import AgentReaders
@testable import PillCore

final class AgentArtifactReaderTests: XCTestCase {

    private var fixturesRoot: URL {
        // Prefer SPM resource bundle; fall back to source-relative path.
        if let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) {
            return url
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    func testClaudeCodeReaderParsesFixtureSession() {
        let projects = fixturesRoot
            .appendingPathComponent("claude/projects", isDirectory: true)
        let sessions = ClaudeCodeSessionReader.readSessions(
            projectsRoot: projects,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10
        )
        XCTAssertFalse(sessions.isEmpty, "expected at least one Claude session from fixtures at \(projects.path)")
        // No-usage fixture must stay fail-closed (usage fixture is sess-bbbb-2222).
        let s = sessions.first { $0.id.contains("sess-aaaa-1111") } ?? sessions[0]
        XCTAssertEqual(s.agentId, "claude_code")
        XCTAssertEqual(s.sourceKind, .artifact)
        XCTAssertEqual(s.presence, .observed)
        XCTAssertFalse(s.id.isEmpty)
        // Non-empty activity/state field from fixture (title or prompt).
        let activity = s.lastTask ?? s.activitySummary ?? ""
        XCTAssertFalse(activity.isEmpty, "session should expose title or last prompt")
        // Tokens must stay missing when artifact has none.
        XCTAssertNil(s.tokensIn)
        XCTAssertNil(s.tokensOut)
        XCTAssertNotNil(s.sourcePath)
        XCTAssertTrue(s.sourcePath?.hasSuffix(".jsonl") == true)
    }

    func testClaudeCodeMissingRootReturnsEmpty() {
        let missing = URL(fileURLWithPath: "/tmp/shannon-no-such-claude-projects-\(UUID().uuidString)")
        let sessions = ClaudeCodeSessionReader.readSessions(projectsRoot: missing)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testCodexReaderParsesFixtureRollout() {
        let root = fixturesRoot
            .appendingPathComponent("codex/sessions", isDirectory: true)
        let sessions = CodexSessionReader.readSessions(
            sessionsRoot: root,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10
        )
        XCTAssertFalse(sessions.isEmpty, "expected Codex session from fixtures at \(root.path)")
        // No-usage fixture must stay fail-closed (usage fixture is cccccccc-…).
        let s = sessions.first { $0.id.contains("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb") } ?? sessions[0]
        XCTAssertEqual(s.agentId, "codex")
        XCTAssertEqual(s.displayName, "Codex")
        XCTAssertEqual(s.sourceKind, .artifact)
        XCTAssertEqual(s.cwd, "/Users/test/DemoApp")
        XCTAssertEqual(s.project, "DemoApp")
        // Activity/state from events
        XCTAssertFalse((s.lastTask ?? s.stateLabel ?? "").isEmpty)
        XCTAssertNil(s.tokensIn)
        XCTAssertNil(s.tokensOut)
    }

    func testCodexMissingStoreReturnsEmptyNotFake() {
        let missing = URL(fileURLWithPath: "/tmp/shannon-no-codex-\(UUID().uuidString)")
        let sessions = CodexSessionReader.readSessions(sessionsRoot: missing)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testReadersPlugIntoSessionRegistry() {
        let projects = fixturesRoot.appendingPathComponent("claude/projects", isDirectory: true)
        let codexRoot = fixturesRoot.appendingPathComponent("codex/sessions", isDirectory: true)
        let cursorRoot = fixturesRoot.appendingPathComponent("cursor/projects", isDirectory: true)
        let coworkRoot = fixturesRoot.appendingPathComponent("cowork/sessions", isDirectory: true)
        let kimiRoot = fixturesRoot.appendingPathComponent("kimi/sessions", isDirectory: true)
        let reg = SessionRegistry()
        reg.register(ClaudeCodeSessionReader(projectsRoot: projects, maxSessions: 5))
        reg.register(CodexSessionReader(sessionsRoot: codexRoot, maxSessions: 5))
        reg.register(CursorSessionReader(projectsRoot: cursorRoot, maxSessions: 5))
        reg.register(CoworkSessionReader(sessionsRoot: coworkRoot, maxSessions: 5))
        reg.register(KimiSessionReader(sessionRoots: [kimiRoot], maxSessions: 5))
        // Gate live should outrank when same agent appears (science only on gate).
        reg.register(GateSessionProvider(agents: [
            AgentActivitySnapshot(
                id: "science", displayName: "Claude Science",
                status: .midTask, lastTask: "gate live", source: "gate",
                updatedAt: Date(), resumable: true, historyCount: 1, presence: .live
            ),
        ]))
        let all = reg.allSessions()
        XCTAssertTrue(all.contains { $0.agentId == "claude_code" && $0.sourceKind == .artifact })
        XCTAssertTrue(all.contains { $0.agentId == "codex" && $0.sourceKind == .artifact })
        XCTAssertTrue(all.contains { $0.agentId == "cursor" && $0.sourceKind == .artifact })
        XCTAssertTrue(all.contains { $0.agentId == "cowork" && $0.sourceKind == .artifact })
        XCTAssertTrue(all.contains { $0.agentId == "kimi" && $0.sourceKind == .artifact })
        let science = all.first { $0.agentId == "science" }
        XCTAssertEqual(science?.presence, .live)
        XCTAssertEqual(science?.sourceKind, .gate)
    }

    // MARK: - AgentNotch works-with residual readers

    func testCursorReaderParsesFixtureTranscript() {
        let root = fixturesRoot.appendingPathComponent("cursor/projects", isDirectory: true)
        let sessions = CursorSessionReader.readSessions(
            projectsRoot: root,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10
        )
        XCTAssertFalse(sessions.isEmpty, "expected Cursor session at \(root.path)")
        let s = sessions[0]
        XCTAssertEqual(s.agentId, "cursor")
        XCTAssertEqual(s.displayName, "Cursor")
        XCTAssertEqual(s.sourceKind, .artifact)
        XCTAssertTrue(s.id.contains("cursor:"))
        XCTAssertEqual(s.status, .idle) // turn_ended success
        XCTAssertEqual(s.project, "DemoApp")
        let task = s.lastTask ?? s.activitySummary ?? ""
        XCTAssertTrue(task.lowercased().contains("hud") || task.lowercased().contains("spring"),
                      "task=\(task)")
        XCTAssertNil(s.tokensIn)
        XCTAssertNil(s.tokensOut)
    }

    func testCursorMissingRootReturnsEmpty() {
        let missing = URL(fileURLWithPath: "/tmp/shannon-no-cursor-\(UUID().uuidString)")
        XCTAssertTrue(CursorSessionReader.readSessions(projectsRoot: missing).isEmpty)
    }

    func testCoworkReaderParsesFixtureSession() {
        let root = fixturesRoot.appendingPathComponent("cowork/sessions", isDirectory: true)
        let sessions = CoworkSessionReader.readSessions(
            sessionsRoot: root,
            now: Date(timeIntervalSince1970: 1_721_500_200),
            maxSessions: 10,
            recentActivityWindow: 600
        )
        XCTAssertFalse(sessions.isEmpty, "expected Cowork session at \(root.path)")
        let s = sessions[0]
        XCTAssertEqual(s.agentId, "cowork")
        XCTAssertEqual(s.displayName, "Cowork")
        XCTAssertEqual(s.sourceKind, .artifact)
        XCTAssertEqual(s.model, "claude-opus-test")
        XCTAssertEqual(s.lastTask, "Sort invoice folder")
        XCTAssertEqual(s.project, "Invoices")
        XCTAssertEqual(s.status, .midTask) // lastActivity within window of now
        XCTAssertNil(s.tokensIn)
    }

    func testCoworkMissingRootReturnsEmpty() {
        let missing = URL(fileURLWithPath: "/tmp/shannon-no-cowork-\(UUID().uuidString)")
        XCTAssertTrue(CoworkSessionReader.readSessions(sessionsRoot: missing).isEmpty)
    }

    func testKimiReaderParsesFixtureAndFailClosedEmpty() {
        let root = fixturesRoot.appendingPathComponent("kimi/sessions", isDirectory: true)
        let sessions = KimiSessionReader.readSessions(
            roots: [root],
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10
        )
        XCTAssertFalse(sessions.isEmpty)
        let s = sessions.first { $0.id.contains("bbbb-2222") } ?? sessions[0]
        XCTAssertEqual(s.agentId, "kimi")
        XCTAssertEqual(s.displayName, "Kimi")
        XCTAssertEqual(s.model, "kimi-k2")
        // Idle multi-turn fixture is not a wait.
        XCTAssertEqual(s.status, .idle)
        // Wait state is observational — never invents Approve capability.
        XCTAssertFalse((s.stateLabel ?? "").lowercased().contains("approve"))
        let missing = URL(fileURLWithPath: "/tmp/shannon-no-kimi-\(UUID().uuidString)")
        XCTAssertTrue(KimiSessionReader.readSessions(roots: [missing]).isEmpty)
    }

    func testKimiWaitingStatusElevatesNeedsYouWithoutApprove() {
        let root = fixturesRoot.appendingPathComponent("kimi/sessions", isDirectory: true)
        let sessions = KimiSessionReader.readSessions(
            roots: [root],
            now: Date(timeIntervalSince1970: 1_721_500_300),
            maxSessions: 10
        )
        let s = sessions.first { $0.id.contains("wait-cccc") }
        XCTAssertNotNil(s, "expected wait fixture sess-kimi-wait-cccc-3333")
        guard let s else { return }
        // After user+assistant history, status=waiting_for_user must still block.
        XCTAssertEqual(s.status, .blocked)
        XCTAssertTrue(
            (s.stateLabel ?? "").lowercased().contains("waiting"),
            "stateLabel=\(s.stateLabel ?? "nil")"
        )
        XCTAssertFalse((s.stateLabel ?? "").lowercased().contains("approve"))
        // Card path: needsYou elevated from session.blocked; no gate ask → no inline Approve.
        let card = SessionContentPresenter.card(session: s, pendingAsks: [], now: Date())
        XCTAssertTrue(card.needsYou, "blocked session must elevate needsYou")
        XCTAssertEqual(card.attention, .needsYou)
        XCTAssertFalse(card.canAnswerInline, "Kimi must not fake Approve without gate ask")
        XCTAssertNil(card.pendingPrompt)
        // Surface resolve agrees.
        let surface = SessionContentPresenter.resolveSurface(session: s)
        XCTAssertTrue(surface.needsYou)
        XCTAssertEqual(surface.attention, .needsYou)
    }

    func testCursorProjectLabelPreservesDottedUsernameHome() {
        let home = "/Users/lp.more"
        let label = CursorSessionReader.projectLabel(
            fromProjectDir: "Users-lp-more-Projects-Shannon",
            home: home
        )
        XCTAssertEqual(label.cwd, "/Users/lp.more/Projects/Shannon")
        XCTAssertEqual(label.project, "Shannon")
        // Must NOT split the username into lp/more.
        XCTAssertFalse(label.cwd?.contains("/lp/more/") == true)
        XCTAssertFalse(label.cwd?.hasPrefix("/Users/lp/more") == true)

        // Fixture path uses Users-test-DemoApp — home won't match → cwd fail-closed nil.
        let foreign = CursorSessionReader.projectLabel(
            fromProjectDir: "Users-test-DemoApp",
            home: home
        )
        XCTAssertNil(foreign.cwd, "foreign home must not invent a broken cwd")
        XCTAssertEqual(foreign.project, "DemoApp")
    }

    func testCursorReaderFixtureWithDottedHomeSlug() {
        let root = fixturesRoot.appendingPathComponent("cursor/projects", isDirectory: true)
        let sessions = CursorSessionReader.readSessions(
            projectsRoot: root,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10,
            resolveBranch: { _ in nil }
        )
        // When home is the real machine home, Shannon slug should decode if username matches.
        if let shannon = sessions.first(where: { $0.id.contains("dotted-2222") }) {
            XCTAssertEqual(shannon.agentId, "cursor")
            // Either home-decoded cwd or fail-closed project basename — never /Users/lp/more/...
            if let cwd = shannon.cwd {
                XCTAssertFalse(cwd.contains("/lp/more/"), "cwd corrupted: \(cwd)")
            }
        }
    }

    func testPanelRegistryRegistersWorksWithReaders() throws {
        // Structural: ShannonPill collectParityPayload must register residual providers.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PillCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Pill
            .appendingPathComponent("Sources/ShannonPill/PanelSectionRegistry.swift")
        let text = try String(contentsOf: root, encoding: .utf8)
        for needle in [
            "CoworkSessionReader",
            "ClaudeCodeSessionReader",
            "CodexSessionReader",
            "CursorSessionReader",
            "KimiSessionReader",
        ] {
            XCTAssertTrue(text.contains(needle), "PanelSectionRegistry must register \(needle)")
        }
    }

    func testProjectDirectoryDecodePrefersHome() {
        let home = "/Users/lp.more"
        let encoded = "-Users-lp-more-Documents-PhD-Programs-FlexAIDdS"
        let path = ClaudeCodeSessionReader.decodeProjectDirectoryName(encoded, home: home)
        XCTAssertEqual(path, "/Users/lp.more/Documents/PhD/Programs/FlexAIDdS")
    }

    // MARK: - Token usage (ENH-004)

    func testClaudeCodeReaderParsesUsageFromFixture() {
        let projects = fixturesRoot
            .appendingPathComponent("claude/projects", isDirectory: true)
        let sessions = ClaudeCodeSessionReader.readSessions(
            projectsRoot: projects,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10
        )
        let s = sessions.first { $0.id.contains("sess-bbbb-2222") }
        XCTAssertNotNil(s, "expected Claude usage fixture sess-bbbb-2222")
        // input_tokens 100 + cache_read_input_tokens 50 (+ cache_creation 0) = 150
        XCTAssertEqual(s?.tokensIn, 150)
        XCTAssertEqual(s?.tokensOut, 25)

        guard let session = s else { return }
        let usage = SessionContentPresenter.usageFromSession(session)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.tokensUsed, 175)
    }

    func testCodexReaderParsesTokenCountFromFixture() {
        let root = fixturesRoot
            .appendingPathComponent("codex/sessions", isDirectory: true)
        let sessions = CodexSessionReader.readSessions(
            sessionsRoot: root,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10
        )
        let s = sessions.first { $0.id.contains("cccccccc-cccc-cccc-cccc-cccccccccccc") }
        XCTAssertNotNil(s, "expected Codex usage fixture cccccccc-…")
        // plain input_tokens only (cached_input_tokens not double-counted)
        XCTAssertEqual(s?.tokensIn, 1000)
        XCTAssertEqual(s?.tokensOut, 40)

        guard let session = s else { return }
        let usage = SessionContentPresenter.usageFromSession(session)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.tokensUsed, 1040)
    }

    func testClaudeExtractUsageFailClosed() {
        XCTAssertNil(ClaudeCodeSessionReader.extractUsage(from: [:]))
        XCTAssertNil(ClaudeCodeSessionReader.extractUsage(from: [
            "type": "assistant",
            "message": ["role": "assistant", "content": "hi"],
        ]))
        XCTAssertNil(ClaudeCodeSessionReader.extractUsage(from: [
            "usage": ["input_tokens": -1, "output_tokens": -5],
        ]))
        // message.usage preferred
        let u = ClaudeCodeSessionReader.extractUsage(from: [
            "usage": ["input_tokens": 1, "output_tokens": 1],
            "message": [
                "usage": [
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 20,
                    "cache_read_input_tokens": 30,
                    "output_tokens": 4,
                ] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertEqual(u?.tokensIn, 60)
        XCTAssertEqual(u?.tokensOut, 4)
        // top-level usage fallback
        let top = ClaudeCodeSessionReader.extractUsage(from: [
            "usage": ["input_tokens": 7, "output_tokens": 3],
        ])
        XCTAssertEqual(top?.tokensIn, 7)
        XCTAssertEqual(top?.tokensOut, 3)
        // only output present
        let outOnly = ClaudeCodeSessionReader.extractUsage(from: [
            "usage": ["output_tokens": 9],
        ])
        XCTAssertNil(outOnly?.tokensIn)
        XCTAssertEqual(outOnly?.tokensOut, 9)
    }

    // MARK: - Git branch probe (ENH-013)

    func testGitBranchProbeValidName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-git-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let branch = GitBranchProbe.branch(for: dir.path, runner: { _ in "feat/hud" })
        XCTAssertEqual(branch, "feat/hud")
    }

    func testGitBranchProbeFailClosed() throws {
        XCTAssertNil(GitBranchProbe.branch(for: nil, runner: { _ in "main" }))
        XCTAssertNil(GitBranchProbe.branch(for: "", runner: { _ in "main" }))
        XCTAssertNil(GitBranchProbe.branch(for: "   ", runner: { _ in "main" }))
        XCTAssertNil(GitBranchProbe.branch(
            for: "/tmp/shannon-no-such-dir-\(UUID().uuidString)",
            runner: { _ in "main" }
        ))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-git-branch-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(GitBranchProbe.branch(for: dir.path, runner: { _ in nil }))
        XCTAssertNil(GitBranchProbe.branch(for: dir.path, runner: { _ in "" }))
        XCTAssertNil(GitBranchProbe.branch(for: dir.path, runner: { _ in "   " }))
        XCTAssertNil(GitBranchProbe.branch(for: dir.path, runner: { _ in "HEAD" }))
        // Whitespace-stripped valid name
        XCTAssertEqual(
            GitBranchProbe.branch(for: dir.path, runner: { _ in "  main\n" }),
            "main"
        )
    }

    func testClaudeCodeReaderInjectedBranch() {
        let projects = fixturesRoot
            .appendingPathComponent("claude/projects", isDirectory: true)
        let sessions = ClaudeCodeSessionReader.readSessions(
            projectsRoot: projects,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10,
            resolveBranch: { _ in "feat/hud" }
        )
        XCTAssertFalse(sessions.isEmpty)
        for s in sessions {
            XCTAssertEqual(s.branch, "feat/hud", "injected branch should apply to \(s.id)")
        }
    }

    func testClaudeCodeReaderNilBranchWhenProbeFails() {
        let projects = fixturesRoot
            .appendingPathComponent("claude/projects", isDirectory: true)
        let sessions = ClaudeCodeSessionReader.readSessions(
            projectsRoot: projects,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10,
            resolveBranch: { _ in nil }
        )
        XCTAssertFalse(sessions.isEmpty)
        for s in sessions {
            XCTAssertNil(s.branch, "fail-closed probe must leave branch nil for \(s.id)")
        }
    }

    func testCodexReaderInjectedBranch() {
        let root = fixturesRoot
            .appendingPathComponent("codex/sessions", isDirectory: true)
        let sessions = CodexSessionReader.readSessions(
            sessionsRoot: root,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10,
            resolveBranch: { cwd in
                // Only fill when cwd known (fixture has /Users/test/DemoApp)
                cwd == nil ? nil : "feat/hud"
            }
        )
        XCTAssertFalse(sessions.isEmpty)
        let withCwd = sessions.filter { $0.cwd != nil }
        XCTAssertFalse(withCwd.isEmpty)
        for s in withCwd {
            XCTAssertEqual(s.branch, "feat/hud")
        }
    }

    func testCodexReaderNilBranchWhenProbeFails() {
        let root = fixturesRoot
            .appendingPathComponent("codex/sessions", isDirectory: true)
        let sessions = CodexSessionReader.readSessions(
            sessionsRoot: root,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10,
            resolveBranch: { _ in nil }
        )
        XCTAssertFalse(sessions.isEmpty)
        for s in sessions {
            XCTAssertNil(s.branch)
        }
    }

    func testFixtureSessionsLeaveBranchNilWithoutInjection() {
        // Default path uses real git against fixture cwds (non-repos / missing) → nil.
        let projects = fixturesRoot
            .appendingPathComponent("claude/projects", isDirectory: true)
        let claude = ClaudeCodeSessionReader.readSessions(
            projectsRoot: projects,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10
        )
        XCTAssertFalse(claude.isEmpty)
        for s in claude {
            XCTAssertNil(s.branch, "fixture cwd should not invent a branch for \(s.id)")
        }

        let codexRoot = fixturesRoot
            .appendingPathComponent("codex/sessions", isDirectory: true)
        let codex = CodexSessionReader.readSessions(
            sessionsRoot: codexRoot,
            now: Date(timeIntervalSince1970: 1_721_500_000),
            maxSessions: 10
        )
        XCTAssertFalse(codex.isEmpty)
        for s in codex {
            XCTAssertNil(s.branch, "fixture cwd should not invent a branch for \(s.id)")
        }
    }

    func testCodexExtractTokenCountFailClosed() {
        XCTAssertNil(CodexSessionReader.extractTokenCount(from: [:]))
        XCTAssertNil(CodexSessionReader.extractTokenCount(from: [
            "type": "token_count",
            "info": [:] as [String: Any],
        ]))
        XCTAssertNil(CodexSessionReader.extractTokenCount(from: [
            "type": "token_count",
            "info": [
                "total_token_usage": ["input_tokens": -3, "output_tokens": -1],
            ] as [String: Any],
        ]))
        // prefers total over last; does not add cached_input_tokens
        let u = CodexSessionReader.extractTokenCount(from: [
            "type": "token_count",
            "info": [
                "total_token_usage": [
                    "input_tokens": 1000,
                    "cached_input_tokens": 200,
                    "output_tokens": 40,
                ] as [String: Any],
                "last_token_usage": [
                    "input_tokens": 1,
                    "output_tokens": 1,
                ] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertEqual(u?.tokensIn, 1000)
        XCTAssertEqual(u?.tokensOut, 40)
        // fall back to last when total missing
        let last = CodexSessionReader.extractTokenCount(from: [
            "type": "token_count",
            "info": [
                "last_token_usage": [
                    "input_tokens": 12,
                    "output_tokens": 3,
                ] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertEqual(last?.tokensIn, 12)
        XCTAssertEqual(last?.tokensOut, 3)
    }
}
