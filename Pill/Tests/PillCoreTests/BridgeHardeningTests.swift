import XCTest
import Darwin
@testable import PillCore

/// Transport-level fail-closed behaviour for the detector socket. A producer
/// that sends garbage, or that never terminates a frame, must not be able to
/// put a number on screen or exhaust memory in the UI process.
final class BridgeHardeningTests: XCTestCase {

    private func frame(
        _ entropy: String = "7.2", delta: String = "0.0",
        collapsed: String = "false", tokens: String = "10", backend: String = "\"cpp\""
    ) -> Data {
        Data("""
        {"entropy": \(entropy), "delta_h": \(delta), "collapsed": \(collapsed), \
        "token_count": \(tokens), "backend": \(backend)}
        """.utf8)
    }

    // MARK: - Value validation

    func testOutOfRangeEntropyIsRefused() {
        for value in ["1e9", "-1.0", "1025"] {
            XCTAssertThrowsError(try BridgeCodec.decodeStatus(frame(value)), value) { error in
                guard case BridgeError.valueOutOfRange = error else {
                    return XCTFail("expected .valueOutOfRange for \(value), got \(error)")
                }
            }
        }
    }

    /// A literal too large for `Double` never reaches the range guard —
    /// `JSONDecoder` refuses it first. Either way the frame is rejected, which
    /// is the property that matters.
    func testUnrepresentableNumbersAreRefusedByTheDecoder() {
        for field in [frame("1e400"), frame(delta: "1e400")] {
            XCTAssertThrowsError(try BridgeCodec.decodeStatus(field)) { error in
                guard case BridgeError.decodeFailed = error else {
                    return XCTFail("expected .decodeFailed, got \(error)")
                }
            }
        }
    }

