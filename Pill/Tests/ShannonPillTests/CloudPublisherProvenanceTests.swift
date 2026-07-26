import XCTest
import Darwin
import PillCore
import ShannonCore
@testable import ShannonPill

/// A minimal stand-in for `python -m shannon.pill_bridge --demo`: a REAL Unix
/// socket that answers a `{"command":"status"}` line with one fixed status
/// frame. The point of the defect is that a synthetic detector is
/// indistinguishable from a real one at the socket layer — only `backend`
/// tells them apart — so the test has to come in through the socket too.
final class StubPillBridgeServer: @unchecked Sendable {
    let path: String
    private let frame: String
    private var listenFD: Int32 = -1
    private var running = false

    init(path: String, statusJSON: String) {
        self.path = path
        self.frame = statusJSON + "\n"
    }

    func start() throws {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw XCTSkip("cannot open a unix socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { throw XCTSkip("socket path too long") }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        cstr, maxLen - 1)
            }
        }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else {
            Darwin.close(listenFD)
            listenFD = -1
            throw XCTSkip("cannot bind \(path)")
        }
        running = true
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    private func acceptLoop() {
        while running {
            let conn = accept(listenFD, nil, nil)
            guard conn >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 256)
            _ = recv(conn, &buf, buf.count, 0)
            var reply = frame
            reply.withUTF8 { bytes in
                _ = Darwin.send(conn, bytes.baseAddress, bytes.count, 0)
            }
            Darwin.close(conn)
        }
    }

    func stop() {
        running = false
        if listenFD >= 0 { Darwin.close(listenFD) }
        listenFD = -1
        unlink(path)
    }
}

