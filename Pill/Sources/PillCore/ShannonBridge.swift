import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Live entropy readout from the Shannon Python coordination layer.
public struct ShannonStatus: Codable, Sendable, Equatable {
    public var entropy: Double
    public var deltaH: Double
    public var collapsed: Bool
    public var tokenCount: Int
    public var backend: String
    public var agent: String?

    enum CodingKeys: String, CodingKey {
        case entropy
        case deltaH = "delta_h"
        case collapsed
        case tokenCount = "token_count"
        case backend
        case agent
    }

    public init(
        entropy: Double,
        deltaH: Double,
        collapsed: Bool,
        tokenCount: Int,
        backend: String,
        agent: String? = nil
    ) {
        self.entropy = entropy
        self.deltaH = deltaH
        self.collapsed = collapsed
        self.tokenCount = tokenCount
        self.backend = backend
        self.agent = agent
    }

    /// Compact readout for the collapsed pill: "H 8.4 ▽2.1".
    public var pillLabel: String {
        let h = String(format: "%.1f", entropy)
        guard deltaH < 0 else { return "H \(h)" }
        return "H \(h) ▽\(String(format: "%.1f", abs(deltaH)))"
    }
}

public struct BridgeRequest: Codable, Sendable, Equatable {
    public var command: String
    public init(command: String) { self.command = command }
}

public enum BridgeError: Error, Equatable {
    case socketUnavailable
    case connectionFailed(Int32)
    case pathTooLong
    case closed
    case decodeFailed(String)
}

/// Newline-delimited JSON framing, shared with `shannon.pill_bridge`.
/// Pure so the wire format can be tested without a socket.
public enum BridgeCodec {
    public static func encode(_ request: BridgeRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return data
    }

    public static func decodeStatus(_ line: Data) throws -> ShannonStatus {
        do {
            return try JSONDecoder().decode(ShannonStatus.self, from: line)
        } catch {
            throw BridgeError.decodeFailed(String(describing: error))
        }
    }

    /// Split a buffer into complete newline-terminated frames plus the remainder.
    public static func frames(from buffer: Data) -> (lines: [Data], remainder: Data) {
        var lines: [Data] = []
        var rest = buffer
        while let idx = rest.firstIndex(of: 0x0A) {
            let line = rest[rest.startIndex..<idx]
            if !line.isEmpty { lines.append(Data(line)) }
            rest = Data(rest[rest.index(after: idx)...])
        }
        return (lines, rest)
    }
}

/// Blocking Unix-domain-socket client. Kept off the main thread by `ShannonBridge`.
public final class UnixSocketClient {
    private var fd: Int32 = -1
    private var buffer = Data()

    public init() {}
    deinit { close() }

    public var isConnected: Bool { fd >= 0 }

    public func connect(to path: String, timeout: TimeInterval = 2.0) throws {
        close()
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw BridgeError.socketUnavailable }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else {
            Darwin.close(s)
            throw BridgeError.pathTooLong
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        cstr, maxLen - 1)
            }
        }

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(s, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let err = errno
            Darwin.close(s)
            throw BridgeError.connectionFailed(err)
        }
        fd = s
        buffer.removeAll()
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    public func send(_ data: Data) throws {
        guard fd >= 0 else { throw BridgeError.closed }
        try data.withUnsafeBytes { raw in
            var sent = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < data.count {
                let n = Darwin.send(fd, base + sent, data.count - sent, 0)
                guard n > 0 else { throw BridgeError.closed }
                sent += n
            }
        }
    }

    /// Read one newline-terminated frame.
    public func readLine() throws -> Data {
        guard fd >= 0 else { throw BridgeError.closed }
        while true {
            let (lines, rest) = BridgeCodec.frames(from: buffer)
            if let first = lines.first {
                // Preserve any frames beyond the first.
                var remaining = Data()
                for extra in lines.dropFirst() {
                    remaining.append(extra)
                    remaining.append(0x0A)
                }
                remaining.append(rest)
                buffer = remaining
                return first
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { throw BridgeError.closed }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    public func request(_ req: BridgeRequest) throws -> ShannonStatus {
        try send(try BridgeCodec.encode(req))
        return try BridgeCodec.decodeStatus(try readLine())
    }
}

/// Polls the Python coordination layer and republishes to SwiftUI.
/// A missing socket is normal (agent not running) and shows as `connected == false`
/// rather than an error banner.
@MainActor
public final class ShannonBridge: ObservableObject {
    @Published public private(set) var status: ShannonStatus?
    @Published public private(set) var connected = false

    public let socketPath: String
    private let interval: TimeInterval
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.lebonhomme.shannon.pill.bridge")

    /// `nonisolated` so it can serve as a default argument to `init`, which
    /// callers may construct off the main actor.
    public nonisolated static var defaultSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["SHANNON_PILL_SOCKET"] {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.shannon/pill.sock"
    }

    public init(socketPath: String = ShannonBridge.defaultSocketPath, interval: TimeInterval = 1.0) {
        self.socketPath = socketPath
        self.interval = interval
    }

    public func start() {
        poll()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func poll() {
        let path = socketPath
        queue.async {
            let client = UnixSocketClient()
            let result: ShannonStatus? = {
                do {
                    try client.connect(to: path)
                    defer { client.close() }
                    return try client.request(BridgeRequest(command: "status"))
                } catch {
                    return nil
                }
            }()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = result
                self.connected = (result != nil)
            }
        }
    }
}
