import XCTest
@testable import PillCore

final class AgentActivityTests: XCTestCase {

    func testShortenAndJunkFilter() {
        XCTAssertTrue(AgentActivitySnapshot.looksLikeSecretOrJunk(
            "ANTHROPIC_API_KEY=sk-ant-abc123 put this in .env"
        ))
        XCTAssertTrue(AgentActivitySnapshot.looksLikeSecretOrJunk(String(repeating: "x", count: 200)))
        XCTAssertFalse(AgentActivitySnapshot.looksLikeSecretOrJunk("fix CF.com floor on 1SG0"))
        XCTAssertEqual(
            AgentActivitySnapshot.shorten("hello world this is a long task description", max: 12),
            "hello world…"
        )
    }

    func testCollapsedMultiAgent() {
        let a = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude", status: .active,
            lastTask: "wire notch UI", source: "chat",
            updatedAt: Date(), resumable: true, historyCount: 1
        )
        let b = AgentActivitySnapshot(
            id: "codex", displayName: "Codex", status: .active,
            lastTask: "review PR", source: "chat",
            updatedAt: Date().addingTimeInterval(-10), resumable: true, historyCount: 0
        )
        let s = AgentActivitySummary(agents: [a, b])
        XCTAssertEqual(s.busyCount, 2)
        XCTAssertTrue(s.collapsedText.contains("Claude"))
        XCTAssertTrue(s.collapsedText.contains("+1"))
    }

    func testReaderLoadsPets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-act-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let agentDir = pets.appendingPathComponent("claude_code", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let state: [String: Any] = [
            "status": "active",
            "last_task": "refine pill UI",
            "updated_at": Date().timeIntervalSince1970,
            "resumable": true,
            "history_count": 2,
            "memory_size": 10,
            "last_cf_delta": NSNull(),
        ]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: agentDir.appendingPathComponent("state.json"))

        let reg: [[String: Any]] = [[
            "id": "claude_code",
            "display_name": "Claude",
            "source": "chat",
            "last_task": "refine pill UI",
            "updated_at": Date().timeIntervalSince1970,
        ]]
        try JSONSerialization.data(withJSONObject: reg)
            .write(to: root.appendingPathComponent("agents.json"))

        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json")
        )
        XCTAssertEqual(summary.busyCount, 1)
        XCTAssertEqual(summary.primary?.id, "claude_code")
        XCTAssertEqual(summary.primary?.displayName, "Claude")
        XCTAssertTrue(summary.collapsedText.contains("Claude"))
        XCTAssertTrue(summary.collapsedText.contains("refine"))
    }

    func testStaleActiveBecomesIdleInUI() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let agentDir = pets.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let state: [String: Any] = [
            "status": "active",
            "last_task": "old work",
            "updated_at": Date().addingTimeInterval(-3 * 3600).timeIntervalSince1970,
            "resumable": true,
            "history_count": 0,
            "memory_size": 0,
            "last_cf_delta": NSNull(),
        ]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: agentDir.appendingPathComponent("state.json"))

        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            staleAfter: 45 * 60
        )
        XCTAssertEqual(summary.busyCount, 0)
        XCTAssertEqual(summary.agents.first?.status, .idle)
    }

    func testClipboardRejectsSecrets() {
        let (id, task) = AgentAppMapper.parseClipboard(
            "ANTHROPIC_API_KEY=sk-ant-secret\nmore junk"
        )
        XCTAssertNil(id)
        XCTAssertNil(task)
    }

    func testClipboardAgentLineAllowed() {
        let (id, task) = AgentAppMapper.parseClipboard("agent: science fix CF.com floor")
        XCTAssertEqual(id, "science")
        XCTAssertEqual(task, "fix CF.com floor")
    }

    /// Claude hub enhancement: live gate `agents` rows win when fresher/busy.
    func testMergePrefersLiveGateAgent() {
        let pet = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude", status: .idle,
            lastTask: "old offline task", source: "chat",
            updatedAt: Date().addingTimeInterval(-120), resumable: false, historyCount: 0
        )
        let gate = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude", status: .active,
            lastTask: "docking canary", source: "gate",
            updatedAt: Date(), resumable: true, historyCount: 4
        )
        let s = AgentActivityReader.merge(base: [pet], gate: [gate])
        XCTAssertEqual(s.busyCount, 1)
        XCTAssertEqual(s.primary?.lastTask, "docking canary")
        XCTAssertEqual(s.primary?.status, .active)
        XCTAssertTrue(s.collapsedText.contains("Claude"))
    }
}