/// DEFECT 11 was fixed for the companion board, which is one of the surfaces
/// that reacts to an entropy number. `CloudPublisher.agentSnapshot()` is
/// another, and it is the one that leaves the machine: it mirrors
/// `bridge.status` to the iPhone, Apple Watch and iPad, where `isCollapsed`
/// paints the readout `shannonError` red (iOS `HomeView.swift:264`,
/// watchOS `ShannonFaceView.swift:165`, iPadOS `AgentCardView.swift:135`) and
/// `activity == .blocked` reads shared badge "needs you". Nothing on those devices can
/// tell a measurement from `--demo`'s `8.0 + 2.0*sin(n/12)` — `AgentState` has
/// no provenance field and renders `entropyLabel` without the pill's `~`.
@MainActor
final class CloudPublisherProvenanceTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        // Short name on purpose: `sun_path` is 104 bytes and the system temp
        // directory already spends ~50 of them.
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
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

    /// Stand up a bridge on a stub socket serving `statusJSON`, publish one
    /// pass, and return the `AgentState` that would reach the devices.
    private func mirroredAgent(statusJSON: String, backend expected: String) async throws -> AgentState {
        let socketPath = dir.appendingPathComponent("pill.sock").path
        let stub = StubPillBridgeServer(path: socketPath, statusJSON: statusJSON)
        try stub.start()
        defer { stub.stop() }

        let bridge = ShannonBridge(socketPath: socketPath, interval: 3600)
        bridge.poll()
        try await waitUntil("the bridge to read a \(expected) status") {
            bridge.status?.backend == expected
        }
        XCTAssertTrue(bridge.connected, "the stub socket is up, so the bridge is connected")

        let sink = InMemorySyncBackend()
        let publisher = CloudPublisher(
            nowPlaying: nil, battery: nil, bridge: bridge, activity: nil,
            backend: sink, interval: 3600, deviceName: "TestMac"
        )
        publisher.publish()
        try await waitUntil("the agent record to be published") {
            sink.recordCount(AgentState.recordType) == 1
        }
        let states = try await sink.fetch(AgentState.self)
        return try XCTUnwrap(states.first)
    }

    /// `--demo` reports `backend == "demo"` and asserts `is_collapsed` whenever
    /// `|8 - H| > 1.8` — about 29% of ticks. None of it may be mirrored as a
    /// measured collapse.
    func testDemoBridgeIsNotMirroredToDevicesAsACollapse() async throws {
        let mirrored = try await mirroredAgent(
            statusJSON: #"{"entropy":6.2,"delta_h":-1.9,"collapsed":true,"token_count":128,"backend":"demo","agent":"demo"}"#,
            backend: "demo"
        )
        XCTAssertFalse(
            mirrored.isCollapsed,
            "a --demo sine wave must not reach the phone and watch as a collapse"
        )
        XCTAssertNotEqual(
            mirrored.activity, .blocked,
            "a synthetic reading must not put the agent card into the alarmed state"
        )
        XCTAssertNil(
            mirrored.entropyDelta,
            "AgentState carries no provenance, so an unmeasured delta must not be published at all"
        )
        XCTAssertNil(
            mirrored.entropyBits,
            "entropyLabel renders \"H 6.2\" with no ~ marker — an unmeasured H is indistinguishable "
                + "from a measured one on the phone, so it must not be published"
        )
    }

    /// The same rule the pill applies to `unknown`: provenance cannot be
    /// established, so a deception monitor fails closed.
    func testUnknownBackendIsAlsoTreatedAsUnmeasured() async throws {
        let mirrored = try await mirroredAgent(
            statusJSON: #"{"entropy":2.0,"delta_h":-7.0,"collapsed":true,"token_count":9,"backend":"unknown"}"#,
            backend: "unknown"
        )
        XCTAssertFalse(mirrored.isCollapsed)
        XCTAssertNil(mirrored.entropyDelta)
    }

    /// …and the honest path is untouched: a real backend's collapse still
    /// reaches every device, numbers and all.
    func testMeasuredCollapseStillReachesTheDevices() async throws {
        let mirrored = try await mirroredAgent(
            statusJSON: #"{"entropy":2.1,"delta_h":-6.0,"collapsed":true,"token_count":512,"backend":"vllm","agent":"codex"}"#,
            backend: "vllm"
        )
        XCTAssertTrue(mirrored.isCollapsed, "a measured collapse must still alarm the devices")
        XCTAssertEqual(mirrored.activity, .blocked)
        XCTAssertEqual(mirrored.entropyDelta ?? 0, -6.0, accuracy: 0.001)
        XCTAssertEqual(mirrored.entropyBits ?? 0, 2.1, accuracy: 0.001)
        XCTAssertEqual(mirrored.lastAction, "Entropy collapse detected")
    }

    /// A measured, healthy reading publishes its numbers without alarming.
    func testMeasuredHealthyReadingPublishesNumbersWithoutAlarm() async throws {
        let mirrored = try await mirroredAgent(
            statusJSON: #"{"entropy":9.4,"delta_h":0.3,"collapsed":false,"token_count":77,"backend":"cpp","agent":"flexaid"}"#,
            backend: "cpp"
        )
        XCTAssertFalse(mirrored.isCollapsed)
        XCTAssertEqual(mirrored.activity, .running)
        XCTAssertEqual(mirrored.entropyBits ?? 0, 9.4, accuracy: 0.001)
        XCTAssertEqual(mirrored.taskTitle, "Entropy gate (cpp)")
    }

    // MARK: - ENH-022: resolve / resolveForAgent parity with the pill

    /// Demo bridge + live gate score: never publish demo collapse; publish the
    /// gate-measured H the local pill would show via `EntropyProvenance.resolve`.
    func testDemoBridgePlusGateMeasuredDoesNotPublishDemoCollapse() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = try XCTUnwrap(
            EntropyIntegrity.accept(
                bits: 2.86,
                deltaH: nil,
                collapsed: nil,
                source: .gate(agentId: "claude_code", presence: .live),
                measuredAt: now.addingTimeInterval(-4),
                now: now
            ),
            "fixture gate measurement must construct"
        )
        let demo = ShannonStatus(
            entropy: 6.2, deltaH: -1.9, collapsed: true,
            tokenCount: 128, backend: "demo", agent: "demo"
        )
        let mirrored = try XCTUnwrap(
            AgentStateRosterPublish.bridgeAggregate(
                bridgeConnected: true,
                bridgeStatus: demo,
                gateEntropy: [gate],
                gateDBAvailable: true,
                now: now
            )
        )
        XCTAssertFalse(
            mirrored.isCollapsed,
            "demo sine collapse must not reach devices when gate H is measured"
        )
        XCTAssertNotEqual(mirrored.activity, .blocked)
        XCTAssertEqual(
            mirrored.entropyBits ?? 0, 2.86, accuracy: 1e-9,
            "gate-measured H must publish when resolve falls through from demo"
        )
        XCTAssertNil(
            mirrored.entropyDelta,
            "gate rows have no ΔH — must not invent demo's -1.9"
        )
        XCTAssertTrue(
            mirrored.taskTitle.contains("gate:"),
            "task title must attribute gate, not claim demo is measured"
        )
    }

    /// Without a gate score, demo still fails closed (same as pre-ENH-022).
    func testDemoBridgeWithoutGateStillWithholdsEntropy() throws {
        let demo = ShannonStatus(
            entropy: 6.2, deltaH: -1.9, collapsed: true,
            tokenCount: 128, backend: "demo", agent: "demo"
        )
        let mirrored = try XCTUnwrap(
            AgentStateRosterPublish.bridgeAggregate(
                bridgeConnected: true,
                bridgeStatus: demo,
                gateEntropy: [],
                gateDBAvailable: true
            )
        )
        XCTAssertFalse(mirrored.isCollapsed)
        XCTAssertNil(mirrored.entropyBits)
        XCTAssertNil(mirrored.entropyDelta)
        XCTAssertEqual(mirrored.taskTitle, "Entropy gate (simulated)")
    }

    /// Multi-agent roster: per-agent gate entropy feeds `resolveForAgent`, so a
    /// demo fleet bridge cannot paint collapse onto a row that has real gate H.
    func testMultiAgentDemoBridgePlusGateUsesResolveForAgent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = try XCTUnwrap(
            EntropyIntegrity.accept(
                bits: 3.1,
                source: .gate(agentId: "claude_code", presence: .live),
                measuredAt: now.addingTimeInterval(-2),
                now: now
            )
        )
        let agent = AgentActivitySnapshot(
            id: "claude_code",
            displayName: "Claude Code",
            status: .active,
            lastTask: "review PR",
            source: "gate",
            updatedAt: now,
            resumable: true,
            historyCount: 4,
            presence: .live
        )
        let demo = ShannonStatus(
            entropy: 2.0, deltaH: -6.0, collapsed: true,
            tokenCount: 99, backend: "demo", agent: "demo"
        )
        let rows = AgentStateRosterPublish.snapshots(
            activityAgents: [agent],
            bridgeConnected: true,
            bridgeStatus: demo,
            gateEntropy: [gate],
            gateDBAvailable: true,
            entropyMemory: nil,
            now: now
        )
        XCTAssertEqual(rows.count, 1)
        let mirrored = try XCTUnwrap(rows.first)
        XCTAssertEqual(mirrored.id, "claude_code")
        XCTAssertFalse(
            mirrored.isCollapsed,
            "demo collapse must not attach to a different agent row"
        )
        XCTAssertEqual(
            mirrored.entropyBits ?? 0, 3.1, accuracy: 1e-9,
            "per-agent gate H must feed resolveForAgent and publish measured"
        )
        XCTAssertNotEqual(mirrored.activity, .blocked)
    }

    /// Measured real bridge still collapses the multi-agent row when named.
    func testMultiAgentMeasuredBridgeCollapseStillPublishes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let agent = AgentActivitySnapshot(
            id: "codex",
            displayName: "Codex",
            status: .active,
            lastTask: "build",
            source: "gate",
            updatedAt: now,
            resumable: true,
            historyCount: 2,
            presence: .live
        )
        let real = ShannonStatus(
            entropy: 2.1, deltaH: -6.0, collapsed: true,
            tokenCount: 512, backend: "vllm", agent: "codex"
        )
        let rows = AgentStateRosterPublish.snapshots(
            activityAgents: [agent],
            bridgeConnected: true,
            bridgeStatus: real,
            gateEntropy: [],
            gateDBAvailable: true,
            now: now
        )
        let mirrored = try XCTUnwrap(rows.first)
        XCTAssertTrue(mirrored.isCollapsed)
        XCTAssertEqual(mirrored.activity, .blocked)
        XCTAssertEqual(mirrored.entropyBits ?? 0, 2.1, accuracy: 0.001)
        XCTAssertEqual(mirrored.entropyDelta ?? 0, -6.0, accuracy: 0.001)
    }
}
