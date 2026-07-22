import XCTest
import Darwin
@testable import PillCore

final class ShannonBridgeTests: XCTestCase {

    // MARK: Wire format

    func testStatusRoundTripsThroughSnakeCaseJSON() throws {
        let json = """
        {"entropy": 8.42, "delta_h": -3.51, "collapsed": true, \
        "token_count": 1024, "backend": "cpp", "agent": "flexaid-runner"}
        """.data(using: .utf8)!

        let status = try BridgeCodec.decodeStatus(json)
        XCTAssertEqual(status.entropy, 8.42, accuracy: 1e-9)
        XCTAssertEqual(status.deltaH, -3.51, accuracy: 1e-9)
        XCTAssertTrue(status.collapsed)
        XCTAssertEqual(status.tokenCount, 1024)
        XCTAssertEqual(status.backend, "cpp")
        XCTAssertEqual(status.agent, "flexaid-runner")
    }

    func testAgentFieldIsOptional() throws {
        let json = """
        {"entropy": 1.0, "delta_h": 0.0, "collapsed": false, \
        "token_count": 1, "backend": "numpy"}
        """.data(using: .utf8)!
        XCTAssertNil(try BridgeCodec.decodeStatus(json).agent)
    }

    func testMalformedPayloadThrowsDecodeFailed() {
        XCTAssertThrowsError(try BridgeCodec.decodeStatus(Data("not json".utf8))) { error in
            guard case BridgeError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }

    func testRequestEncodingIsNewlineTerminated() throws {
        let data = try BridgeCodec.encode(BridgeRequest(command: "status"))
        XCTAssertEqual(data.last, 0x0A)
        let text = String(decoding: data.dropLast(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"command\""))
        XCTAssertTrue(text.contains("status"))
    }

    // MARK: Framing

    func testFramingSplitsCompleteLinesAndKeepsRemainder() {
        let buffer = Data("{\"a\":1}\n{\"b\":2}\n{\"partial\"".utf8)
        let (lines, remainder) = BridgeCodec.frames(from: buffer)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(decoding: lines[0], as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(String(decoding: lines[1], as: UTF8.self), "{\"b\":2}")
        XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "{\"partial\"")
    }

    func testFramingIgnoresBlankLines() {
        let (lines, remainder) = BridgeCodec.frames(from: Data("\n\n{\"a\":1}\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(remainder.isEmpty)
    }

    func testFramingWithNoNewlineYieldsNothing() {
        let (lines, remainder) = BridgeCodec.frames(from: Data("{\"a\":1}".utf8))
        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(remainder.count, 7)
    }

    // MARK: Live socket

    func testClientRoundTripsAgainstLoopbackServer() throws {
        let path = Self.temporarySocketPath()
        let server = try LoopbackServer(path: path, response: """
        {"entropy": 7.25, "delta_h": -0.5, "collapsed": false, \
        "token_count": 88, "backend": "numba"}
        """)
        defer { server.stop() }

        let client = UnixSocketClient()
        try client.connect(to: path)
        defer { client.close() }

        let status = try client.request(BridgeRequest(command: "status"))
        XCTAssertEqual(status.entropy, 7.25, accuracy: 1e-9)
        XCTAssertEqual(status.tokenCount, 88)
        XCTAssertEqual(status.backend, "numba")
        XCTAssertEqual(server.received(), "{\"command\":\"status\"}")
    }

    func testConnectingToMissingSocketThrows() {
        let client = UnixSocketClient()
        XCTAssertThrowsError(try client.connect(to: "/tmp/shannon-pill-does-not-exist.sock")) { e in
            guard case BridgeError.connectionFailed = e else {
                return XCTFail("expected .connectionFailed, got \(e)")
            }
        }
        XCTAssertFalse(client.isConnected)
    }

    func testOverlongSocketPathIsRejected() {
        // sockaddr_un.sun_path is 104 bytes on Darwin.
        let client = UnixSocketClient()
        let longPath = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        XCTAssertThrowsError(try client.connect(to: longPath)) { e in
            XCTAssertEqual(e as? BridgeError, .pathTooLong)
        }
    }

    // MARK: Pill label

    func testPillLabelShowsDeltaOnlyWhenNegative() {
        let dropping = ShannonStatus(entropy: 8.42, deltaH: -3.51, collapsed: true,
                                     tokenCount: 10, backend: "cpp")
        XCTAssertEqual(dropping.pillLabel, "H 8.4 ▽3.5")

        let steady = ShannonStatus(entropy: 8.42, deltaH: 0.2, collapsed: false,
                                   tokenCount: 10, backend: "cpp")
        XCTAssertEqual(steady.pillLabel, "H 8.4")
    }

    // MARK: Helpers

    private static func temporarySocketPath() -> String {
        // Keep well under sun_path's 104-byte limit.
        "/tmp/shannon-pill-test-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    /// Minimal single-shot Unix-domain server: accepts one client, reads one
    /// line, writes the canned response.
    private final class LoopbackServer {
        private let listenFD: Int32
        private let path: String
        private let thread: Thread

        init(path: String, response: String) throws {
            self.path = path
            unlink(path)

            // Held locally until the end of init: the pointer closures below
            // must not capture a partially initialized `self`.
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
                    // Qualified: XCTestCase also exposes a `bind` instance method.
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindRC == 0, Darwin.listen(fd, 1) == 0 else {
                Darwin.close(fd)
                throw BridgeError.connectionFailed(errno)
            }

            let box = ReceivedBox()
            thread = Thread {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var buf = [UInt8](repeating: 0, count: 1024)
                let n = recv(client, &buf, buf.count, 0)
                if n > 0 {
                    let text = String(decoding: buf[0..<n], as: UTF8.self)
                        .trimmingCharacters(in: .newlines)
                    box.set(text)
                }
                var payload = Array((response + "\n").utf8)
                _ = send(client, &payload, payload.count, 0)
                Darwin.close(client)
            }
            self.box = box
            thread.start()
        }

        private let box: ReceivedBox

        func received() -> String { box.get() }

        func stop() {
            Darwin.close(listenFD)
            unlink(path)
        }

        final class ReceivedBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = ""
            func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
            func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
        }
    }
}
