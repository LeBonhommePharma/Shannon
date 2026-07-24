import XCTest
import SQLite3
@testable import PillCore

/// Exercises the reader against a real SQLite file built with the hub's schema,
/// so the SQL itself (not just the Swift around it) is covered.
final class GateDBReaderTests: XCTestCase {

    private var dir: URL!
    private var dbPath: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gatedb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("agent_hub.db").path
        try makeSchema()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixture

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else {
            throw XCTSkip("cannot open temp sqlite db")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            XCTFail("sqlite exec failed: \(msg)\n\(sql)")
        }
    }

    private func makeSchema() throws {
        try exec("""
        CREATE TABLE agents (
            agent_id TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'idle',
            connected_at INTEGER, last_seen_ns INTEGER NOT NULL DEFAULT 0,
            disconnected_at INTEGER, task_id TEXT DEFAULT '',
            message_count INTEGER DEFAULT 0, entropy_score REAL DEFAULT 0.0,
            task_summary TEXT DEFAULT '', auth_method TEXT DEFAULT 'socket_secret');
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

    // MARK: - Agents

    func testDisconnectedAgentIsOfflineAndNotBusy() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, task_summary)
        VALUES ('claude_code', 'active', \(ns(40 * 3600)), \(ns(40 * 3600 - 1)), 'e2e status');
        """)
        let rows = GateDBReader.readAgents(path: dbPath)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].presence, .offline)
        XCTAssertEqual(rows[0].status, .idle, "a hung-up agent is never busy")
        XCTAssertFalse(rows[0].status.isBusy)
    }

    func testConnectedAgentStaysLive() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, task_summary)
        VALUES ('science', 'active', \(ns(5)), NULL, 'docking 1SG0');
        """)
        let rows = GateDBReader.readAgents(path: dbPath)
        XCTAssertEqual(rows[0].presence, .live)
        XCTAssertEqual(rows[0].status, .active)
        XCTAssertTrue(rows[0].status.isBusy)
    }

    /// The gate under-counts `message_count`; the real rows win.
    func testMessageCountUsesRealRowsWhenHigher() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, message_count)
        VALUES ('grok_build', 'idle', \(ns(60)), 1);
        INSERT INTO agent_messages (received_at_ns, agent_id, task_id, message_type, payload_json)
        VALUES (\(ns(60)), 'grok_build', 't', 'status', '{}'),
               (\(ns(59)), 'grok_build', 't', 'status', '{}'),
               (\(ns(58)), 'grok_build', 't', 'status', '{}'),
               (\(ns(57)), 'grok_build', 't', 'status', '{}'),
               (\(ns(56)), 'grok_build', 't', 'status', '{}');
        """)
        XCTAssertEqual(GateDBReader.readAgents(path: dbPath).first?.historyCount, 5)
    }

    // MARK: - Approvals

    func testOrphanedAskIsNotActionable() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('science', 'idle', \(ns(3600)), \(ns(60)));
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('ask-old', 'science', 'Apply Softb canary?', 'pending', \(ns(7200)));
        """)
        let snap = GateDBReader.readSnapshot(path: dbPath)
        XCTAssertTrue(snap.pendingAsks.isEmpty, "agent disconnected after asking — nobody is waiting")
        XCTAssertEqual(snap.staleAsks.count, 1)
        XCTAssertTrue(snap.staleAsks[0].isOrphaned)
        XCTAssertEqual(GateDBReader.readPendingAsks(path: dbPath).count, 0)
    }

    func testLiveAskIsActionable() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('science', 'active', \(ns(2)), NULL);
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('ask-now', 'science', 'Dock 1G9V?', 'pending', \(ns(30)));
        """)
        let snap = GateDBReader.readSnapshot(path: dbPath)
        XCTAssertEqual(snap.pendingAsks.count, 1)
        XCTAssertEqual(snap.pendingAsks[0].interactionId, "ask-now")
        XCTAssertFalse(snap.pendingAsks[0].isOrphaned)
        XCTAssertEqual(snap.pendingAsks[0].waitingFor, "30s")
        XCTAssertTrue(snap.staleAsks.isEmpty)
    }

    /// An ask from an agent the `agents` table never saw cannot be proven dead,
    /// so it stays actionable — we only drop what we can prove.
    func testAskFromUnknownAgentSurvives() throws {
        try exec("""
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('ask-x', 'mystery', 'proceed?', 'pending', \(ns(30)));
        """)
        XCTAssertEqual(GateDBReader.readSnapshot(path: dbPath).pendingAsks.count, 1)
    }

    func testResolvedAsksAreIgnored() throws {
        try exec("""
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('ask-done', 'science', 'ok?', 'approved', \(ns(30)));
        """)
        XCTAssertTrue(GateDBReader.readSnapshot(path: dbPath).pendingAsks.isEmpty)
    }

    // MARK: - Activity feed

    func testActivityFeedIsNewestFirstAndAttributed() throws {
        try exec("""
        INSERT INTO agent_activity (agent_id, event_at_ns, event_type, event_label, event_output)
        VALUES ('science',    \(ns(300)), 'status',   'older event',  'out1'),
               ('local_test', \(ns(10)),  'approval_response', 'approved: ask-1', 'out2'),
               ('codex',      \(ns(120)), 'tool_call', 'Dock(1SG0)',  'CF=-187.3');
        """)
        let feed = GateDBReader.readRecentActivity(path: dbPath, limit: 5)
        XCTAssertEqual(feed.map(\.agentId), ["local_test", "codex", "science"])
        XCTAssertEqual(feed[0].label, "approved: ask-1")
        XCTAssertEqual(feed[1].type, "tool_call")
        XCTAssertEqual(feed[2].relativeAge, "5m")
    }

    // MARK: - Robustness

    func testMissingDatabaseIsEmptyNotUnavailable() {
        let snap = GateDBReader.readSnapshot(path: dir.appendingPathComponent("nope.db").path)
        XCTAssertFalse(snap.available)
        XCTAssertTrue(snap.agents.isEmpty)
        XCTAssertTrue(snap.pendingAsks.isEmpty)
        XCTAssertTrue(snap.activity.isEmpty)
    }

    /// End-to-end through the merge layer: a stale ⌘D pet plus a disconnected
    /// gate row must produce zero "active agents".
    func testLoadFullReportsNoFalseActivity() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, task_summary)
        VALUES ('claude_code', 'active', \(ns(40 * 3600)), \(ns(40 * 3600 - 1)), 'e2e status'),
               ('terminal',    'active', \(ns(40 * 3600)), \(ns(40 * 3600 - 1)), '');
        """)
        let pets = dir.appendingPathComponent("pets", isDirectory: true)
        for id in ["claude_code", "terminal"] {
            let d = pets.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: [
                "status": "active", "last_task": "Working in \(id)",
                "updated_at": Date().timeIntervalSince1970, "resumable": true,
            ]).write(to: d.appendingPathComponent("state.json"))
        }
        let full = AgentActivityReader.loadFull(
            petsRoot: pets,
            registryURL: dir.appendingPathComponent("agents.json"),
            gateDB: URL(fileURLWithPath: dbPath)
        )
        XCTAssertTrue(full.gateDBAvailable)
        XCTAssertEqual(full.summary.busyCount, 0)
        XCTAssertEqual(full.summary.connected.count, 0)
        XCTAssertEqual(full.summary.agents.count, 2)
        XCTAssertTrue(full.summary.agents.allSatisfy { $0.presence == .offline })
        // Labels survive — we removed the lie, not the information.
        XCTAssertTrue(full.summary.agents.contains { $0.lastTask == "e2e status" })
    }
}
