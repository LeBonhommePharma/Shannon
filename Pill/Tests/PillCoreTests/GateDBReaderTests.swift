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

    /// A DB written by a gate that predates `heartbeat_ns` must still read —
    /// the reader falls back to the older SELECT and reports "no evidence"
    /// rather than a stale beat.
    func testSchemaWithoutHeartbeatReadsWithNoBeat() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('science', 'active', \(ns(5)), NULL);
        """)
        let rows = GateDBReader.readAgents(path: dbPath)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].heartbeatAt)
        XCTAssertEqual(rows[0].presence, .live)
    }

    /// With the column present, the beat is what proves the connection is open.
    /// `last_seen_ns` stays what it always was: when the agent last *spoke*.
    func testHeartbeatIsReadAndKeepsQuietAgentLive() throws {
        try exec("ALTER TABLE agents ADD COLUMN heartbeat_ns INTEGER;")
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, heartbeat_ns, task_summary)
        VALUES ('science', 'active', \(ns(3 * 3600)), NULL, \(ns(4)), 'docking 1SG0');
        """)
        let rows = GateDBReader.readAgents(path: dbPath)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].heartbeatAt)
        XCTAssertEqual(
            rows[0].updatedAt.timeIntervalSinceNow, -3 * 3600, accuracy: 5,
            "last_seen must keep meaning last activity, not last heartbeat"
        )

        let full = AgentActivityReader.loadFull(
            petsRoot: dir.appendingPathComponent("pets", isDirectory: true),
            registryURL: dir.appendingPathComponent("agents.json"),
            gateDB: URL(fileURLWithPath: dbPath)
        )
        let a = try XCTUnwrap(full.summary.agents.first)
        XCTAssertEqual(a.presence, .live, "connected and quiet is not offline")
        XCTAssertEqual(a.status, .idle, "…but it is not working either")
        // Quiet live attach: statusLine is "live" (not "idle" — idle looked unattached).
        XCTAssertEqual(a.statusLine, "live")
        XCTAssertEqual(a.relativeAge, "3h")
    }

    /// The case the heartbeat exists for: the gate was killed, so its `finally`
    /// never stamped `disconnected_at` and the row still claims a connection.
    /// A stale beat settles it — offline, even though the agent spoke recently.
    func testStaleHeartbeatIsOfflineDespiteOpenRow() throws {
        try exec("ALTER TABLE agents ADD COLUMN heartbeat_ns INTEGER;")
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, heartbeat_ns)
        VALUES ('science', 'active', \(ns(20)), NULL, \(ns(600)));
        """)
        let full = AgentActivityReader.loadFull(
            petsRoot: dir.appendingPathComponent("pets", isDirectory: true),
            registryURL: dir.appendingPathComponent("agents.json"),
            gateDB: URL(fileURLWithPath: dbPath)
        )
        let a = try XCTUnwrap(full.summary.agents.first)
        XCTAssertEqual(a.presence, .offline)
        XCTAssertEqual(a.status, .idle)
        XCTAssertEqual(full.summary.busyCount, 0)
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
        // ENH-031: no payload → no invented paths.
        XCTAssertTrue(snap.pendingAsks[0].changePaths.isEmpty)
        XCTAssertNil(snap.pendingAsks[0].changeSummary)
        XCTAssertTrue(snap.pendingAsks[0].changePathsPresentation.isEmpty)
    }

    /// ENH-031: paths/summary from agent_messages payload when interaction_id matches.
    func testAskSurfacesChangePathsFromMatchingPayload() throws {
        let payload = """
        {"interaction_id":"ask-paths","approval_needed":true,"paths":["src/a.swift","src/b.swift"],"change_summary":"Two file edit"}
        """
        // Escape single quotes for SQL string literal.
        let escaped = payload.replacingOccurrences(of: "'", with: "''")
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('science', 'active', \(ns(2)), NULL);
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('ask-paths', 'science', 'Apply edit?', 'pending', \(ns(10)));
        INSERT INTO agent_messages (received_at_ns, agent_id, task_id, message_type, payload_json)
        VALUES (\(ns(10)), 'science', 't', 'approval_needed', '\(escaped)');
        """)
        let ask = try XCTUnwrap(GateDBReader.readSnapshot(path: dbPath).pendingAsks.first)
        XCTAssertEqual(ask.interactionId, "ask-paths")
        XCTAssertEqual(ask.changePaths, ["src/a.swift", "src/b.swift"])
        XCTAssertEqual(ask.changeSummary, "Two file edit")
        let presentation = ask.changePathsPresentation
        XCTAssertFalse(presentation.isEmpty)
        XCTAssertEqual(presentation.summary, "Two file edit")
        XCTAssertEqual(presentation.pathLines, ["src/a.swift", "src/b.swift"])
    }

    /// ENH-031: prompt text that merely *names* a path must not invent changePaths.
    func testAskDoesNotInventPathsFromPromptProse() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('science', 'active', \(ns(2)), NULL);
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('ask-prose', 'science', 'Edit /Users/me/main.py and util.ts?', 'pending', \(ns(10)));
        INSERT INTO agent_messages (received_at_ns, agent_id, task_id, message_type, payload_json)
        VALUES (\(ns(10)), 'science', 't', 'approval_needed',
                '{"interaction_id":"ask-prose","prompt":"Edit /Users/me/main.py and util.ts?"}');
        """)
        let ask = try XCTUnwrap(GateDBReader.readSnapshot(path: dbPath).pendingAsks.first)
        XCTAssertTrue(ask.changePaths.isEmpty)
        XCTAssertNil(ask.changeSummary)
        XCTAssertTrue(ask.changePathsPresentation.isEmpty)
    }

    /// ENH-031: payload for a *different* interaction_id must not leak paths.
    func testAskIgnoresPathsFromOtherInteraction() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('science', 'active', \(ns(2)), NULL);
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('ask-live', 'science', 'Proceed?', 'pending', \(ns(10)));
        INSERT INTO agent_messages (received_at_ns, agent_id, task_id, message_type, payload_json)
        VALUES (\(ns(5)), 'science', 't', 'approval_needed',
                '{"interaction_id":"ask-other","paths":["secret.swift"]}');
        """)
        let ask = try XCTUnwrap(GateDBReader.readSnapshot(path: dbPath).pendingAsks.first)
        XCTAssertEqual(ask.interactionId, "ask-live")
        XCTAssertTrue(ask.changePaths.isEmpty, "must not attribute another ask's paths")
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

    /// The row limit must bound *actionable* asks, not raw rows. Five abandoned
    /// approvals used to fill the `LIMIT 5` before the orphan filter ever ran,
    /// so the one ask a human could answer was never fetched — invisible in the
    /// pill, unanswerable, forever.
    func testOrphanedAsksDoNotCrowdOutAnActionableOne() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('ghost', 'idle', \(ns(3600)), \(ns(60))),
               ('science', 'active', \(ns(2)), NULL);
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('ghost-1', 'ghost', 'dead 1?', 'pending', \(ns(300))),
               ('ghost-2', 'ghost', 'dead 2?', 'pending', \(ns(301))),
               ('ghost-3', 'ghost', 'dead 3?', 'pending', \(ns(302))),
               ('ghost-4', 'ghost', 'dead 4?', 'pending', \(ns(303))),
               ('ghost-5', 'ghost', 'dead 5?', 'pending', \(ns(304))),
               ('ghost-6', 'ghost', 'dead 6?', 'pending', \(ns(305))),
               ('live-1',  'science', 'Dock 1G9V?', 'pending', \(ns(600)));
        """)
        let snap = GateDBReader.readSnapshot(path: dbPath)
        XCTAssertEqual(
            snap.pendingAsks.map(\.interactionId), ["live-1"],
            "the answerable ask must survive six newer orphans"
        )
        XCTAssertEqual(snap.staleAsks.count, 6)
        XCTAssertEqual(GateDBReader.readPendingAsks(path: dbPath).map(\.interactionId), ["live-1"])
    }

    /// …and it must survive a backlog far larger than anything we are willing
    /// to read: the bound on the fetch must not reintroduce the crowding-out.
    func testHugeOrphanBacklogStillSurfacesTheLiveAsk() throws {
        var rows: [String] = ["('live-1', 'science', 'Dock 1G9V?', 'pending', \(ns(400)))"]
        for i in 0..<200 {
            rows.append("('ghost-\(i)', 'ghost', 'dead \(i)?', 'pending', \(ns(Double(i) + 1)))")
        }
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('ghost', 'idle', \(ns(3600)), \(ns(0.5))),
               ('science', 'active', \(ns(2)), NULL);
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES \(rows.joined(separator: ",\n"));
        """)
        let snap = GateDBReader.readSnapshot(path: dbPath)
        XCTAssertEqual(snap.pendingAsks.map(\.interactionId), ["live-1"])
        XCTAssertLessThanOrEqual(
            snap.pendingAsks.count + snap.staleAsks.count, 64,
            "a pathological interactions table must not be read in full"
        )
    }

    /// The age backstop must classify the same rows the new SQL ordering
    /// prioritises — one clock in Swift, one cutoff in SQL, same answer.
    func testAgeBackstopAgreesWithTheSQLCutoff() throws {
        try exec("""
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('aged',  'mystery', 'yesterday?', 'pending', \(ns(7 * 3600))),
               ('fresh', 'mystery', 'just now?',  'pending', \(ns(5 * 3600)));
        """)
        let snap = GateDBReader.readSnapshot(path: dbPath)
        XCTAssertEqual(snap.pendingAsks.map(\.interactionId), ["fresh"])
        XCTAssertEqual(snap.staleAsks.map(\.interactionId), ["aged"])
        // A tighter window ages both out; a wider one keeps both.
        XCTAssertTrue(GateDBReader.readPendingAsks(path: dbPath, maxAge: 3600).isEmpty)
        XCTAssertEqual(
            GateDBReader.readPendingAsks(path: dbPath, maxAge: 48 * 3600).map(\.interactionId),
            ["fresh", "aged"]
        )
    }

    /// The limit still applies — to actionable asks — and the raw fetch stays
    /// bounded so a pathological table is never loaded whole.
    func testActionableAsksAreStillCapped() throws {
        var rows: [String] = []
        for i in 0..<300 {
            rows.append("('live-\(i)', 'mystery', 'ask \(i)?', 'pending', \(ns(Double(i) + 1)))")
        }
        try exec("""
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES \(rows.joined(separator: ",\n"));
        """)
        let snap = GateDBReader.readSnapshot(path: dbPath, askLimit: 3)
        XCTAssertEqual(snap.pendingAsks.map(\.interactionId), ["live-0", "live-1", "live-2"])
        XCTAssertLessThanOrEqual(
            snap.pendingAsks.count + snap.staleAsks.count, 64,
            "a pathological interactions table must not be read in full"
        )
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
        // Legacy schema without tool_kind column: toolKind stays nil.
        XCTAssertNil(feed[0].toolKind)
        XCTAssertNil(feed[1].toolKind)
    }

    /// ENH-017: when tool_kind is present, reader maps it; empty → nil.
    func testActivityFeedReadsOptionalToolKind() throws {
        try exec("""
        ALTER TABLE agent_activity ADD COLUMN tool_kind TEXT;
        INSERT INTO agent_activity
            (agent_id, event_at_ns, event_type, event_label, event_output, tool_kind)
        VALUES ('codex', \(ns(5)), 'tool_call', 'patch store.ts', 'ok', 'edit'),
               ('science', \(ns(15)), 'tool_call', 'ls', 'done', NULL);
        """)
        let feed = GateDBReader.readRecentActivity(path: dbPath, limit: 5)
        XCTAssertEqual(feed.count, 2)
        XCTAssertEqual(feed[0].agentId, "codex")
        XCTAssertEqual(feed[0].toolKind, "edit")
        XCTAssertEqual(feed[1].agentId, "science")
        XCTAssertNil(feed[1].toolKind)
    }

    // MARK: - Robustness

    func testMissingDatabaseIsEmptyNotUnavailable() {
        let snap = GateDBReader.readSnapshot(path: dir.appendingPathComponent("nope.db").path)
        XCTAssertFalse(snap.available)
        XCTAssertTrue(snap.agents.isEmpty)
        XCTAssertTrue(snap.pendingAsks.isEmpty)
        XCTAssertTrue(snap.activity.isEmpty)
        XCTAssertNil(snap.benchmark, "missing DB must not invent a benchmark row")
    }

    /// FlexAIDdS hub: `benchmark_state` is optional; absent table → nil (fail-closed).
    func testBenchmarkStateAbsentIsNilNotInvented() throws {
        let snap = GateDBReader.readSnapshot(path: dbPath)
        XCTAssertTrue(snap.available)
        XCTAssertNil(snap.benchmark)
    }

    /// Real gate row flows into Snapshot + loadFull (agentic hub binding).
    func testBenchmarkStateRowIsReadHonestly() throws {
        let updated = ns(30)
        try exec("""
        CREATE TABLE benchmark_state (
            task_id TEXT PRIMARY KEY,
            completed INTEGER NOT NULL DEFAULT 0,
            total INTEGER NOT NULL DEFAULT 0,
            best_cf REAL,
            best_rmsd REAL,
            active_target TEXT,
            updated_at INTEGER NOT NULL
        );
        INSERT INTO benchmark_state
            (task_id, completed, total, best_cf, best_rmsd, active_target, updated_at)
        VALUES ('benchmark_v133_astex85', 34, 85, -12.5, 1.42, '1hpv', \(updated));
        """)
        let snap = GateDBReader.readSnapshot(path: dbPath)
        XCTAssertNotNil(snap.benchmark)
        XCTAssertEqual(snap.benchmark?.taskId, "benchmark_v133_astex85")
        XCTAssertEqual(snap.benchmark?.completed, 34)
        XCTAssertEqual(snap.benchmark?.total, 85)
        XCTAssertEqual(snap.benchmark?.countLabel, "34/85")
        XCTAssertEqual(snap.benchmark?.activeTarget, "1hpv")
        XCTAssertEqual(snap.benchmark?.bestRMSD ?? 0, 1.42, accuracy: 1e-9)
        // No invented success % — only gate fields.
        XCTAssertFalse(snap.benchmark?.shortLabel.contains("%") ?? true)

        let full = AgentActivityReader.loadFull(
            petsRoot: dir.appendingPathComponent("pets_empty", isDirectory: true),
            registryURL: dir.appendingPathComponent("agents.json"),
            gateDB: URL(fileURLWithPath: dbPath)
        )
        XCTAssertEqual(full.benchmark?.countLabel, "34/85")
        XCTAssertEqual(full.benchmark?.activeTarget, "1hpv")
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
