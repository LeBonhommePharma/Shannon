import XCTest
import SQLite3
@testable import PillCore

/// The gate has been computing real per-agent entropy all along
/// (`agents.entropy_score` = `decision.computed_H`, written by
/// `update_agent_seen`), and `GateDBReader` explicitly read that column and threw
/// it away — `_ = sqlite3_column_double(stmt, 3)` — while the pill displayed a
/// hardcoded sine instead.
///
/// These run against a real SQLite file built with the hub's schema, so the SQL
/// is covered and not just the Swift around it.
final class GateEntropyProvenanceTests: XCTestCase {

    private var dir: URL!
    private var dbPath: String!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = EntropyPolicy(maxAge: 120, warnBits: 5, maxBits: 64, mode: .enforce)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-entropy-\(UUID().uuidString)", isDirectory: true)
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
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK, let db else {
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

    /// The hub's schema as of `shannon_gate.py` — `entropy_score REAL DEFAULT 0.0`.
    private func makeSchema() throws {
        try exec("""
        CREATE TABLE agents (
            agent_id TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'idle',
            connected_at INTEGER, last_seen_ns INTEGER NOT NULL DEFAULT 0,
            disconnected_at INTEGER, task_id TEXT DEFAULT '',
            message_count INTEGER DEFAULT 0, entropy_score REAL DEFAULT 0.0,
            task_summary TEXT DEFAULT '', auth_method TEXT DEFAULT 'socket_secret',
            heartbeat_ns INTEGER);
        CREATE TABLE agent_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT, received_at_ns INTEGER NOT NULL,
            agent_id TEXT NOT NULL, task_id TEXT NOT NULL, message_type TEXT NOT NULL,
            payload_json TEXT NOT NULL, gate_H REAL);
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
        Int64((now.timeIntervalSince1970 - secondsAgo) * 1_000_000_000)
    }

    private func read() -> [EntropyMeasurement] {
        GateDBReader.readAgentEntropy(path: dbPath, now: now, policy: policy)
    }

    // MARK: - The column is surfaced, not discarded

    /// The values are the operator's real ones: claude_code 2.86, codex 2.63.
    func testGateMeasuredEntropyIsSurfacedWithAgentAndTimestamp() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, entropy_score, message_count)
        VALUES ('claude_code', 'active', \(ns(5)), NULL, 2.86, 12),
               ('codex', 'active', \(ns(20)), NULL, 2.63, 7);
        """)
        let rows = read().sorted { $0.bits < $1.bits }
        guard rows.count == 2 else {
            return XCTFail("gate-computed entropy must reach the pill, got \(rows.count) rows")
        }
        XCTAssertEqual(rows[0].bits, 2.63, accuracy: 1e-9)
        XCTAssertEqual(rows[0].source, .gate(agentId: "codex", presence: .live))
        XCTAssertEqual(rows[0].measuredAt.timeIntervalSince1970,
                       now.timeIntervalSince1970 - 20, accuracy: 0.01,
                       "the reading must carry when it was measured")
        XCTAssertEqual(rows[0].age(at: now), 20, accuracy: 0.01)

        XCTAssertEqual(rows[1].bits, 2.86, accuracy: 1e-9)
        XCTAssertEqual(rows[1].source, .gate(agentId: "claude_code", presence: .live))
    }

    /// End to end: the DB value becomes the reading the whole pill agrees on.
    func testSnapshotEntropyFeedsAMeasuredReading() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, entropy_score)
        VALUES ('claude_code', 'active', \(ns(4)), NULL, 2.86);
        """)
        let snap = GateDBReader.readSnapshot(path: dbPath, now: now, entropyPolicy: policy)
        XCTAssertTrue(snap.available)
        XCTAssertEqual(snap.agentEntropy.count, 1)

        let reading = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil,
            gate: snap.agentEntropy, gateDBAvailable: snap.available,
            now: now, policy: policy
        )
        XCTAssertTrue(reading.isMeasured)
        XCTAssertEqual(reading.currentBits ?? 0, 2.86, accuracy: 1e-9)
        // Gate column is message score: 2.86 is normal, not collapse-watch.
        XCTAssertEqual(reading.verdict(policy: policy), .healthy,
                       "low H_msg must not paint as approaching collapse")
        XCTAssertEqual(reading.display(at: now, policy: policy)?.source,
                       .gate(agentId: "claude_code", presence: .live))
        XCTAssertEqual(reading.display(at: now, policy: policy)?.badge, "H_msg")
    }

    // MARK: - Staleness

    func testFortyMinuteOldGateReadingIsNotPresentedAsCurrent() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, entropy_score)
        VALUES ('claude_code', 'active', \(ns(40 * 60)), NULL, 2.86);
        """)
        let rows = read()
        guard rows.count == 1 else {
            return XCTFail("the value must still be surfaced — just not as current; got \(rows.count)")
        }
        XCTAssertEqual(rows[0].age(at: now), 2400, accuracy: 0.01)

        let reading = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil, gate: rows,
            gateDBAvailable: true, now: now, policy: policy
        )
        XCTAssertTrue(reading.isStale)
        XCTAssertNil(reading.currentBits)
        XCTAssertEqual(reading.verdict(policy: policy), .unknown)
        XCTAssertNil(reading.display(at: now, policy: policy), "enforce withholds a stale number")
    }

    /// A hung-up agent's last H is real, but it is not a reading about now.
    func testDisconnectedAgentEntropyCarriesOfflinePresence() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, entropy_score)
        VALUES ('claude_code', 'active', \(ns(10)), \(ns(5)), 2.86);
        """)
        let rows = read()
        guard rows.count == 1 else { return XCTFail("expected 1 row, got \(rows.count)") }
        XCTAssertEqual(rows[0].source, .gate(agentId: "claude_code", presence: .offline))
        XCTAssertFalse(rows[0].source.canBeCurrent)

        let reading = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil, gate: rows,
            gateDBAvailable: true, now: now, policy: policy
        )
        XCTAssertTrue(reading.isStale, "fresh timestamp, dead agent — still not current")
        XCTAssertNil(reading.currentBits)
    }

    // MARK: - Fail closed

    /// `entropy_score REAL DEFAULT 0.0` means an unscored row is
    /// indistinguishable from a genuine zero. Refuse both: rendering 0.00 bits
    /// would be a false collapse alarm, and false alarms get monitors disabled.
    func testUnscoredRowProducesNoMeasurementRatherThanZeroBits() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('never_scored', 'active', \(ns(3)), NULL);
        """)
        XCTAssertTrue(read().isEmpty, "the DEFAULT 0.0 must never become a displayed value")

        // …and the agent itself still reads normally; only the number is absent.
        XCTAssertEqual(GateDBReader.readAgents(path: dbPath, now: now).count, 1)

        let reading = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil, gate: read(),
            gateDBAvailable: true, now: now, policy: policy
        )
        XCTAssertEqual(reading.absence, .noDetector)
        XCTAssertNotEqual(reading.verdict(policy: policy), .healthy)
    }

    func testExplicitNullEntropyProducesNoMeasurement() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, entropy_score)
        VALUES ('nulled', 'active', \(ns(3)), NULL, NULL);
        """)
        XCTAssertTrue(read().isEmpty)
    }

    func testRowWithoutTimestampProducesNoMeasurement() throws {
        // A value that cannot be aged must never be called current.
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, entropy_score)
        VALUES ('no_clock', 'active', 0, NULL, 2.86);
        """)
        XCTAssertTrue(read().isEmpty)
    }

    func testOversizedAndNegativeEntropyRowsAreRefused() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, entropy_score)
        VALUES ('huge', 'active', \(ns(3)), NULL, 1e9),
               ('negative', 'active', \(ns(3)), NULL, -4.0),
               ('sane', 'active', \(ns(3)), NULL, 3.25);
        """)
        let rows = read()
        guard rows.count == 1 else {
            return XCTFail("only the plausible row should survive, got \(rows.count)")
        }
        XCTAssertEqual(rows[0].bits, 3.25, accuracy: 1e-9)
    }

    /// Clock skew must not be able to make an old value look current.
    func testFutureDatedRowIsRefused() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, entropy_score)
        VALUES ('skewed', 'active', \(ns(-3600)), NULL, 2.86);
        """)
        XCTAssertTrue(read().isEmpty, "a future-dated row is corrupt, not fresh")
    }

    func testMissingDatabaseYieldsNoMeasurementsAndAnAbsentReading() {
        let missing = dir.appendingPathComponent("nope.db").path
        XCTAssertTrue(GateDBReader.readAgentEntropy(path: missing, now: now, policy: policy).isEmpty)

        let snap = GateDBReader.readSnapshot(path: missing, now: now, entropyPolicy: policy)
        XCTAssertFalse(snap.available)
        let reading = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil,
            gate: snap.agentEntropy, gateDBAvailable: snap.available,
            now: now, policy: policy
        )
        XCTAssertEqual(reading.absence, .gateUnavailable)
        XCTAssertNil(reading.currentBits)
    }

    // MARK: - Migration safety

    /// The user's existing DB is read in place; nothing is written and no
    /// migration is required, because `entropy_score` has been in the schema all
    /// along. This proves the read is non-destructive and works read-only.
    func testReaderNeverWritesToTheDatabase() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, entropy_score)
        VALUES ('claude_code', 'active', \(ns(5)), NULL, 2.86);
        """)
        let attrs = try FileManager.default.attributesOfItem(atPath: dbPath)
        let sizeBefore = attrs[.size] as? Int
        let modifiedBefore = attrs[.modificationDate] as? Date

        _ = read()
        _ = GateDBReader.readSnapshot(path: dbPath, now: now, entropyPolicy: policy)

        let after = try FileManager.default.attributesOfItem(atPath: dbPath)
        XCTAssertEqual(after[.size] as? Int, sizeBefore)
        XCTAssertEqual(after[.modificationDate] as? Date, modifiedBefore)
    }

    /// A database written by a gate that predates `entropy_score` entirely must
    /// still list its agents. Every entropy-bearing SELECT names the column, so
    /// without the no-entropy fallback the agent list itself would go empty —
    /// a schema-old DB would silently lose all telemetry.
    func testDatabaseWithoutEntropyColumnStillReadsAgentsWithNoEntropy() throws {
        let legacyPath = dir.appendingPathComponent("legacy.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(legacyPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK, let db else {
            throw XCTSkip("cannot open temp sqlite db")
        }
        sqlite3_exec(db, """
            CREATE TABLE agents (
                agent_id TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'idle',
                last_seen REAL, task_summary TEXT DEFAULT '');
            INSERT INTO agents (agent_id, status, last_seen, task_summary)
            VALUES ('old_agent', 'active', \(now.timeIntervalSince1970 - 30), 'legacy row');
            """, nil, nil, nil)
        sqlite3_close(db)

        let agents = GateDBReader.readAgents(path: legacyPath, now: now)
        guard agents.count == 1 else {
            return XCTFail("a pre-entropy_score DB must not lose its agents; got \(agents.count)")
        }
        XCTAssertEqual(agents[0].id, "old_agent")
        XCTAssertTrue(
            GateDBReader.readAgentEntropy(path: legacyPath, now: now, policy: policy).isEmpty,
            "no column means no measurement — never a fabricated one"
        )
    }

    // MARK: - Determinism

    func testRepeatedReadsOfTheSameDatabaseAgree() throws {
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at, entropy_score)
        VALUES ('a', 'active', \(ns(5)), NULL, 3.0),
               ('b', 'active', \(ns(5)), NULL, 4.0),
               ('c', 'active', \(ns(9)), NULL, 5.0);
        """)
        let first = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil, gate: read(),
            gateDBAvailable: true, now: now, policy: policy
        )
        for _ in 0..<10 {
            let again = EntropyProvenance.resolve(
                bridgeConnected: false, bridgeStatus: nil, gate: read(),
                gateDBAvailable: true, now: now, policy: policy
            )
            XCTAssertEqual(again, first)
        }
        XCTAssertEqual(first.currentBits ?? 0, 3.0, accuracy: 1e-9,
                       "tie on timestamp breaks on agent id 'a'")
    }
}
