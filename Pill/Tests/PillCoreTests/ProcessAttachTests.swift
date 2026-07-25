import XCTest
@testable import PillCore

/// Process-attach reliability: ⌘D observations track real process liveness
/// without claiming gate-live / busy state.
final class ProcessAttachTests: XCTestCase {

    func testDeadPidIsOffline() {
        XCTAssertEqual(
            ProcessAttach.presence(
                attachPid: 42, attachBundle: nil, runningBundleIDs: nil,
                pidAlive: { _ in false }
            ),
            .offline
        )
    }

    func testLivePidIsLiveAndCanBeBusyEligible() {
        let p = ProcessAttach.presence(
            attachPid: 1234,
            attachBundle: "com.example.app",
            runningBundleIDs: ["com.example.app"],
            pidAlive: { _ in true }
        )
        XCTAssertEqual(p, .live)
        XCTAssertTrue(p.canBeBusy, "live process-attach is busy-eligible (status still idle until gate)")
    }

    func testBundleGoneIsOfflineWhenNoPid() {
        let p = ProcessAttach.presence(
            attachPid: nil,
            attachBundle: "com.todesktop.cursor",
            runningBundleIDs: ["com.apple.Terminal"]
        )
        XCTAssertEqual(p, .offline)
    }

    func testBundlePresentIsLive() {
        let p = ProcessAttach.presence(
            attachPid: nil,
            attachBundle: "com.todesktop.230313mzl4w4u92",
            runningBundleIDs: Set(["com.todesktop.230313mzl4w4u92".lowercased()])
        )
        XCTAssertEqual(p, .live)
    }

    func testNoEvidenceStaysObserved() {
        let p = ProcessAttach.presence(
            attachPid: nil,
            attachBundle: nil,
            runningBundleIDs: ["com.apple.finder"]
        )
        XCTAssertEqual(p, .observed)
    }

    func testPidWinsOverStaleBundle() {
        // Process still alive even if host bundle list missed it.
        let p = ProcessAttach.presence(
            attachPid: 7,
            attachBundle: "com.gone.app",
            runningBundleIDs: [],
            pidAlive: { $0 == 7 }
        )
        XCTAssertEqual(p, .live)
    }

    func testLiveQuietStatusLineSaysLiveNotIdle() {
        let snap = AgentActivitySnapshot(
            id: "cursor", displayName: "Cursor", status: .idle,
            lastTask: "editing", source: "ide",
            updatedAt: Date(), resumable: false, historyCount: 0,
            presence: .live
        )
        XCTAssertEqual(snap.statusLine, "live")
        XCTAssertEqual(AgentActivitySummary(agents: [snap]).busyCount, 0)
    }

    func testLoadMarksDeadAttachOffline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("process-attach-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let agentDir = pets.appendingPathComponent("cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let state: [String: Any] = [
            "status": "observed",
            "source": "observed",
            "last_task": "editing",
            "updated_at": Date().timeIntervalSince1970,
            "attach_pid": 424242,
            "attach_bundle": "com.todesktop.cursor",
            "resumable": true,
            "history_count": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: state)
        try data.write(to: agentDir.appendingPathComponent("state.json"))

        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            now: Date(),
            runningBundleIDs: [],
            // force pid dead via... we can't inject pidAlive into load.
            // Use a pid that is almost certainly dead: INT_MAX-ish.
            gateRows: nil
        )
        // With real kill(0) on 424242 — almost always dead → offline.
        // If somehow alive (extremely unlikely), presence would be observed.
        guard let cursor = summary.agents.first(where: { $0.id == "cursor" }) else {
            return XCTFail("cursor pet missing")
        }
        if !ProcessAttach.isProcessAlive(pid: 424242) {
            XCTAssertEqual(cursor.presence, .offline)
        }
        XCTAssertFalse(cursor.status.isBusy)
    }
}