    /// JSON cannot express NaN or Infinity, so the transport can never hand one
    /// up. The guard that does the work lives in `EntropyMeasurement.init?`,
    /// which any caller can reach with any Double.
    func testNonFiniteValuesAreRefusedAtMeasurementConstruction() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let src = EntropySource.bridge(backend: "cpp")
        XCTAssertNil(EntropyMeasurement(bits: .nan, source: src, measuredAt: now, now: now))
        XCTAssertNil(EntropyMeasurement(bits: .infinity, source: src, measuredAt: now, now: now))
        XCTAssertNil(EntropyMeasurement(bits: 3.5, deltaH: .nan, source: src,
                                        measuredAt: now, now: now))
        XCTAssertNil(EntropyMeasurement(bits: 3.5, deltaH: -.infinity, source: src,
                                        measuredAt: now, now: now))
    }

    func testNegativeTokenCountIsRefused() {
        XCTAssertThrowsError(try BridgeCodec.decodeStatus(frame(tokens: "-5"))) { error in
            guard case BridgeError.valueOutOfRange = error else {
                return XCTFail("expected .valueOutOfRange, got \(error)")
            }
        }
    }

    /// A producer that will not say whether it detected a collapse does not get
    /// its number displayed. Missing `collapsed` must not default to false.
    func testMissingCollapsedFieldIsRefused() {
        let json = Data("""
        {"entropy": 7.2, "delta_h": 0.0, "token_count": 10, "backend": "cpp"}
        """.utf8)
        XCTAssertThrowsError(try BridgeCodec.decodeStatus(json)) { error in
            guard case BridgeError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }

    func testMissingBackendFieldIsRefused() {
        let json = Data("""
        {"entropy": 7.2, "delta_h": 0.0, "collapsed": false, "token_count": 10}
        """.utf8)
        XCTAssertThrowsError(try BridgeCodec.decodeStatus(json)) { error in
            guard case BridgeError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }

    /// A *blank* backend decodes on purpose — it is caught one layer up as an
    /// explicit absence. Dropping the frame here would hide the fact that
    /// something is connected and refusing to identify itself.
    func testBlankBackendDecodesThenResolvesToAbsent() throws {
        let status = try BridgeCodec.decodeStatus(frame(backend: "\"\""))
        XCTAssertTrue(status.isSynthetic)
        XCTAssertNil(status.measuredCollapsed)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = EntropyProvenance.resolve(
            bridgeConnected: true, bridgeStatus: status,
            gate: [], gateDBAvailable: true, now: now,
            policy: EntropyPolicy(mode: .enforce)
        )
        XCTAssertEqual(reading.absence, .syntheticSource(""))
        XCTAssertNil(reading.currentBits)
        XCTAssertNotEqual(reading.verdict, .healthy)
    }

    func testValidFrameStillDecodes() throws {
        let status = try BridgeCodec.decodeStatus(frame("8.42", delta: "-3.51", collapsed: "true"))
        XCTAssertEqual(status.entropy, 8.42, accuracy: 1e-9)
        XCTAssertEqual(status.measuredCollapsed, true)
    }

    /// Zero is a legal transport value — the policy question of whether it is a
    /// usable measurement belongs to `EntropyMeasurement`, not the socket.
    func testZeroEntropyDecodesButIsRefusedAsAMeasurement() throws {
        let status = try BridgeCodec.decodeStatus(frame("0.0"))
        XCTAssertEqual(status.entropy, 0)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(EntropyMeasurement(
            bits: status.entropy, source: .bridge(backend: status.backend),
            measuredAt: now, now: now
        ))
    }

    // MARK: - Oversized input

    /// An unterminated frame must fail closed rather than growing the buffer in
    /// the UI process without bound.
    func testUnterminatedFrameIsRefusedInsteadOfBufferedForever() throws {
        let path = "/tmp/shannon-pill-flood-\(UInt32.random(in: 0...UInt32.max)).sock"
        let server = try FloodServer(path: path, bytes: BridgeCodec.maxFrameBytes + 200_000)
        defer { server.stop() }

        let client = UnixSocketClient()
        try client.connect(to: path, timeout: 5)
        defer { client.close() }

        // `.closed` is NOT accepted here. The flood is finite, so an unbounded
        // reader swallows all of it and then sees the server hang up — which
        // throws `.closed` and would let this test pass with the bound removed.
        // It has to be `.frameTooLarge`, at a buffer no larger than the ceiling
        // plus one read, or the test proves nothing about the ceiling.
        XCTAssertThrowsError(try client.readLine()) { error in
            guard case BridgeError.frameTooLarge(let n) = error else {
                return XCTFail("expected .frameTooLarge, got \(error) — the bound did not fire")
            }
            XCTAssertGreaterThan(n, 0)
            XCTAssertLessThanOrEqual(
                n, BridgeCodec.maxFrameBytes + 4096,
                "refused, but only after buffering more than the ceiling plus one read"
            )
        }
    }

    func testMaxFrameBytesHasASaneDefault() {
        XCTAssertGreaterThanOrEqual(BridgeCodec.maxFrameBytes, 1024)
        XCTAssertLessThanOrEqual(BridgeCodec.maxFrameBytes, 8 * 1024 * 1024)
    }

    // MARK: - Peer hang-up

    /// A peer that goes away mid-conversation must surface as `.closed`, not as
    /// SIGPIPE. The gate restarting under a live 1 s poll is routine, and
    /// without `SO_NOSIGPIPE` on the client socket the default signal
    /// disposition terminates the entire pill process — a monitor that dies
    /// silently when the thing it monitors restarts is worse than no monitor.
    ///
    /// If this regresses the xctest process is killed with signal 13 and takes
    /// the rest of the suite with it, which is exactly the production failure
    /// being guarded against. Note the `SO_NOSIGPIPE` inside `FloodServer` does
    /// NOT cover this: that one protects the test's own server socket, so
    /// removing the production client's option left the whole suite green.
    func testSendToHungUpPeerSurfacesAsClosedNotSIGPIPE() throws {
        let path = "/tmp/shannon-pill-hangup-\(UInt32.random(in: 0...UInt32.max)).sock"
        let server = try HangUpServer(path: path)
        defer { server.stop() }

        let client = UnixSocketClient()
        try client.connect(to: path, timeout: 2)
        defer { client.close() }
        server.waitForHangUp()

        // Large enough that the write cannot be absorbed by a socket buffer.
        let payload = Data(repeating: UInt8(ascii: "x"), count: 1_000_000)
        var caught: Error?
        for _ in 0..<3 {
            do { try client.send(payload) } catch { caught = error; break }
        }
        guard let caught else {
            return XCTFail("expected the hung-up peer to surface as an error")
        }
        XCTAssertEqual(caught as? BridgeError, BridgeError.closed)
    }

    // MARK: - Helpers

    /// Accepts exactly one connection and immediately hangs up on it.
    private final class HangUpServer {
        private let listenFD: Int32
        private let path: String
        private let done = DispatchSemaphore(value: 0)

        init(path: String) throws {
            self.path = path
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BridgeError.socketUnavailable }
            listenFD = fd
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
                path.withCString { c in
                    strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self),
                            c, maxLen - 1)
                }
            }
            let bindRC = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindRC == 0, Darwin.listen(fd, 1) == 0 else {
                Darwin.close(fd)
                throw BridgeError.connectionFailed(errno)
            }
            let sem = done
            Thread {
                let c = accept(fd, nil, nil)
                if c >= 0 { Darwin.close(c) }
                sem.signal()
            }.start()
        }

        /// Deterministic: the send only happens once the peer has actually gone.
        func waitForHangUp() { _ = done.wait(timeout: .now() + 5) }

        func stop() {
            Darwin.close(listenFD)
            unlink(path)
        }
    }

    /// Writes a large newline-free payload, so `readLine` can never complete.
    private final class FloodServer {
        private let listenFD: Int32
        private let path: String
        private let thread: Thread

        init(path: String, bytes: Int) throws {
            self.path = path
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BridgeError.socketUnavailable }
            listenFD = fd

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
                path.withCString { c in
                    strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self),
                            c, maxLen - 1)
                }
            }
            let bindRC = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindRC == 0, Darwin.listen(fd, 1) == 0 else {
                Darwin.close(fd)
                throw BridgeError.connectionFailed(errno)
            }
            thread = Thread {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                // The client refuses and hangs up mid-flood; without this the
                // next `send` would SIGPIPE and take the test process with it.
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                           socklen_t(MemoryLayout<Int32>.size))
                var chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 16384)
                var written = 0
                while written < bytes {
                    let n = send(client, &chunk, min(chunk.count, bytes - written), 0)
                    if n <= 0 { break }
                    written += n
                }
                Darwin.close(client)
            }
            thread.start()
        }

        func stop() {
            Darwin.close(listenFD)
            unlink(path)
        }
    }
}
