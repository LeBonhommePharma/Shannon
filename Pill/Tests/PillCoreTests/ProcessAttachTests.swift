import XCTest
@testable import PillCore

/// Process-attach reliability: ⌘D observations track real process liveness
/// without claiming gate-live / busy state.
final class ProcessAttachTests: XCTestCase {

    func testDeadPidWithoutBundleIsOffline() {
        XCTAssertEqual(
            ProcessAttach.presence(
                attachPid: 42, attachBundle: nil, runningBundleIDs: nil,
                pidAlive: { _ in false }
            ),
            .offline
        )
    }

    /// Electron/IDE restarts: old attach PID dies but host bundle stays up →
    /// stay **live** so ⌘D agents do not thrash the menu bar offline→live.
    func testDeadPidWithLiveHostBundleStaysLive() {
        let p = ProcessAttach.presence(
            attachPid: 42,
            attachBundle: "com.todesktop.cursor",
            runningBundleIDs: ["com.todesktop.cursor"],
            pidAlive: { _ in false }
        )
        XCTAssertEqual(p, .live)
        XCTAssertTrue(p.canBeBusy)
    }

    func testDeadPidWithHostBundleGoneIsOffline() {
        XCTAssertEqual(
            ProcessAttach.presence(
                attachPid: 99,
                attachBundle: "com.mitchellh.ghostty",
                runningBundleIDs: ["com.apple.Terminal"],
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

    func testLoadMarksDeadAttachOfflineWhenHostGone() throws {
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
            gateRows: nil
        )
        // Pid almost always dead + host not in running set → offline.
        guard let cursor = summary.agents.first(where: { $0.id == "cursor" }) else {
            return XCTFail("cursor pet missing")
        }
        if !ProcessAttach.isProcessAlive(pid: 424242) {
            XCTAssertEqual(cursor.presence, .offline)
        }
        XCTAssertFalse(cursor.status.isBusy)
    }

    /// Host still running with a stale attach PID stays live (restart stickiness).
    func testLoadKeepsDeadPidLiveWhenHostBundleRunning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("process-stick-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let agentDir = pets.appendingPathComponent("grok_build", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "status": "observed", "source": "process",
            "last_task": "build", "updated_at": Date().timeIntervalSince1970,
            "attach_pid": 424242, "attach_bundle": "com.mitchellh.ghostty",
            "resumable": true, "history_count": 1,
        ] as [String: Any]).write(to: agentDir.appendingPathComponent("state.json"))

        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            runningBundleIDs: ["com.mitchellh.ghostty"]
        )
        guard let agent = summary.agents.first(where: { $0.id == "grok_build" }) else {
            return XCTFail("grok_build missing")
        }
        XCTAssertEqual(agent.presence, .live)
        XCTAssertEqual(agent.attachBundle, "com.mitchellh.ghostty")
        XCTAssertEqual(agent.statusLine, "live")
    }

    /// Gate-only poll re-checks attach evidence so dead hosts drop without a full pets walk.
    func testSkipPetsScanRechecksProcessAttach() throws {
        let previous = [
            AgentActivitySnapshot(
                id: "cursor", displayName: "Cursor", status: .idle,
                lastTask: "edit", source: "ide",
                updatedAt: Date().addingTimeInterval(-30),
                resumable: false, historyCount: 1,
                presence: .live,
                attachPid: 424242,
                attachBundle: "com.todesktop.cursor"
            ),
        ]
        // Host gone → offline on gate-only tick.
        let offline = AgentActivityReader.load(
            petsRoot: FileManager.default.temporaryDirectory,
            registryURL: FileManager.default.temporaryDirectory.appendingPathComponent("none.json"),
            gateDB: nil,
            runningBundleIDs: [],
            skipPetsScan: true,
            previousAgents: previous
        )
        XCTAssertEqual(offline.agents.first?.presence, .offline)

        // Host still up → live even with dead pid.
        let live = AgentActivityReader.load(
            petsRoot: FileManager.default.temporaryDirectory,
            registryURL: FileManager.default.temporaryDirectory.appendingPathComponent("none.json"),
            gateDB: nil,
            runningBundleIDs: ["com.todesktop.cursor"],
            skipPetsScan: true,
            previousAgents: previous
        )
        XCTAssertEqual(live.agents.first?.presence, .live)
    }

    /// ⌘D regression: a gate-only tick after capture does **not** see a brand-new
    /// pet (previousAgents empty / pre-capture roster). Only a full pets scan
    /// admits the agent onto menu bar / pill. This is why refresh(forceFullScan:)
    /// must run after captureFromFrontApp.
    func testPostCaptureGateOnlyMissesNewPetUntilFullScan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("process-cmd-d-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let reg = root.appendingPathComponent("agents.json")
        let agentDir = pets.appendingPathComponent("cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "status": "observed", "source": "process",
            "last_task": "editing", "updated_at": Date().timeIntervalSince1970,
            "attach_pid": 55_001, "attach_bundle": "com.todesktop.230313mzl4w4u92",
            "resumable": true, "history_count": 1,
        ] as [String: Any]).write(to: agentDir.appendingPathComponent("state.json"))
        try JSONSerialization.data(withJSONObject: [
            ["id": "cursor", "display_name": "Cursor", "source": "ide",
             "last_task": "editing", "updated_at": Date().timeIntervalSince1970,
             "bundle": "com.todesktop.230313mzl4w4u92"],
        ] as [[String: Any]]).write(to: reg)

        let hostRunning: Set<String> = ["com.todesktop.230313mzl4w4u92"]

        // Gate-only with empty previous (as if capture just wrote disk but
        // monitor still has pre-capture summary) → agent missing.
        let gateOnly = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: reg,
            gateDB: nil,
            runningBundleIDs: hostRunning,
            skipPetsScan: true,
            previousAgents: []
        )
        XCTAssertTrue(
            gateOnly.agents.filter { $0.id == "cursor" }.isEmpty,
            "skipPetsScan must not invent the new capture from empty previous"
        )

        // Full pets scan → live + admitted on roster surfaces.
        let full = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: reg,
            gateDB: nil,
            runningBundleIDs: hostRunning,
            skipPetsScan: false
        )
        guard let cursor = full.agents.first(where: { $0.id == "cursor" }) else {
            return XCTFail("full pets scan must load ⌘D-written cursor pet")
        }
        XCTAssertEqual(cursor.presence, .live)
        XCTAssertEqual(cursor.attachBundle, "com.todesktop.230313mzl4w4u92")
        let listed = LiveRosterAdmission.filterListed(agents: full.agents)
        XCTAssertTrue(
            listed.contains(where: { $0.id == "cursor" }),
            "named IDE attach must surface on menu bar / pill after full scan"
        )
        XCTAssertTrue(
            LiveRosterAdmission.willSurfaceCapture(
                agentID: "cursor",
                displayName: "Cursor",
                attachPid: 55_001,
                attachBundle: "com.todesktop.230313mzl4w4u92"
            )
        )
    }
}
