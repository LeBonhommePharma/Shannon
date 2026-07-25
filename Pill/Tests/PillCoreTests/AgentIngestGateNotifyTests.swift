import XCTest
@testable import PillCore

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Compile-time regression

/// **COMPILE-TIME REGRESSION — do not delete, do not make this `@MainActor`.**
///
/// `notifyGateBestEffort` does blocking BSD socket work. It used to be a plain
/// `static func` on the `@MainActor`-isolated `AgentIngestService`, so every
/// caller inherited main-actor isolation and a stalled gate froze the UI. The
/// sibling `gateAccepted` was already `nonisolated`; the distinction was
/// understood and simply not applied here.
///
/// This free function is *synchronous* and *non-isolated*. If anyone removes
/// `nonisolated` from `notifyGateBestEffort`, this call becomes
/// "call to main actor-isolated static method in a synchronous nonisolated
/// context" and the test target stops building. That is the intended failure:
/// a build break is a stronger regression test than an assertion, because it
/// cannot be skipped, quarantined or made flaky.
private func notifyGateFromSynchronousNonisolatedContext() -> GateNotifyOutcome {
    AgentIngestService.notifyGateBestEffort(
        agentID: "local_test",
        task: "compile-time isolation probe",
        env: ["SHANNON_GATE_NOTIFY": "off"],   // contacts nothing
        transport: .refuseAll
    )
}

// MARK: - Test support

/// Minimal `Sendable` mutable cell, so a detached notifier can report what it
/// saw without a data race and without a clock.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var get: T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
}

/// A real listener on 127.0.0.1 that either answers a canned HTTP response or
/// accepts and says nothing. Hermetic: no daemon, no fixed port, no network.
private final class StubHTTPGate: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let stopped = Box(false)

    /// `reply == nil` models a wedged gate: the connection is accepted, and
    /// then nothing ever comes back.
    init?(reply: String?) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                          // kernel picks a free port
        addr.sin_addr.s_addr = "127.0.0.1".withCString { inet_addr($0) }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        var back = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &back) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard named == 0 else { close(fd); return nil }
        self.listenFD = fd
        self.port = UInt16(bigEndian: back.sin_port)

        let stopped = self.stopped
        DispatchQueue.global().async {
            var held: [Int32] = []
            while !stopped.get {
                let conn = accept(fd, nil, nil)
                if conn < 0 { break }
                if let reply {
                    var scratch = [UInt8](repeating: 0, count: 4096)
                    _ = recv(conn, &scratch, scratch.count, 0)
                    let bytes = Array(reply.utf8)
                    _ = bytes.withUnsafeBufferPointer { send(conn, $0.baseAddress, $0.count, 0) }
                    close(conn)
                } else {
                    held.append(conn)   // accepted, deliberately never answered
                }
            }
            for c in held { close(c) }
        }
    }

    func stop() {
        stopped.set(true)
        close(listenFD)   // unblocks the accept loop
    }
}

final class AgentIngestGateNotifyTests: XCTestCase {

