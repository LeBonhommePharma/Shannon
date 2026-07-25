import XCTest
import SQLite3
import PillCore
import ShannonCore
@testable import ShannonPill

/// End-to-end cover for the CALL SITE of the ask-lifetime fix.
///
/// `ConfirmationCreatedAtTests` pins the resolver in isolation, but the defect
/// was that `CloudPublisher.publish()` never asked the resolver — it seeded
/// `createdAt` from the pill's own `Date()`. This drives the real publisher,
/// with a real gate DB and an in-memory CloudKit backend, and asserts on the
/// record that would actually reach the phone and the watch.
@MainActor
final class CloudPublisherAskLifetimeTests: XCTestCase {

    private var home: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["SHANNON_LOG_DIR"]
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudpub-\(UUID().uuidString)", isDirectory: true)
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

    /// Wait for an async condition without blocking the main actor.
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

    /// The user-visible defect: an ask the gate opened 40 minutes ago is
    /// mirrored to the phone as brand new, so it never ages out.
    func testOldGateAskIsMirroredWithTheGatesOwnTimestamp() async throws {
        let askedSecondsAgo: TimeInterval = 40 * 60
        let askedAt = Date().addingTimeInterval(-askedSecondsAgo)
        try exec("""
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('i-old', 'codex', 'rm -rf build?', 'pending',
                \(Int64(askedAt.timeIntervalSince1970 * 1_000_000_000)));
        """)

        let monitor = AgentActivityMonitor(interval: 3600)
        monitor.refresh()
        try await waitUntil("the gate ask to reach the monitor") { monitor.pendingAsks.count == 1 }

        let backend = InMemorySyncBackend()
        let publisher = CloudPublisher(
            nowPlaying: nil, battery: nil, bridge: nil,
            activity: monitor, backend: backend, interval: 3600, deviceName: "TestMac"
        )
        publisher.publish()
        try await waitUntil("the confirmation to be published") {
            backend.recordCount(PendingConfirmation.recordType) == 1
        }

        let published = try await backend.fetch(PendingConfirmation.self)
        let mirrored = try XCTUnwrap(published.first)
        XCTAssertEqual(mirrored.id, "i-old")
        XCTAssertEqual(
            mirrored.createdAt.timeIntervalSince1970,
            askedAt.timeIntervalSince1970,
            accuracy: 1.0,
            "createdAt must come from the gate's created_at_ns, not from this pill launch"
        )
        XCTAssertTrue(
            mirrored.isExpired(),
            "an ask opened \(Int(askedSecondsAgo / 60)) min ago is past the "
                + "\(Int(PendingConfirmation.defaultLifetime / 60)) min lifetime and must reach "
                + "the phone already expired"
        )
    }

    /// The behaviour the local first-seen cache existed to protect: a fresh ask
    /// still publishes as live, and republishes identically.
    func testFreshAskPublishesLiveAndStaysStableAcrossPasses() async throws {
        let askedAt = Date().addingTimeInterval(-30)
        try exec("""
        INSERT INTO agent_interactions (interaction_id, agent_id, prompt, status, created_at_ns)
        VALUES ('i-new', 'codex', 'push to main?', 'pending',
                \(Int64(askedAt.timeIntervalSince1970 * 1_000_000_000)));
        """)

        let monitor = AgentActivityMonitor(interval: 3600)
        monitor.refresh()
        try await waitUntil("the gate ask to reach the monitor") { monitor.pendingAsks.count == 1 }

        let backend = InMemorySyncBackend()
        let publisher = CloudPublisher(
            nowPlaying: nil, battery: nil, bridge: nil,
            activity: monitor, backend: backend, interval: 3600, deviceName: "TestMac"
        )
        publisher.publish()
        try await waitUntil("first publish") {
            backend.recordCount(PendingConfirmation.recordType) == 1
        }
        let firstBatch = try await backend.fetch(PendingConfirmation.self)
        let first = try XCTUnwrap(firstBatch.first)
        XCTAssertFalse(first.isExpired(), "a 30 s old ask must still be answerable")

        publisher.publish()
        try await Task.sleep(nanoseconds: 200_000_000)
        let secondBatch = try await backend.fetch(PendingConfirmation.self)
        let second = try XCTUnwrap(secondBatch.first)
        XCTAssertEqual(
            first.createdAt.timeIntervalSince1970,
            second.createdAt.timeIntervalSince1970,
            accuracy: 0.001,
            "createdAt must not move between passes or the publisher republishes forever"
        )
    }
}
