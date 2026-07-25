import XCTest
import SQLite3
@testable import PillCore

/// Adversarial coverage for the two `pillcore-data` defects, written against
/// angles the original fix tests do not reach:
///
///  * **Defect 4** (`readPendingAsks` applied the SQL `LIMIT` to raw rows) —
///    the existing tests crowd the fetch with *orphans only* and only ever
///    assert through `GateDBReader` directly. These push mixed stale kinds past
///    the fetch window, ask for a full `askLimit` of survivors rather than one,
///    and go through `AgentActivityReader.loadFull` — the path the pill
///    actually polls.
///  * **Defect 6** (lowercased registry bundle vs case-preserving NSWorkspace) —
///    the existing test covers one id via `load`. These cover the whole family
///    of mixed-case ids the mapper can store, and the `loadFull` hop.
///
/// Every test whose name says "survives"/"folds" fails on the pre-fix sources.
final class GateAskAndBundleCaseTests: XCTestCase {

    private var dir: URL!
    private var dbPath: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("agent_hub.db").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixture

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

    /// Mirrors `shannon_gate.py`'s schema, including `created_at_ns NOT NULL`.
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

    private func makePet(_ root: URL, id: String, bundle: String) throws -> URL {
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let petDir = pets.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "status": "active", "last_task": "editing",
            "updated_at": Date().timeIntervalSince1970, "resumable": true,
        ]).write(to: petDir.appendingPathComponent("state.json"))
        try JSONSerialization.data(withJSONObject: [[
            "id": id, "display_name": id, "source": "ide",
            "bundle": bundle, "updated_at": Date().timeIntervalSince1970,
        ]]).write(to: root.appendingPathComponent("agents.json"))
        return pets
    }

    // MARK: - Defect 4: the fetch window must never bury an answerable ask

    /// Both kinds of stale at once — orphans *newer* than the live ask plus a
    /// pile that aged out — totalling more rows than the fetch window.
    func testMixedStaleKindsDoNotBuryTheLiveAsk() throws {
        try makeSchema()
        var rows = ["('live-1', 'science', 'Dock 1G9V?', 'pending', \(ns(60)))"]
        for i in 0..<10 {
            rows.append("('ghost-\(i)', 'ghost', 'dead?', 'pending', \(ns(Double(i) + 1)))")
        }
        for i in 0..<15 {
            rows.append("('old-\(i)', 'science', 'ancient?', 'pending', \(ns(7 * 3600 + Double(i))))")
        }
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('ghost', 'idle', \(ns(3600)), \(ns(0.5))),
               ('science', 'active', \(ns(2)), NULL);
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES \(rows.joined(separator: ","));
        """)
        XCTAssertEqual(
            GateDBReader.readSnapshot(path: dbPath).pendingAsks.map(\.interactionId), ["live-1"],
            "orphans and aged rows together must not bury the answerable ask"
        )
    }

    /// A *full* `askLimit` of answerable asks hidden behind a backlog far
    /// larger than the fetch window: all five come back, newest first.
    func testFullLimitOfLiveAsksSurvivesABacklogLargerThanTheFetch() throws {
        try makeSchema()
        var rows: [String] = []
        for i in 0..<5 {
            rows.append("('live-\(i)', 'science', 'ask \(i)?', 'pending', \(ns(Double(i) + 100)))")
        }
        for i in 0..<300 {
            rows.append("('ghost-\(i)', 'ghost', 'dead?', 'pending', \(ns(Double(i) / 10 + 1)))")
        }
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('ghost', 'idle', \(ns(3600)), \(ns(0.5))),
               ('science', 'active', \(ns(2)), NULL);
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES \(rows.joined(separator: ","));
        """)
        XCTAssertEqual(
            GateDBReader.readSnapshot(path: dbPath).pendingAsks.map(\.interactionId),
            ["live-0", "live-1", "live-2", "live-3", "live-4"]
        )
    }

    /// The pill does not call `GateDBReader` directly — it polls `loadFull`.
    /// Assert the survivor reaches the surface the user actually sees.
    func testLoadFullSurfacesTheLiveAskBehindABacklog() throws {
        try makeSchema()
        var rows = ["('live-1', 'science', 'Dock 1G9V?', 'pending', \(ns(60)))"]
        for i in 0..<100 {
            rows.append("('ghost-\(i)', 'ghost', 'dead?', 'pending', \(ns(Double(i) / 10 + 1)))")
        }
        try exec("""
        INSERT INTO agents (agent_id, status, last_seen_ns, disconnected_at)
        VALUES ('ghost', 'idle', \(ns(3600)), \(ns(0.5))),
               ('science', 'active', \(ns(2)), NULL);
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES \(rows.joined(separator: ","));
        """)
        let full = AgentActivityReader.loadFull(
            petsRoot: dir.appendingPathComponent("pets", isDirectory: true),
            registryURL: dir.appendingPathComponent("agents.json"),
            gateDB: URL(fileURLWithPath: dbPath)
        )
        XCTAssertEqual(full.pendingAsks.map(\.interactionId), ["live-1"])
    }

    // MARK: - Defect 4: the new SQL cutoff must not be able to hide everything

    /// `staleCutoffNs` is interpolated into the SQL as a bare `Int64` literal.
    /// If a clamped value (`Int64.min`) made `sqlite3_prepare_v2` fail, the
    /// reader would return [] and *every* ask would silently vanish from the
    /// pill. Exercise both clamp branches through the real query.
    func testClampedCutoffsNeverSilentlyHideEveryAsk() throws {
        try makeSchema()
        try exec("""
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('a1', 'mystery', 'proceed?', 'pending', \(ns(30)));
        """)
        // Int64.min branch — "never age anything out".
        XCTAssertEqual(
            GateDBReader.readPendingAsks(path: dbPath, maxAge: .greatestFiniteMagnitude)
                .map(\.interactionId), ["a1"]
        )
        XCTAssertEqual(
            GateDBReader.readPendingAsks(path: dbPath, maxAge: .infinity).map(\.interactionId), ["a1"]
        )
        // Int64.max branch — "everything has aged out" must still be *reported*,
        // as stale, not dropped on the floor.
        let aged = GateDBReader.readSnapshot(path: dbPath, askMaxAge: -.infinity)
        XCTAssertTrue(aged.pendingAsks.isEmpty)
        XCTAssertEqual(aged.staleAsks.map(\.interactionId), ["a1"])
    }

    /// The SQL cutoff must land on exactly the boundary the Swift filter uses.
    func testStaleCutoffMatchesTheSwiftAgeFilter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            GateDBReader.staleCutoffNs(now: now, maxAge: 6 * 3600),
            Int64((1_800_000_000 - 6 * 3600) * 1_000_000_000)
        )
        XCTAssertEqual(GateDBReader.staleCutoffNs(now: now, maxAge: .greatestFiniteMagnitude), .min)
        XCTAssertEqual(GateDBReader.staleCutoffNs(now: now, maxAge: .infinity), .min)
        XCTAssertEqual(GateDBReader.staleCutoffNs(now: now, maxAge: -.greatestFiniteMagnitude), .max)
        XCTAssertEqual(GateDBReader.staleCutoffNs(now: now, maxAge: -.infinity), .max)
    }

    // MARK: - Defect 6: bundle ids are case-insensitive identities

    /// Every mixed-case id the mapper can lowercase into `agents.json` must
    /// still match what NSWorkspace reports verbatim → **live** process-attach
    /// (running host app is evidence the attach is still present).
    func testEveryMixedCaseBundleIDFolds() throws {
        for (registryBundle, running) in [
            ("com.googlecode.iterm2", "com.googlecode.iTerm2"),
            ("com.jetbrains.intellij", "com.jetbrains.intelliJ"),
            ("com.microsoft.vscode", "com.microsoft.VSCode"),
            ("com.apple.terminal", "com.apple.Terminal"),
        ] {
            let root = dir.appendingPathComponent("case-\(UUID().uuidString)", isDirectory: true)
            let pets = try makePet(root, id: "agent1", bundle: registryBundle)
            let s = AgentActivityReader.load(
                petsRoot: pets,
                registryURL: root.appendingPathComponent("agents.json"),
                gateDB: nil,
                runningBundleIDs: [running]
            )
            XCTAssertEqual(
                s.agents.first?.presence, .live,
                "\(registryBundle) and \(running) are the same app (case-fold → live attach)"
            )
            // Wrong case that does NOT fold to the same id must not false-live.
            let miss = AgentActivityReader.load(
                petsRoot: pets,
                registryURL: root.appendingPathComponent("agents.json"),
                gateDB: nil,
                runningBundleIDs: ["com.example.NotThisApp"]
            )
            XCTAssertEqual(
                miss.agents.first?.presence, .offline,
                "unrelated running bundle must not keep attach live"
            )
        }
    }

    /// …and through `loadFull`, which is what the poll loop calls.
    func testLoadFullFoldsBundleCaseToo() throws {
        let root = dir.appendingPathComponent("full-\(UUID().uuidString)", isDirectory: true)
        let pets = try makePet(root, id: "agent1", bundle: "com.microsoft.vscode")
        let full = AgentActivityReader.loadFull(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            runningBundleIDs: ["com.microsoft.VSCode"]
        )
        XCTAssertEqual(full.summary.agents.first?.presence, .live)
    }

    /// The folding must not turn the liveness check into a no-op: an empty
    /// running set still means "nothing is running", and `nil` still skips.
    func testCaseFoldingDoesNotDisableTheLivenessCheck() throws {
        let root = dir.appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        let pets = try makePet(root, id: "agent1", bundle: "com.microsoft.vscode")
        let registry = root.appendingPathComponent("agents.json")

        XCTAssertEqual(
            AgentActivityReader.load(
                petsRoot: pets, registryURL: registry, gateDB: nil, runningBundleIDs: []
            ).agents.first?.presence, .offline
        )
        XCTAssertEqual(
            AgentActivityReader.load(
                petsRoot: pets, registryURL: registry, gateDB: nil,
                runningBundleIDs: ["com.apple.finder"]
            ).agents.first?.presence, .offline
        )
        XCTAssertEqual(
            AgentActivityReader.load(
                petsRoot: pets, registryURL: registry, gateDB: nil, runningBundleIDs: nil
            ).agents.first?.presence, .observed
        )
    }
}