    private func withIsolatedShannonHome(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-gate-notify-\(UUID().uuidString)", isDirectory: true)
        let oldHome = ProcessInfo.processInfo.environment["SHANNON_LOG_DIR"]
        setenv("SHANNON_LOG_DIR", root.path, 1)
        defer {
            if let oldHome { setenv("SHANNON_LOG_DIR", oldHome, 1) }
            else { unsetenv("SHANNON_LOG_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    private static let okResponse = """
    HTTP/1.1 200 OK\r
    Content-Type: application/json\r
    Content-Length: 24\r
    \r
    {"decision": "allowed"}\n
    """

    // MARK: - W1: the notify path must not be main-actor isolated

    /// Drives the compile-time probe above. The assertion is secondary; the
    /// value of this test is that the probe is reachable code, so the build
    /// break cannot be dodged by dead-stripping.
    func testNotifyIsCallableFromASynchronousNonisolatedContext() {
        let outcome = notifyGateFromSynchronousNonisolatedContext()
        XCTAssertEqual(outcome.status, .refused)
        XCTAssertTrue(outcome.detail.contains("SHANNON_GATE_NOTIFY"), outcome.detail)
    }

    /// And it really executes off the main thread when driven from a detached
    /// task — the isolation annotation is not just cosmetic.
    func testNotifyExecutesOffTheMainThread() async {
        let sawMainThread = Box<Bool?>(nil)
        let transport = GateNotifyTransport { _, _, _ in
            sawMainThread.set(Thread.isMainThread)
            return AgentIngestGateNotifyTests.okResponse
        }
        let outcome = await Task.detached {
            AgentIngestService.notifyGateBestEffort(
                agentID: "local_test", task: "off-main probe",
                env: [:], transport: transport
            )
        }.value
        XCTAssertTrue(outcome.accepted, outcome.detail)
        XCTAssertEqual(sawMainThread.get, false, "the blocking notify ran on the main thread")
    }

    // MARK: - W3: an unreachable gate must not freeze the main actor
    //
    // THE headline regression. Hermetic: "unreachable" is a semaphore the test
    // owns, not a blackholed route, so this passes on a clean machine with no
    // gate running and no network.

    @MainActor
    func testCaptureDoesNotBlockTheMainActorOnAnUnreachableGate() throws {
        try withIsolatedShannonHome { _ in
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let ranOnMainThread = Box<Bool?>(nil)

            let service = AgentIngestService { _, _, _ in
                ranOnMainThread.set(Thread.isMainThread)
                entered.signal()
                // A blackholed gate, deterministically. The timeout exists only
                // so that the BROKEN (main-actor-blocking) arrangement FAILS the
                // assertions below instead of hanging the suite forever.
                _ = release.wait(timeout: .now() + 3.0)
                return .refused("blackholed")
            }

            let started = DispatchTime.now()
            let result = service.capture(
                bundleID: "com.anthropic.claude-code", appName: "Claude Code",
                clipboardText: ""
            )
            let elapsedMS = Double(
                DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
            ) / 1_000_000

            // 1. The capture itself is complete and honest…
            XCTAssertTrue(result.captured)
            XCTAssertTrue(result.createdPet)
            // 2. …but it makes no claim about a gate that has not answered.
            XCTAssertEqual(result.gateStatus, .pending)
            XCTAssertFalse(result.gateNotified,
                           "a pending POST must never read as a notified gate")
            // 3. And it returned instead of waiting out the stall.
            XCTAssertLessThan(elapsedMS, 1_000,
                              "capture() blocked \(elapsedMS) ms on the gate")

            // The notifier has started and is *still inside* its blocking wait —
            // nothing has signalled `release` yet.
            XCTAssertEqual(entered.wait(timeout: .now() + 5.0), .success,
                           "the notifier never started")
            XCTAssertEqual(ranOnMainThread.get, false,
                           "the blocking notify ran on the main thread")
            // Executing this line at all, while the notifier is wedged, IS the
            // proof: the main thread is free.
            XCTAssertTrue(Thread.isMainThread)

            release.signal()
        }
    }

    /// The verdict does arrive, and it rewrites the published row — this is the
    /// "say exactly how the UI reflects it" half. `lastResult` is `@Published`,
    /// so a bound view re-renders with `⚠︎gate` and the reason.
    @MainActor
    func testAsyncGateVerdictRewritesThePublishedResult() async throws {
        try withIsolatedShannonHome { _ in
            let service = AgentIngestService { _, _, _ in .refused("no answer from 127.0.0.1:8765") }
            let result = service.capture(
                bundleID: "com.anthropic.claude-code", appName: "Claude Code",
                clipboardText: ""
            )
            XCTAssertEqual(result.gateStatus, .pending)
            XCTAssertEqual(result.pillLabel, "+Claude Code", "pending is not a failure")
            self.pendingTask = service.gateNotifyTask
            self.pendingService = service
        }
        await pendingTask?.value
        let service = try XCTUnwrap(pendingService)
        XCTAssertEqual(service.lastResult?.gateStatus, .refused)
        XCTAssertFalse(service.lastResult?.gateNotified ?? true)
        XCTAssertEqual(service.lastResult?.pillLabel, "+Claude Code ⚠︎gate")
        XCTAssertTrue(service.lastResult?.message.contains("no answer") ?? false,
                      service.lastResult?.message ?? "")
        XCTAssertEqual(service.recent.first?.gateStatus, .refused,
                       "the history row must not keep claiming pending")
    }

    @MainActor
    func testAcceptedGateVerdictLeavesNoWarningMarker() async throws {
        try withIsolatedShannonHome { _ in
            let service = AgentIngestService { _, _, _ in .accepted }
            _ = service.capture(
                bundleID: "com.anthropic.claude-code", appName: "Claude Code",
                clipboardText: ""
            )
            self.pendingTask = service.gateNotifyTask
            self.pendingService = service
        }
        await pendingTask?.value
        let service = try XCTUnwrap(pendingService)
        XCTAssertEqual(service.lastResult?.gateStatus, .accepted)
        XCTAssertTrue(service.lastResult?.gateNotified ?? false)
        XCTAssertEqual(service.lastResult?.pillLabel, "+Claude Code")
    }

    /// A refused capture must not even dispatch a notify — no pet, no gate.
    @MainActor
    func testRefusedCaptureNeverContactsTheGate() throws {
        try withIsolatedShannonHome { _ in
            let calls = Box(0)
            let service = AgentIngestService { _, _, _ in
                calls.mutate { $0 += 1 }
                return .accepted
            }
            let result = service.capture(
                bundleID: "com.apple.dock", appName: "Dock", clipboardText: ""
            )
            XCTAssertFalse(result.captured)
            XCTAssertEqual(result.gateStatus, .notAttempted)
            XCTAssertFalse(result.gateNotified)
            XCTAssertNil(service.gateNotifyTask)
            XCTAssertEqual(calls.get, 0)
        }
    }

    /// Rapid ⌘D: the first notify is cancelled, and a late verdict for a
    /// superseded capture must not rewrite the newer row.
    @MainActor
    func testASupersededVerdictDoesNotRewriteANewerCapture() async throws {
        try withIsolatedShannonHome { _ in
            let service = AgentIngestService { agentID, _, _ in
                agentID == "claude_code" ? .refused("stale") : .accepted
            }
            _ = service.capture(
                bundleID: "com.anthropic.claude-code", appName: "Claude Code",
                clipboardText: ""
            )
            let first = service.gateNotifyTask
            _ = service.capture(
                bundleID: "com.openai.chat", appName: "ChatGPT", clipboardText: ""
            )
            self.pendingTask = service.gateNotifyTask
            self.pendingService = service
            self.otherTask = first
        }
        await otherTask?.value
        await pendingTask?.value
        let service = try XCTUnwrap(pendingService)
        XCTAssertEqual(service.lastResult?.gateStatus, .accepted,
                       "a superseded verdict overwrote the newest capture")
    }

    /// Observe-only mode is worthless if its finding never reaches a human.
    /// An accepted-but-would-have-been-refused post still explains itself in
    /// the capture's message, without the `⚠︎gate` marker — it did work.
    @MainActor
    func testObserveOnlyFindingReachesThePublishedMessage() async throws {
        try withIsolatedShannonHome { _ in
            let service = AgentIngestService { _, _, _ in
                GateNotifyOutcome(
                    status: .accepted,
                    detail: "observe-only: 10.0.0.5 is not loopback; "
                        + "set SHANNON_GATE_ALLOW_REMOTE=1 to allow it"
                )
            }
            _ = service.capture(
                bundleID: "com.anthropic.claude-code", appName: "Claude Code",
                clipboardText: ""
            )
            self.pendingTask = service.gateNotifyTask
            self.pendingService = service
        }
        await pendingTask?.value
        let service = try XCTUnwrap(pendingService)
        XCTAssertEqual(service.lastResult?.gateStatus, .accepted)
        XCTAssertEqual(service.lastResult?.pillLabel, "+Claude Code",
                       "observe-only worked; it must not wear a failure marker")
        XCTAssertTrue(service.lastResult?.message.contains("observe-only") ?? false,
                      service.lastResult?.message ?? "")
    }

    /// Going off-actor moved the environment read *later*. If the notifier read
    /// the live process environment on the background thread it could resolve a
    /// different gate than the ⌘D the operator actually pressed — including the
    /// real one, from a test that had already restored its own overrides. The
    /// snapshot is taken synchronously at dispatch; this pins that.
    @MainActor
    func testTheEndpointIsSnapshottedAtCaptureTimeNotAtNotifyTime() async throws {
        let seenPort = Box<String?>(nil)
        let proceed = DispatchSemaphore(value: 0)
        let oldPort = ProcessInfo.processInfo.environment["SHANNON_HTTP_PORT"]
        defer {
            if let oldPort { setenv("SHANNON_HTTP_PORT", oldPort, 1) }
            else { unsetenv("SHANNON_HTTP_PORT") }
        }
        try withIsolatedShannonHome { _ in
            setenv("SHANNON_HTTP_PORT", "65533", 1)     // nothing listens there
            let service = AgentIngestService { _, _, env in
                proceed.wait()                         // hold until env changed
                seenPort.set(env["SHANNON_HTTP_PORT"])
                return .refused("held")
            }
            _ = service.capture(
                bundleID: "com.anthropic.claude-code", appName: "Claude Code",
                clipboardText: ""
            )
            setenv("SHANNON_HTTP_PORT", "8765", 1)     // a live gate's port
            proceed.signal()
            self.pendingTask = service.gateNotifyTask
        }
        await pendingTask?.value
        XCTAssertEqual(seenPort.get, "65533",
                       "the notify resolved the environment as of notify time, not capture time")
    }

    // Held across the `withIsolatedShannonHome` boundary because the helper is
    // synchronous and cannot carry an `await`.
    @MainActor private var pendingTask: Task<Void, Never>?
    @MainActor private var otherTask: Task<Void, Never>?
    @MainActor private var pendingService: AgentIngestService?

    // MARK: - W2: the fd is non-blocking and the deadline is real

    /// `connect()` on a blocking fd ignores every timeout we can set. Without
    /// `O_NONBLOCK` the rest of the fix is decorative.
    func testGateSocketIsNonBlockingFromBirth() throws {
        let fd = GateSocketIO.makeSocket()
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertNotEqual(flags & O_NONBLOCK, 0,
                          "fd is blocking: connect() cannot be bounded")
    }

    /// The deadline mechanism itself, against a pipe that is never readable.
    /// This is the assertion `SO_SNDTIMEO` could not make: reproduced in C, the
    /// option read back as 0.200000 s while `connect()` to a blackholed address
    /// still blocked for 75,000.3 ms.
    func testWaitHonoursItsDeadlineOnAFdThatNeverBecomesReady() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        let started = DispatchTime.now()
        let outcome = GateSocketIO.wait(
            fd: fds[0], events: Int16(POLLIN), deadline: Date().addingTimeInterval(0.15)
        )
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
        ) / 1_000_000_000

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertGreaterThanOrEqual(elapsed, 0.10, "returned before the deadline")
        XCTAssertLessThan(elapsed, 10.0, "the deadline is nominal, not real (\(elapsed)s)")
    }

    func testWaitReturnsReadyAsSoonAsTheFdIsReadable() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        var byte: UInt8 = 42
        XCTAssertEqual(write(fds[1], &byte, 1), 1)
        XCTAssertEqual(
            GateSocketIO.wait(fd: fds[0], events: Int16(POLLIN),
                              deadline: Date().addingTimeInterval(5.0)),
            .ready
        )
    }

    func testWaitWithAnAlreadyExpiredDeadlineTimesOutImmediately() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertEqual(
            GateSocketIO.wait(fd: fds[0], events: Int16(POLLIN),
                              deadline: Date().addingTimeInterval(-1)),
            .timedOut
        )
    }

    // MARK: - W4: the doc said loopback-only; now the code says it too

    func testDefaultEndpointIsLoopback8765() {
        guard case .go(let plan) = GateEndpointPolicy.resolve(env: [:]) else {
            return XCTFail("the default environment must resolve")
        }
        XCTAssertEqual(plan.endpoint.host, "127.0.0.1")
        XCTAssertEqual(plan.endpoint.port, 8765)
        XCTAssertTrue(plan.endpoint.isLoopback)
        XCTAssertEqual(plan.timeout, 0.25, accuracy: 0.0001)
        XCTAssertNil(plan.observeOnlyNote)
    }

    func testLoopbackVariantsAreAccepted() {
        // "" and "   " mean "unset" — the operator has expressed no preference,
        // so the safe default (loopback) applies rather than a refusal.
        for host in ["127.0.0.1", "127.9.9.9", "localhost", "LocalHost", "", "   "] {
            guard case .go(let plan) = GateEndpointPolicy.resolve(
                env: ["SHANNON_HTTP_HOST": host]
            ) else {
                return XCTFail("\(host) must resolve to loopback")
            }
            XCTAssertTrue(plan.endpoint.isLoopback, host)
            XCTAssertTrue(plan.endpoint.host.hasPrefix("127."), "\(host) → \(plan.endpoint.host)")
        }
    }

    /// The defect verbatim: the comment claimed "loopback-only" while the host
    /// came straight from `SHANNON_HTTP_HOST`. Now the claim is enforced.
    func testNonLoopbackHostIsRefusedByDefault() {
        guard case .refuse(let why) = GateEndpointPolicy.resolve(
            env: ["SHANNON_HTTP_HOST": "10.0.0.5"]
        ) else {
            return XCTFail("a non-loopback gate host must be refused by default")
        }
        XCTAssertTrue(why.contains("SHANNON_GATE_ALLOW_REMOTE"), why)
    }

    func testNonLoopbackHostIsAllowedOnlyByExplicitOptIn() {
        guard case .go(let plan) = GateEndpointPolicy.resolve(
            env: ["SHANNON_HTTP_HOST": "10.0.0.5", "SHANNON_GATE_ALLOW_REMOTE": "1"]
        ) else {
            return XCTFail("SHANNON_GATE_ALLOW_REMOTE=1 must allow an off-box gate")
        }
        XCTAssertFalse(plan.endpoint.isLoopback)
        XCTAssertNil(plan.observeOnlyNote)
    }

    /// Observe-only: measure the impact before the restriction bites.
    func testObserveOnlyPolicySendsButRecordsWhatEnforceWouldHaveDone() {
        guard case .go(let plan) = GateEndpointPolicy.resolve(
            env: ["SHANNON_HTTP_HOST": "10.0.0.5", "SHANNON_GATE_HOST_POLICY": "observe"]
        ) else {
            return XCTFail("observe-only must not refuse")
        }
        XCTAssertFalse(plan.endpoint.isLoopback)
        let note = plan.observeOnlyNote ?? ""
        XCTAssertTrue(note.contains("observe-only"), note)
        XCTAssertTrue(note.contains("not loopback"), note)
    }

    func testUnknownHostPolicyIsRefusedRatherThanTreatedAsPermissive() {
        guard case .refuse(let why) = GateEndpointPolicy.resolve(
            env: ["SHANNON_HTTP_HOST": "10.0.0.5", "SHANNON_GATE_HOST_POLICY": "yolo"]
        ) else {
            return XCTFail("an unrecognised policy must fail closed")
        }
        XCTAssertTrue(why.contains("enforce|observe"), why)
    }

    /// No DNS on the ⌘D path, ever — and `inet_pton`, not `inet_addr`, so the
    /// legacy short forms that silently mean a *different* host are refused.
    func testUnresolvableAndLegacyHostFormsAreRefused() {
        for host in ["gate.internal", "::1", "10", "0x7f.1", "1.2.3.4.5", "999.1.1.1", "127.0.0"] {
            guard case .refuse(let why) = GateEndpointPolicy.resolve(
                env: ["SHANNON_HTTP_HOST": host]
            ) else {
                return XCTFail("\(host) must be refused, not guessed")
            }
            XCTAssertTrue(why.contains("IPv4 literal"), "\(host): \(why)")
        }
    }

    func testMalformedPortIsRefusedRatherThanDefaulted() {
        for port in ["0", "abc", "70000", "-1", "8765x"] {
            guard case .refuse(let why) = GateEndpointPolicy.resolve(
                env: ["SHANNON_HTTP_PORT": port]
            ) else {
                return XCTFail("SHANNON_HTTP_PORT=\(port) must be refused")
            }
            XCTAssertTrue(why.contains("SHANNON_HTTP_PORT"), why)
        }
        guard case .go(let plan) = GateEndpointPolicy.resolve(env: ["SHANNON_HTTP_PORT": ""])
        else { return XCTFail("an empty port means the default") }
        XCTAssertEqual(plan.endpoint.port, 8765)
    }

    func testTimeoutKnobIsClampedAndMalformedValuesAreRefused() {
        guard case .go(let fast) = GateEndpointPolicy.resolve(
            env: ["SHANNON_GATE_NOTIFY_TIMEOUT_MS": "1"]
        ) else { return XCTFail("1 ms must clamp, not refuse") }
        XCTAssertEqual(fast.timeout, 0.020, accuracy: 0.0001)

        guard case .go(let slow) = GateEndpointPolicy.resolve(
            env: ["SHANNON_GATE_NOTIFY_TIMEOUT_MS": "999999"]
        ) else { return XCTFail("a huge value must clamp, not refuse") }
        XCTAssertEqual(slow.timeout, 5.0, accuracy: 0.0001)

        guard case .refuse(let why) = GateEndpointPolicy.resolve(
            env: ["SHANNON_GATE_NOTIFY_TIMEOUT_MS": "soon"]
        ) else { return XCTFail("a malformed timeout must fail closed") }
        XCTAssertTrue(why.contains("SHANNON_GATE_NOTIFY_TIMEOUT_MS"), why)
    }

    func testKillSwitchStopsTheNotifyEntirely() {
        for off in ["off", "0", "false", "NO"] {
            guard case .refuse(let why) = GateEndpointPolicy.resolve(
                env: ["SHANNON_GATE_NOTIFY": off]
            ) else { return XCTFail("SHANNON_GATE_NOTIFY=\(off) must disable the notify") }
            XCTAssertTrue(why.contains("SHANNON_GATE_NOTIFY"), why)
        }
        guard case .go = GateEndpointPolicy.resolve(env: ["SHANNON_GATE_NOTIFY": "on"]) else {
            return XCTFail("the notify is on by default")
        }
    }

    // MARK: - Fail-closed end to end

    /// A policy refusal must not put a single packet on the wire.
    func testPolicyRefusalNeverReachesTheTransport() {
        let calls = Box(0)
        let counting = GateNotifyTransport { _, _, _ in
            calls.mutate { $0 += 1 }
            return AgentIngestGateNotifyTests.okResponse
        }
        for env in [
            ["SHANNON_HTTP_HOST": "10.0.0.5"],
            ["SHANNON_HTTP_HOST": "gate.internal"],
            ["SHANNON_HTTP_PORT": "abc"],
            ["SHANNON_GATE_NOTIFY": "off"],
            ["SHANNON_GATE_NOTIFY_TIMEOUT_MS": "soon"],
        ] {
            let outcome = AgentIngestService.notifyGateBestEffort(
                agentID: "local_test", task: "t", env: env, transport: counting
            )
            XCTAssertEqual(outcome.status, .refused, "\(env)")
            XCTAssertFalse(outcome.accepted, "\(env)")
            XCTAssertFalse(outcome.detail.isEmpty, "a refusal must say why: \(env)")
        }
        XCTAssertEqual(calls.get, 0, "a refused endpoint still opened a connection")
    }

    func testTransportFailureIsReportedAsRefusedWithTheDeadlineInTheReason() {
        let outcome = AgentIngestService.notifyGateBestEffort(
            agentID: "local_test", task: "t",
            env: ["SHANNON_GATE_NOTIFY_TIMEOUT_MS": "120"],
            transport: .refuseAll
        )
        XCTAssertEqual(outcome.status, .refused)
        XCTAssertTrue(outcome.detail.contains("127.0.0.1:8765"), outcome.detail)
        XCTAssertTrue(outcome.detail.contains("120 ms"), outcome.detail)
    }

    func testGateRejectionIsNotReportedAsSuccess() {
        let refusal = """
        HTTP/1.1 403 Forbidden\r
        \r
        {"error": "unknown_agent:claude_devtools"}
        """
        let outcome = AgentIngestService.notifyGateBestEffort(
            agentID: "claude_devtools", task: "t", env: [:],
            transport: GateNotifyTransport { _, _, _ in refusal }
        )
        XCTAssertEqual(outcome.status, .refused)
        XCTAssertFalse(outcome.accepted)
    }

    func testObserveOnlyNoteSurvivesAnAcceptedPost() {
        let outcome = AgentIngestService.notifyGateBestEffort(
            agentID: "local_test", task: "t",
            env: ["SHANNON_HTTP_HOST": "10.0.0.5", "SHANNON_GATE_HOST_POLICY": "observe"],
            transport: GateNotifyTransport { _, _, _ in AgentIngestGateNotifyTests.okResponse }
        )
        XCTAssertTrue(outcome.accepted)
        XCTAssertTrue(outcome.detail.contains("observe-only"), outcome.detail)
    }

    func testTransportReceivesTheResolvedEndpointAndDeadline() {
        let seen = Box<(GateEndpoint, TimeInterval)?>(nil)
        let outcome = AgentIngestService.notifyGateBestEffort(
            agentID: "local_test", task: "t",
            env: ["SHANNON_HTTP_PORT": "9999", "SHANNON_GATE_NOTIFY_TIMEOUT_MS": "300"],
            transport: GateNotifyTransport { ep, _, timeout in
                seen.set((ep, timeout))
                return AgentIngestGateNotifyTests.okResponse
            }
        )
        XCTAssertTrue(outcome.accepted, outcome.detail)
        XCTAssertEqual(seen.get?.0.host, "127.0.0.1")
        XCTAssertEqual(seen.get?.0.port, 9999)
        XCTAssertEqual(seen.get?.1 ?? 0, 0.3, accuracy: 0.0001)
    }

    // MARK: - The real BSD transport, hermetically

    /// Exercises the shipping non-blocking connect / send / recv against a real
    /// listener on an ephemeral loopback port. No daemon, no fixed port.
    func testRealTransportRoundTripsAgainstAStubGate() throws {
        let gate = try XCTUnwrap(StubHTTPGate(reply: Self.okResponse))
        defer { gate.stop() }
        let outcome = AgentIngestService.notifyGateBestEffort(
            agentID: "local_test", task: "hermetic round trip",
            env: ["SHANNON_HTTP_PORT": String(gate.port)],
            transport: .bsdSocket
        )
        XCTAssertTrue(outcome.accepted, outcome.detail)
    }

    /// A listener that accepts and then says nothing — the wedged gate. The
    /// call must come back at the deadline, not at some kernel default.
    func testRealTransportGivesUpOnAWedgedGateAtTheDeadline() throws {
        let gate = try XCTUnwrap(StubHTTPGate(reply: nil))
        defer { gate.stop() }
        let started = DispatchTime.now()
        let outcome = AgentIngestService.notifyGateBestEffort(
            agentID: "local_test", task: "wedged gate",
            env: [
                "SHANNON_HTTP_PORT": String(gate.port),
                "SHANNON_GATE_NOTIFY_TIMEOUT_MS": "150",
            ],
            transport: .bsdSocket
        )
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
        ) / 1_000_000_000
        XCTAssertEqual(outcome.status, .refused)
        XCTAssertGreaterThanOrEqual(elapsed, 0.10, "returned before the deadline")
        XCTAssertLessThan(elapsed, 10.0, "the deadline is nominal, not real (\(elapsed)s)")
    }

    /// Closed port on loopback: ECONNREFUSED, reported honestly and instantly.
    func testRealTransportFailsClosedOnAClosedPort() throws {
        let gate = try XCTUnwrap(StubHTTPGate(reply: Self.okResponse))
        let port = gate.port
        gate.stop()   // nothing listens there any more
        let outcome = AgentIngestService.notifyGateBestEffort(
            agentID: "local_test", task: "closed port",
            env: ["SHANNON_HTTP_PORT": String(port)],
            transport: .bsdSocket
        )
        XCTAssertEqual(outcome.status, .refused)
        XCTAssertFalse(outcome.accepted)
    }

    // MARK: - Response framing

    func testResponseIsCompleteRespectsContentLength() {
        let head = Array("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n".utf8)
        XCTAssertFalse(GateSocketIO.responseIsComplete(head))
        XCTAssertFalse(GateSocketIO.responseIsComplete(head + Array("abcd".utf8)))
        XCTAssertTrue(GateSocketIO.responseIsComplete(head + Array("abcde".utf8)))
        XCTAssertFalse(GateSocketIO.responseIsComplete(Array("HTTP/1.1 200 OK\r\n".utf8)))
        XCTAssertTrue(GateSocketIO.responseIsComplete(Array("HTTP/1.1 204 No Content\r\n\r\n".utf8)))
    }
}
