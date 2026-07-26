import XCTest
import SQLite3
import PillCore
import ShannonCore
@testable import ShannonPill

// MARK: - Pure roster builder (ENH-020)

/// Unit cover for `AgentStateRosterPublish` — multi-agent rows, bridge fallback,
/// fail-closed entropy, and retract-set math without standing up CloudKit.
final class AgentStateRosterPublishTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func liveAgent(
        id: String,
        name: String? = nil,
        status: AgentRunStatus = .active,
        task: String = "",
        history: Int = 0,
        secondsAgo: TimeInterval = 5
    ) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            id: id,
            displayName: name ?? id,
            status: status,
            lastTask: task,
            source: "chat",
            updatedAt: now.addingTimeInterval(-secondsAgo),
            resumable: false,
            historyCount: history,
            presence: .live,
            heartbeatAt: now.addingTimeInterval(-2)
        )
    }

    private func offlineAgent(id: String) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            id: id,
            displayName: id,
            status: .idle,
            lastTask: "was working",
            source: "chat",
            updatedAt: now.addingTimeInterval(-3_600),
            resumable: false,
            historyCount: 1,
            presence: .offline
        )
    }

    // MARK: Multi-agent

    func testPublishesOneAgentStatePerLiveAgentPreservingOrder() {
        let agents = [
            liveAgent(id: "codex", task: "fix auth", history: 12, secondsAgo: 3),
            liveAgent(id: "claude_code", status: .midTask, task: "review PR", history: 4, secondsAgo: 8),
            offlineAgent(id: "ghost"),
        ]
        let rows = AgentStateRosterPublish.snapshots(
            activityAgents: agents,
            bridgeConnected: false,
            bridgeStatus: nil,
            gateDBAvailable: true,
            now: now
        )
        XCTAssertEqual(rows.map(\.id), ["codex", "claude_code"],
                       "only presence.live agents enter the published live set")
        XCTAssertEqual(rows[0].name, "codex")
        XCTAssertEqual(rows[0].activity, .running)
        XCTAssertEqual(rows[0].taskTitle, "fix auth")
        XCTAssertEqual(rows[0].turnCount, 12)
        XCTAssertEqual(rows[1].activity, .running)
        XCTAssertFalse(rows.contains { $0.id == "ghost" })
    }

    func testMapsBlockedStatusAndIdleWithoutInventingEntropy() {
        let agents = [
            liveAgent(id: "blocked", status: .blocked, task: "awaiting approval"),
            liveAgent(id: "quiet", status: .idle),
        ]
        let rows = AgentStateRosterPublish.snapshots(
            activityAgents: agents,
            bridgeConnected: false,
            bridgeStatus: nil,
            gateDBAvailable: true,
            now: now
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].activity, .blocked)
        XCTAssertEqual(rows[1].activity, .idle)
        for row in rows {
            XCTAssertNil(row.entropyBits, "no gate/bridge measurement → no H")
            XCTAssertNil(row.entropyDelta)
            XCTAssertFalse(row.isCollapsed)
        }
    }

    // MARK: Fail-closed entropy

    func testGateMeasuredEntropyPublishesBitsButNotTokenCollapse() {
        let measuredAt = now.addingTimeInterval(-10)
        let m = EntropyMeasurement(
            bits: 2.86,
            deltaH: nil,
            collapsed: nil,
            source: .gate(agentId: "claude_code", presence: .live),
            measuredAt: measuredAt,
            now: now
        )
        XCTAssertNotNil(m)
        let rows = AgentStateRosterPublish.snapshots(
            activityAgents: [liveAgent(id: "claude_code", task: "docking")],
            bridgeConnected: false,
            bridgeStatus: nil,
            gateEntropy: [m!],
            gateDBAvailable: true,
            now: now
        )
        let row = try! XCTUnwrap(rows.first)
        XCTAssertEqual(row.entropyBits ?? 0, 2.86, accuracy: 1e-9)
        XCTAssertNil(row.entropyDelta)
        XCTAssertFalse(
            row.isCollapsed,
            "gate message scores must never publish as eval-awareness collapse"
        )
        XCTAssertNotEqual(row.activity, .blocked)
    }

    func testDemoBridgeDoesNotPaintPerAgentEntropyOrCollapse() {
        let demo = ShannonStatus(
            entropy: 6.2,
            deltaH: -1.9,
            collapsed: true,
            tokenCount: 128,
            backend: "demo",
            agent: "demo"
        )
        // Fleet agent with a different id: resolveForAgent must not copy
        // fleet/demo numbers onto every row.
        let rows = AgentStateRosterPublish.snapshots(
            activityAgents: [liveAgent(id: "codex", task: "work")],
            bridgeConnected: true,
            bridgeStatus: demo,
            gateDBAvailable: true,
            now: now
        )
        let row = try! XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "codex")
        XCTAssertNil(row.entropyBits)
        XCTAssertNil(row.entropyDelta)
        XCTAssertFalse(row.isCollapsed)
        XCTAssertNotEqual(row.activity, .blocked)
    }

    func testNamedMeasuredBridgeCollapsePublishesOnThatAgentOnly() {
        let status = ShannonStatus(
            entropy: 2.1,
            deltaH: -6.0,
            collapsed: true,
            tokenCount: 512,
            backend: "vllm",
            agent: "codex"
        )
        let agents = [
            liveAgent(id: "codex", task: "tooling"),
            liveAgent(id: "claude_code", task: "docs"),
        ]
        let rows = AgentStateRosterPublish.snapshots(
            activityAgents: agents,
            bridgeConnected: true,
            bridgeStatus: status,
            gateDBAvailable: true,
            now: now
        )
        XCTAssertEqual(rows.count, 2)
        let codex = try! XCTUnwrap(rows.first { $0.id == "codex" })
        let other = try! XCTUnwrap(rows.first { $0.id == "claude_code" })
        XCTAssertTrue(codex.isCollapsed)
        XCTAssertEqual(codex.activity, .blocked)
        XCTAssertEqual(codex.entropyBits ?? 0, 2.1, accuracy: 0.001)
        XCTAssertEqual(codex.entropyDelta ?? 0, -6.0, accuracy: 0.001)
        XCTAssertNil(other.entropyBits, "unnamed / other-agent bridge H must not copy")
        XCTAssertFalse(other.isCollapsed)
    }

    // MARK: Bridge-only fallback

    func testEmptyRosterFallsBackToBridgeAggregate() {
        let status = ShannonStatus(
            entropy: 9.4,
            deltaH: 0.3,
            collapsed: false,
            tokenCount: 77,
            backend: "cpp",
            agent: "flexaid"
        )
        let rows = AgentStateRosterPublish.snapshots(
            activityAgents: [],
            bridgeConnected: true,
            bridgeStatus: status,
            now: now
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "flexaid")
        XCTAssertEqual(rows[0].entropyBits ?? 0, 9.4, accuracy: 0.001)
        XCTAssertFalse(rows[0].isCollapsed)
    }

    func testEmptyRosterDemoBridgeStillFailClosed() {
        let demo = ShannonStatus(
            entropy: 6.2,
            deltaH: -1.9,
            collapsed: true,
            tokenCount: 9,
            backend: "demo",
            agent: "demo"
        )
        let rows = AgentStateRosterPublish.snapshots(
            activityAgents: [],
            bridgeConnected: true,
            bridgeStatus: demo,
            now: now
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].isCollapsed)
        XCTAssertNil(rows[0].entropyBits)
        XCTAssertNil(rows[0].entropyDelta)
    }

    func testNoRosterAndNoBridgePublishesNothing() {
        let rows = AgentStateRosterPublish.snapshots(
            activityAgents: [],
            bridgeConnected: false,
            bridgeStatus: nil,
            now: now
        )
        XCTAssertTrue(rows.isEmpty)
    }

    /// Agents that leave the live set are exactly those previously published
    /// minus the current snapshot ids (mirrors CloudPublisher retract bookkeeping).
    func testStaleAgentIDsArePreviousMinusLive() {
        let first = AgentStateRosterPublish.snapshots(
            activityAgents: [
                liveAgent(id: "a"),
                liveAgent(id: "b"),
            ],
            bridgeConnected: false,
            bridgeStatus: nil,
            now: now
        )
        let second = AgentStateRosterPublish.snapshots(
            activityAgents: [liveAgent(id: "a")],
            bridgeConnected: false,
            bridgeStatus: nil,
            now: now
        )
        let previous = Set(first.map(\.id))
        let live = Set(second.map(\.id))
        XCTAssertEqual(previous.subtracting(live), ["b"])
    }
}

