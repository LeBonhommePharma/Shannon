import XCTest
@testable import PillCore

final class AgentActivityTests: XCTestCase {

    func testShortenAndJunkFilter() {
        XCTAssertTrue(AgentActivitySnapshot.looksLikeSecretOrJunk(
            "ANTHROPIC_API_KEY=sk-ant-abc123 put this in .env"
        ))
        XCTAssertTrue(AgentActivitySnapshot.looksLikeSecretOrJunk(String(repeating: "x", count: 200)))
        XCTAssertFalse(AgentActivitySnapshot.looksLikeSecretOrJunk("fix CF.com floor on 1SG0"))
        // Gate interaction ids contain "ask-", which the old substring match for
        // "sk-" flagged as a leaked key — blanking every approval prompt and
        // activity label the user actually needed to read.
        XCTAssertFalse(AgentActivitySnapshot.looksLikeSecretOrJunk("approved: ask-hub-ui-1784780299"))
        XCTAssertFalse(AgentActivitySnapshot.looksLikeSecretOrJunk("ask-science-e2e-1784779386"))
        XCTAssertFalse(AgentActivitySnapshot.looksLikeSecretOrJunk("task-42 is risk-free"))
        XCTAssertEqual(
            AgentActivitySnapshot.shorten("approved: ask-hub-ui-1784780299", max: 60),
            "approved: ask-hub-ui-1784780299"
        )
        // Still catches a real bare key.
        XCTAssertTrue(AgentActivitySnapshot.looksLikeSecretOrJunk(
            "use sk-abcdefghij0123456789 now"
        ))
        XCTAssertEqual(
            AgentActivitySnapshot.shorten("hello world this is a long task description", max: 12),
            "hello world…"
        )
    }

    func testCollapsedMultiAgent() {
        // Both connected to the hub and mid-turn — the only case that may be
        // rendered as "2 agents active".
        let a = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude", status: .active,
            lastTask: "wire notch UI", source: "gate",
            updatedAt: Date(), resumable: true, historyCount: 1, presence: .live
        )
        let b = AgentActivitySnapshot(
            id: "codex", displayName: "Codex", status: .active,
            lastTask: "review PR", source: "gate",
            updatedAt: Date().addingTimeInterval(-10), resumable: true,
            historyCount: 0, presence: .live
        )
        let s = AgentActivitySummary(agents: [a, b])
        XCTAssertEqual(s.busyCount, 2)
        XCTAssertTrue(s.collapsedText.contains("Claude"))
        XCTAssertTrue(s.collapsedText.contains("+1"))
    }

    /// A pet file is a ⌘D foreground observation, not telemetry. It must never
    /// come back busy — that is exactly the "3 agents active" lie the pill used
    /// to tell about Ghostty, Claude.app and `com.apple.windowmanager`.
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
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil
        )
        // Still listed, still labelled, still useful…
        XCTAssertEqual(summary.primary?.id, "claude_code")
        XCTAssertEqual(summary.primary?.displayName, "Claude")
        XCTAssertEqual(summary.primary?.lastTask, "refine pill UI")
        XCTAssertTrue(summary.collapsedText.contains("Claude"))
        XCTAssertTrue(summary.collapsedText.contains("refine"))
        // …but not claimed to be working, and not counted as active.
        XCTAssertEqual(summary.busyCount, 0)
        XCTAssertEqual(summary.primary?.presence, .observed)
        XCTAssertEqual(summary.primary?.status, .idle)
    }

    /// The app behind an observed pet has quit → say "offline", not "seen".
    func testObservedPetWithDeadAppIsOffline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-dead-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let dir = pets.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "status": "active", "last_task": "Working in ChatGPT",
            "updated_at": Date().timeIntervalSince1970, "resumable": true,
        ]).write(to: dir.appendingPathComponent("state.json"))
        try JSONSerialization.data(withJSONObject: [[
            "id": "codex", "display_name": "Codex", "source": "chat",
            "bundle": "com.openai.codex", "last_task": "Working in ChatGPT",
            "updated_at": Date().timeIntervalSince1970,
        ]]).write(to: root.appendingPathComponent("agents.json"))

        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            runningBundleIDs: ["com.apple.finder"]      // codex is not running
        )
        XCTAssertEqual(summary.agents.first?.presence, .offline)
        XCTAssertEqual(summary.busyCount, 0)
        XCTAssertTrue(summary.agents.first?.statusLine.hasPrefix("offline") == true)
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
            gateDB: nil,
            staleAfter: 45 * 60
        )
        XCTAssertEqual(summary.busyCount, 0)
        XCTAssertEqual(summary.agents.first?.status, .idle)
    }

    /// Regression for the headline bug: a ⌘D pet written 10 minutes ago is
    /// *newer* than the gate row, and the old merge let it win — so a
    /// disconnected agent rendered as "active". The gate must win regardless.
    func testFreshPetCannotOverrideDisconnectedGateAgent() {
        let pet = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude Code", status: .active,
            lastTask: "Working in Claude", source: "chat",
            updatedAt: Date().addingTimeInterval(-600),   // 10 min ago — fresher
            resumable: true, historyCount: 0, presence: .observed
        )
        let gate = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude Code", status: .active,
            lastTask: "e2e status", source: "gate",
            updatedAt: Date().addingTimeInterval(-40 * 3600),  // hung up 40 h ago
            resumable: true, historyCount: 4, presence: .offline
        )
        let s = AgentActivityReader.merge(base: [pet], gate: [gate])
        XCTAssertEqual(s.busyCount, 0)
        XCTAssertEqual(s.agents.first?.status, .idle)
        XCTAssertEqual(s.agents.first?.presence, .offline)
        XCTAssertTrue(s.agents.first?.statusLine.contains("last seen") == true)
        XCTAssertEqual(s.collapsedText, "No active agents")
    }

    /// A connected agent that has gone quiet past `staleAfter` stops counting.
    func testGateAgentGoesIdleWhenQuiet() {
        let gate = AgentActivitySnapshot(
            id: "science", displayName: "Science", status: .active,
            lastTask: "docking", source: "gate",
            updatedAt: Date().addingTimeInterval(-3 * 3600),
            resumable: true, historyCount: 2, presence: .live
        )
        let s = AgentActivityReader.merge(base: [], gate: [gate])
        XCTAssertEqual(s.busyCount, 0)
        XCTAssertEqual(s.agents.first?.presence, .offline)
    }

    func testStatusLineNeverInventsWork() {
        let observed = AgentActivitySnapshot(
            id: "terminal", displayName: "Terminal", status: .active,
            lastTask: "Working in Ghostty", source: "terminal",
            updatedAt: Date().addingTimeInterval(-780), resumable: true,
            historyCount: 0, presence: .observed
        )
        XCTAssertEqual(observed.statusLine, "seen 13m ago")
        XCTAssertEqual(AgentActivitySummary(agents: [observed]).busyCount, 0)
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
