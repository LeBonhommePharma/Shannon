import XCTest
import SQLite3
import PillCore
import ShannonCore
@testable import ShannonPill

/// ENH-023: a remote (phone/watch/iPad) answer must not clear the local ask
/// when the gate socket write fails — same terminal states as on-desk resolve.
@MainActor
final class CloudPublisherRemoteAnswerTests: XCTestCase {

    private var home: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["SHANNON_LOG_DIR"]
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudpub-remote-\(UUID().uuidString)", isDirectory: true)
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

    /// Phone/watch answers when the gate socket is missing must keep the local
    /// ask and surface lastResolveError — never the old always-clearAsk path.
    func testRemoteAnswerKeepsAskAndSurfacesErrorWhenSocketUnavailable() async throws {
        let askedAt = Date().addingTimeInterval(-30)
        try exec("""
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('i-remote-fail', 'codex', 'deploy to prod?', 'pending',
                \(Int64(askedAt.timeIntervalSince1970 * 1_000_000_000)));
        """)

        let monitor = AgentActivityMonitor(interval: 3600)
        // Force a missing socket so resolveAsync throws .socketUnavailable
        // even if a real hub is listening on the default path during tests.
        monitor.gateSocketPath = "/tmp/shannon-nonexistent-\(UUID().uuidString).sock"
        monitor.refresh()
        try await waitUntil("the gate ask to reach the monitor") {
            monitor.pendingAsks.count == 1
        }
        XCTAssertNil(monitor.lastResolveError)

        let backend = InMemorySyncBackend()
        // Simulate an off-desk answer already waiting in the sync queue.
        try await backend.save(ConfirmationResponse(
            id: "i-remote-fail",
            answer: .confirmed,
            source: .tap,
            origin: "iPhone",
            answeredAt: Date()
        ))

        let publisher = CloudPublisher(
            nowPlaying: nil, battery: nil, bridge: nil,
            activity: monitor, backend: backend, interval: 3600, deviceName: "TestMac"
        )
        // One publish: mirrors the open ask, then consumes the remote answer
        // and applies it through applyRemoteAnswer → activity.resolve.
        publisher.publish()

        try await waitUntil("resolve failure to surface on the monitor") {
            monitor.lastResolveError != nil
        }

        XCTAssertEqual(
            monitor.pendingAsks.map(\.interactionId),
            ["i-remote-fail"],
            "failed gate resolve must not clearAsk — local path keeps the card"
        )
        let err = try XCTUnwrap(monitor.lastResolveError)
        // UX-042: post-tap resolve error equals pre-disable macGateOffline token.
        XCTAssertEqual(
            err,
            GateAskActionCopy.macGateOffline,
            "socketUnavailable must surface GateAskActionCopy.macGateOffline"
        )
    }
}
