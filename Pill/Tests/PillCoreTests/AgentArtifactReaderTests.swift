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
        let s = sessions[0]
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
        let s = sessions[0]
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
        let reg = SessionRegistry()
        reg.register(ClaudeCodeSessionReader(projectsRoot: projects, maxSessions: 5))
        reg.register(CodexSessionReader(sessionsRoot: codexRoot, maxSessions: 5))
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
        let science = all.first { $0.agentId == "science" }
        XCTAssertEqual(science?.presence, .live)
        XCTAssertEqual(science?.sourceKind, .gate)
    }

    func testProjectDirectoryDecodePrefersHome() {
        let home = "/Users/lp.more"
        let encoded = "-Users-lp-more-Documents-PhD-Programs-FlexAIDdS"
        let path = ClaudeCodeSessionReader.decodeProjectDirectoryName(encoded, home: home)
        XCTAssertEqual(path, "/Users/lp.more/Documents/PhD/Programs/FlexAIDdS")
    }
}
