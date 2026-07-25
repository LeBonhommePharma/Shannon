import XCTest
@testable import PillCore
#if canImport(Darwin)
import Darwin
#endif

final class HubEnsureTests: XCTestCase {

    func testPlanAlreadyRunning() {
        XCTAssertEqual(
            HubEnsure.plan(listening: true, scriptExists: true),
            .alreadyRunning
        )
        XCTAssertEqual(
            HubEnsure.plan(socketUp: true, scriptExists: false),
            .alreadyRunning
        )
        XCTAssertTrue(HubEnsure.plan(listening: true, scriptExists: true).isUp)
    }

    func testPlanMissingScript() {
        XCTAssertEqual(
            HubEnsure.plan(listening: false, scriptExists: false),
            .missingScript
        )
        XCTAssertFalse(HubEnsure.plan(listening: false, scriptExists: false).isUp)
    }

    func testPlanWouldStart() {
        XCTAssertEqual(
            HubEnsure.plan(listening: false, scriptExists: true),
            .started
        )
        XCTAssertTrue(HubEnsure.shouldStart(listening: false, scriptExists: true))
        XCTAssertFalse(HubEnsure.shouldStart(listening: true, scriptExists: true))
        XCTAssertFalse(HubEnsure.shouldStart(listening: false, scriptExists: false))
    }

    func testIsListeningOnlyWhenProbeListening() {
        XCTAssertTrue(HubEnsure.isListening(.listening))
        XCTAssertFalse(HubEnsure.isListening(.absent))
        XCTAssertFalse(HubEnsure.isListening(.stale))
    }