// MARK: - Publisher integration (InMemorySyncBackend)

/// End-to-end: CloudPublisher.publish multi-agent roster + retract via a real
/// gate DB and in-memory CloudKit stand-in.
@MainActor
final class CloudPublisherRosterIntegrationTests: XCTestCase {

    private var home: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["SHANNON_LOG_DIR"]
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudroster-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SHANNON_LOG_DIR", home.path, 1)
        try makeSchema()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("SHANNON_LOG_DIR", previousHome, 1) }
        else { unsetenv("SHANNON_LOG_DIR") }
        try? FileManager.default.removeItem(at: home)
    }

    private var dbPath: String { home.appendingPathComponent("agent_hub.db").path }

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else { throw XCTSkip("cannot open temp sqlite db") }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            XCTFail("sqlite exec failed: \(msg)")
        }
    }

    private func makeSchema() throws {
        try exec("""
        CREATE TABLE agents (
            agent_id TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'idle',
            connected_at INTEGER, last_seen_ns INTEGER NOT NULL DEFAULT 0,
            disconnected_at INTEGER, task_id TEXT DEFAULT '',
            message_count INTEGER DEFAULT 0, entropy_score REAL DEFAULT 0.0,
            entropy_updated_ns INTEGER DEFAULT 0,
            task_summary TEXT DEFAULT '', auth_method TEXT DEFAULT 'socket_secret',
            heartbeat_ns INTEGER);
        CREATE TABLE agent_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT, received_at_ns INTEGER NOT NULL,
            agent_id TEXT NOT NULL, task_id TEXT NOT NULL, message_type TEXT NOT NULL,
            payload_json TEXT NOT NULL);
        CREATE TABLE agent_interactions (
            interaction_id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, prompt TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending', created_at_ns INTEGER NOT NULL,
            resolved_at_ns INTEGER);
        CREATE TABLE agent_activity (
            id INTEGER PRIMARY KEY AUTOINCREMENT, agent_id TEXT NOT NULL,
            event_at_ns INTEGER NOT NULL, event_type TEXT NOT NULL,
            event_label TEXT NOT NULL, event_output TEXT);
        """)
    }

    private func ns(_ secondsAgo: TimeInterval) -> Int64 {
        Int64((Date().timeIntervalSince1970 - secondsAgo) * 1_000_000_000)
    }

    private func insertLiveAgent(
        _ id: String,
        status: String = "active",
        task: String = "",
        bits: Double? = nil,
        secondsAgo: TimeInterval = 3
    ) throws {
        let last = ns(secondsAgo)
        let ent = bits.map { String($0) } ?? "0.0"
        let entNs = bits != nil ? "\(last)" : "0"
        try exec("""
        INSERT OR REPLACE INTO agents (
            agent_id, status, last_seen_ns, disconnected_at,
            entropy_score, entropy_updated_ns, message_count, task_summary, heartbeat_ns
        ) VALUES (
            '\(id)', '\(status)', \(last), NULL,
            \(ent), \(entNs), 2, '\(task)', \(last)
        );
        """)
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(label)")
    }

    func testPublishMirrorsTwoLiveAgentsFromGateDB() async throws {
        try insertLiveAgent("codex", task: "fix login", bits: 2.63)
        try insertLiveAgent("claude_code", task: "review", bits: 2.86)

        let monitor = AgentActivityMonitor(interval: 3600)
        monitor.refresh()
        try await waitUntil("gate agents to reach the monitor") {
            monitor.summary.agents.filter { $0.presence == .live }.count >= 2
        }

        let backend = InMemorySyncBackend()
        let publisher = CloudPublisher(
            nowPlaying: nil, battery: nil, bridge: nil,
            activity: monitor, backend: backend, interval: 3600, deviceName: "TestMac"
        )
        publisher.publish()
        try await waitUntil("two AgentState records") {
            backend.recordCount(AgentState.recordType) == 2
        }

        let published = try await backend.fetch(AgentState.self)
        let ids = Set(published.map(\.id))
        XCTAssertEqual(ids, ["codex", "claude_code"])
        // Gate H is measured message entropy — publish bits, never collapse.
        for row in published {
            XCTAssertNotNil(row.entropyBits, "measured gate H must publish for \(row.id)")
            XCTAssertFalse(row.isCollapsed)
        }
    }

    func testRetractAgentThatLeftTheLiveSet() async throws {
        try insertLiveAgent("codex", task: "A")
        try insertLiveAgent("claude_code", task: "B")

        let monitor = AgentActivityMonitor(interval: 3600)
        monitor.refresh()
        try await waitUntil("two live agents") {
            monitor.summary.agents.filter { $0.presence == .live }.count >= 2
        }

        let backend = InMemorySyncBackend()
        let publisher = CloudPublisher(
            nowPlaying: nil, battery: nil, bridge: nil,
            activity: monitor, backend: backend, interval: 3600, deviceName: "TestMac"
        )
        publisher.publish()
        try await waitUntil("initial two agents") {
            backend.recordCount(AgentState.recordType) == 2
        }

        // codex disconnects — leave only claude_code live.
        let gone = ns(3)
        try exec("""
        UPDATE agents SET disconnected_at = \(gone), heartbeat_ns = 0, status = 'idle'
        WHERE agent_id = 'codex';
        """)
        monitor.refresh()
        try await waitUntil("codex offline") {
            !monitor.summary.agents.contains { $0.id == "codex" && $0.presence == .live }
        }

        publisher.publish()
        try await waitUntil("codex retracted") {
            backend.recordCount(AgentState.recordType) == 1
        }
        let remaining = try await backend.fetch(AgentState.self)
        XCTAssertEqual(remaining.map(\.id), ["claude_code"])
    }

    func testDemoBridgeWithEmptyActivityStillDoesNotPublishCollapse() async throws {
        // activity with empty roster → bridge fallback; demo must stay fail-closed
        // (same contract as CloudPublisherProvenanceTests).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("pill.sock").path
        let stub = StubPillBridgeServer(
            path: socketPath,
            statusJSON: #"{"entropy":6.2,"delta_h":-1.9,"collapsed":true,"token_count":128,"backend":"demo","agent":"demo"}"#
        )
        try stub.start()
        defer { stub.stop() }

        let bridge = ShannonBridge(socketPath: socketPath, interval: 3600)
        bridge.poll()
        try await waitUntil("demo status") { bridge.status?.backend == "demo" }

        let monitor = AgentActivityMonitor(interval: 3600)
        // Empty agents: refresh with no gate agents → empty roster.
        monitor.refresh()
        try await Task.sleep(nanoseconds: 150_000_000)

        let sink = InMemorySyncBackend()
        let publisher = CloudPublisher(
            nowPlaying: nil, battery: nil, bridge: bridge,
            activity: monitor, backend: sink, interval: 3600, deviceName: "TestMac"
        )
        publisher.publish()
        try await waitUntil("bridge aggregate published") {
            sink.recordCount(AgentState.recordType) == 1
        }
        let states = try await sink.fetch(AgentState.self)
        let mirrored = try XCTUnwrap(states.first)
        XCTAssertFalse(mirrored.isCollapsed)
        XCTAssertNil(mirrored.entropyBits)
        XCTAssertNil(mirrored.entropyDelta)
    }
}