    func testResolveGateScriptFindsEnvRoot() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-hub-ensure-\(UUID().uuidString)", isDirectory: true)
        let hub = tmp.appendingPathComponent("hub", isDirectory: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        let script = hub.appendingPathComponent("shannon_gate.py")
        try "# fake gate\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let found = HubEnsure.resolveGateScript(
            environment: ["SHANNON_ROOT": tmp.path],
            fileManager: .default
        )
        XCTAssertEqual(found?.path, script.path)
    }

    func testEnsureRunningAlreadyListening() {
        var spawnCalled = false
        let result = HubEnsure.ensureRunning(
            socketPath: "/tmp/never-used-\(UUID().uuidString).sock",
            environment: ["SHANNON_ROOT": "/nonexistent"],
            spawn: { _, _ in spawnCalled = true },
            waitForSocket: 0.05,
            probe: { _ in .listening }
        )
        XCTAssertEqual(result, .alreadyRunning)
        XCTAssertFalse(spawnCalled, "must not re-spawn when listening")
    }

    func testEnsureRunningMissingScriptFailClosed() {
        let result = HubEnsure.ensureRunning(
            socketPath: "/tmp/shannon-ensure-missing-\(UUID().uuidString).sock",
            environment: ["SHANNON_ROOT": "/nonexistent/path/for/shannon"],
            spawn: { _, _ in XCTFail("must not spawn") },
            waitForSocket: 0.05,
            probe: { _ in .absent }
        )
        XCTAssertEqual(result, .missingScript)
        XCTAssertFalse(result.isUp)
    }

    /// Stale leftover sock must NOT count as running — ensure must spawn when script exists.
    func testEnsureRunningStaleSocketSpawns() throws {
        let sock = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-stale-\(UUID().uuidString).sock")
        // Regular file mimics a non-listening leftover path (connect fails).
        FileManager.default.createFile(atPath: sock.path, contents: Data("dead".utf8))
        defer { try? FileManager.default.removeItem(at: sock) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-hub-stale-\(UUID().uuidString)", isDirectory: true)
        let hub = tmp.appendingPathComponent("hub", isDirectory: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        let script = hub.appendingPathComponent("shannon_gate.py")
        try "print('gate')\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var spawnCount = 0
        var listeningAfterSpawn = false
        let result = HubEnsure.ensureRunning(
            socketPath: sock.path,
            environment: ["SHANNON_ROOT": tmp.path],
            spawn: { _, _ in
                spawnCount += 1
                listeningAfterSpawn = true
            },
            waitForSocket: 0.4,
            probe: { path in
                // Before spawn: path exists as dead file → stale.
                // After spawn: pretend gate is listening.
                if listeningAfterSpawn { return .listening }
                if FileManager.default.fileExists(atPath: path) { return .stale }
                return .absent
            }
        )
        XCTAssertEqual(result, .started)
        XCTAssertEqual(spawnCount, 1, "stale sock must trigger spawn")
        XCTAssertTrue(result.isUp)
    }

    /// Real FS: regular-file “sock” is not listening; probe unlinks and returns absent.
    func testProbeSocketUnlinksStaleRegularFile() {
        let sock = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-probe-stale-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: sock.path, contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: sock.path))

        let probe = HubEnsure.probeSocket(path: sock.path, unlinkStale: true)
        // After unlink of non-listening path → absent (preferred) or stale if unlink failed.
        XCTAssertNotEqual(probe, .listening)
        XCTAssertFalse(HubEnsure.isListening(probe))
        XCTAssertFalse(
            HubEnsure.isSocketUp(path: sock.path, unlinkStale: true),
            "fileExists alone must not report up"
        )
        // Path should be gone after unlinkStale.
        XCTAssertFalse(FileManager.default.fileExists(atPath: sock.path))
    }

    func testProbeSocketAbsent() {
        let path = "/tmp/shannon-no-such-\(UUID().uuidString).sock"
        XCTAssertEqual(HubEnsure.probeSocket(path: path, unlinkStale: true), .absent)
        XCTAssertFalse(HubEnsure.isSocketUp(path: path))
    }

    #if canImport(Darwin)
    /// Real listening AF_UNIX socket is detected via connect (not mere fileExists).
    func testProbeSocketListeningRealServer() throws {
        // sun_path is short on Darwin (~104 bytes) — use /tmp + short name.
        let path = "/tmp/sh-ls-\(String(UUID().uuidString.prefix(8))).sock"
        try? FileManager.default.removeItem(atPath: path)

        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer {
            close(server)
            try? FileManager.default.removeItem(atPath: path)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        XCTAssertLessThan(pathBytes.count, capacity)
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(server, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindOK, 0, "bind failed errno=\(errno)")
        XCTAssertEqual(Darwin.listen(server, 8), 0)

        // Accept in background so connect() can complete on all Darwin variants.
        let acceptQ = DispatchQueue(label: "hub.ensure.accept")
        acceptQ.async {
            while true {
                let c = Darwin.accept(server, nil, nil)
                if c >= 0 { close(c) } else { break }
            }
        }

        // Brief settle for listen/accept thread.
        Thread.sleep(forTimeInterval: 0.05)
        let probe = HubEnsure.probeSocket(path: path, unlinkStale: false)
        XCTAssertEqual(probe, .listening, "live listener must be .listening not fileExists-only")
        XCTAssertTrue(HubEnsure.isListening(probe))
        // Same path through isSocketUp (connect-based).
        XCTAssertTrue(
            HubEnsure.isSocketUp(path: path, unlinkStale: false),
            "isSocketUp must require successful connect"
        )
    }
    #endif

    func testEnsureRunningSpawnThenListening() throws {
        let sockPath = "/tmp/shannon-spawn-\(UUID().uuidString).sock"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-hub-\(UUID().uuidString)", isDirectory: true)
        let hub = tmp.appendingPathComponent("hub", isDirectory: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        let script = hub.appendingPathComponent("shannon_gate.py")
        try "print('gate')\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var phase = 0
        let result = HubEnsure.ensureRunning(
            socketPath: sockPath,
            environment: ["SHANNON_ROOT": tmp.path],
            spawn: { _, _ in phase = 1 },
            waitForSocket: 0.5,
            probe: { _ in phase == 0 ? .absent : .listening }
        )
        XCTAssertEqual(result, .started)
        XCTAssertTrue(result.isUp)
    }

    func testResultLabels() {
        XCTAssertTrue(HubEnsure.Result.alreadyRunning.shortLabel.contains("running"))
        XCTAssertTrue(HubEnsure.Result.missingScript.shortLabel.contains("missing"))
        XCTAssertTrue(HubEnsure.Result.spawnFailed("x").shortLabel.contains("failed"))
    }

    /// Machine-facing: path existence alone is never enough for “up”.
    /// When the default sock is a dead leftover (file yes, connect no), probe
    /// must not report `.listening` — so ensure will spawn/unlink, not alreadyRunning.
    func testDefaultSocketReadinessIsConnectBased() {
        let path = HubEnsure.defaultSocketPath
        let exists = FileManager.default.fileExists(atPath: path)
        let probeNoUnlink = HubEnsure.probeSocket(path: path, unlinkStale: false)
        if exists {
            // Either truly listening, or stale — never invent listening from fileExists.
            if case .listening = probeNoUnlink {
                XCTAssertTrue(HubEnsure.isSocketUp(path: path, unlinkStale: false))
            } else {
                XCTAssertFalse(
                    HubEnsure.isListening(probeNoUnlink),
                    "stale leftover sock must not count as hub up"
                )
                XCTAssertTrue(
                    HubEnsure.shouldStart(listening: false, scriptExists: true),
                    "stale/absent + script → shouldStart"
                )
            }
        } else {
            XCTAssertEqual(probeNoUnlink, .absent)
        }
    }
}
