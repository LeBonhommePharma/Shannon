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
    /// Optional sliding-window z-score from the detector (collapse threshold ~ −3.2).
    public var zScore: Double?
    /// Optional short token/context snippet — never required; blank → nil.
    public var tokenSnippet: String?
    /// Wire kind: `"status"` (poll reply) or `"event"` (push). Default status.
    public var kind: String?

    enum CodingKeys: String, CodingKey {
        case entropy
        case deltaH = "delta_h"
        case collapsed
        case tokenCount = "token_count"
        case backend
        case agent
        case zScore = "z_score"
        case tokenSnippet = "token_snippet"
        case kind
    }

    public init(
        entropy: Double,
        deltaH: Double,
        collapsed: Bool,
        tokenCount: Int,
        backend: String,
        agent: String? = nil,
        zScore: Double? = nil,
        tokenSnippet: String? = nil,
        kind: String? = nil
    ) {
        self.entropy = entropy
        self.deltaH = deltaH
        self.collapsed = collapsed
        self.tokenCount = tokenCount
        self.backend = backend
        self.agent = agent
        self.zScore = zScore
        self.tokenSnippet = tokenSnippet
        self.kind = kind
    }

    /// Collapse as a tri-state: `nil` when the producer of this status does not
    /// measure anything.
    ///
    /// `collapsed` is a non-optional `Bool` on the wire because a real detector
    /// always answers the question. A *synthetic* producer does not, and the
    /// placeholder used to hardcode `false` — so "no detector attached" asserted
    /// "not collapsed" and a dead monitor read as a healthy one. Anything making
    /// a safety judgement must read this, never `collapsed` directly: unknown is
    /// not false.
    public var measuredCollapsed: Bool? { isSynthetic ? nil : collapsed }

    /// Compact readout for the collapsed pill: "H 8.4 ▽2.1".
    public var pillLabel: String {
        let h = String(format: "%.1f", entropy)
        guard deltaH < 0 else { return "H \(h)" }
        return "H \(h) ▽\(String(format: "%.1f", abs(deltaH)))"
    }

    /// Thermodynamic badge including optional z-score.
    public var refereeLabel: String? {
        EntropyRailLogic.summaryLabel(h: entropy, deltaH: deltaH, zScore: zScore)
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
    /// A producer sent more than `BridgeCodec.maxFrameBytes` without a newline.
    /// The connection is dropped rather than buffered indefinitely.
    case frameTooLarge(Int)
    /// The frame parsed but carried a number no detector could have measured.
    case valueOutOfRange(String)
}

/// Newline-delimited JSON framing, shared with `shannon.pill_bridge`.
/// Pure so the wire format can be tested without a socket.
public enum BridgeCodec {
    public static func encode(_ request: BridgeRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return data
    }

    /// Largest single frame we will buffer before giving up on a producer.
    ///
    /// Operator knob `SHANNON_PILL_MAX_FRAME_BYTES` (default 65536, clamped to
    /// 1 KiB … 8 MiB). A producer that never sends a newline used to grow
    /// `UnixSocketClient.buffer` without bound inside the UI process; it now
    /// fails closed with `.frameTooLarge` and the poll reports "not connected".
    public static let maxFrameBytes: Int = {
        let fallback = 64 * 1024
        guard let raw = ProcessInfo.processInfo.environment["SHANNON_PILL_MAX_FRAME_BYTES"]?
            .trimmingCharacters(in: .whitespaces),
            let value = Int(raw)
        else { return fallback }
        return min(max(value, 1024), 8 * 1024 * 1024)
    }()

    /// Hard ceiling on a decoded entropy, independent of `EntropyPolicy`. This
    /// is a transport sanity check: above this the frame is corrupt, not merely
    /// out of policy.
    public static let maxDecodableBits: Double = 1024

    /// Decode one status frame, refusing values no detector could have produced.
    ///
    /// Fail-closed behaviour:
    /// - not JSON, or missing any required field (including `collapsed` and
    ///   `backend`) → `.decodeFailed`. A producer that will not say whether it
    ///   detected a collapse does not get to have its number displayed.
    /// - a literal that overflows `Double` (`1e400`) or a JSON `NaN`/`Infinity`
    ///   → `.decodeFailed`, refused by `JSONDecoder` before we see it.
    /// - negative `entropy`, `entropy` above `maxDecodableBits`, or negative
    ///   `token_count` → `.valueOutOfRange`.
    ///
    /// The range guard is written as `>= 0 && <= maxDecodableBits` so a NaN that
    /// ever reached it would fail both comparisons and be refused too — there is
    /// no separate `isFinite` check because there is no input that could reach
    /// one, and an unreachable guard is just a claim nobody tests.
    ///
    /// A *blank or unrecognised* `backend` decodes successfully on purpose: it
    /// is caught one layer up by `ShannonStatus.isSynthetic`, which turns it
    /// into an explicit `.absent` reading. Dropping the frame here would hide
    /// the fact that something is connected and refusing to identify itself.
    public static func decodeStatus(_ line: Data) throws -> ShannonStatus {
        let status: ShannonStatus
        do {
            status = try JSONDecoder().decode(ShannonStatus.self, from: line)
        } catch {
            throw BridgeError.decodeFailed(String(describing: error))
        }
        guard status.entropy >= 0, status.entropy <= maxDecodableBits else {
            throw BridgeError.valueOutOfRange("entropy=\(status.entropy)")
        }
        guard status.tokenCount >= 0 else {
            throw BridgeError.valueOutOfRange("token_count=\(status.tokenCount)")
        }
        return status
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

        // Without this, writing to a socket whose peer has gone away raises
        // SIGPIPE and terminates the whole pill. The gate restarting mid-poll is
        // routine, so the default behaviour is a crash waiting to happen; we
        // want `send` to return EPIPE and surface as `.closed` instead.
        var noSigPipe: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

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
            // Refuse before allocating more: a producer that never terminates a
            // frame must not be able to grow this buffer without bound.
            guard buffer.count <= BridgeCodec.maxFrameBytes else {
                close()
                throw BridgeError.frameTooLarge(buffer.count)
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
///
/// **Transport:**
/// - Heartbeat poll (default cadence) remains as fallback on ``pollQueue``.
/// - Push path: `subscribe` keeps a second socket open on **dedicated**
///   ``pushQueue`` so a blocking `readLine` can never starve poll/stop.
/// - Producer emits NDJSON status frames on significant ΔH / collapse. UI applies
///   them via ``applyPush(_:)`` without waiting for the next poll tick.
///
/// Connection is reused across polls when the peer stays up (connect once, request
/// repeatedly). On MainActor, `status` / `connected` are only reassigned when the
/// value actually changes — equality-gated so SwiftUI does not thrash on identical
/// frames. The entropy engine never waits on the UI (socket I/O is off-main).
@MainActor
public final class ShannonBridge: ObservableObject {
    @Published public private(set) var status: ShannonStatus?
    @Published public private(set) var connected = false
    /// Sliding-window H samples from push + poll (oldest → newest). Decorative
    /// rails read this; never invents samples when disconnected.
    @Published public private(set) var hHistory: [Double] = []
    /// True when the last status arrived via push (not the poll heartbeat).
    @Published public private(set) var lastUpdateWasPush = false
    /// Monotonic generation for significant push events (UI can react without 1 Hz lag).
    @Published public private(set) var pushGeneration: UInt64 = 0
    /// Counts successful poll heartbeats (tests: push must not starve poll).
    @Published public private(set) var pollGeneration: UInt64 = 0

    public let socketPath: String
    private let interval: TimeInterval
    private var timer: Timer?

    /// Poll / status request I/O only. Never runs the blocking push read loop.
    private let pollQueue = DispatchQueue(label: "com.lebonhomme.shannon.pill.bridge.poll")
    /// Subscribe / push I/O only. Isolated so `readLine` cannot block poll or stop.
    private let pushQueue = DispatchQueue(label: "com.lebonhomme.shannon.pill.bridge.push")

    /// Shared clients. Poll client is touched only on `pollQueue`; push client
    /// primary I/O is on `pushQueue`. `close()` is safe from `stop()` on any
    /// thread to unblock a blocked `recv` (standard Unix pattern).
    private final class ClientBox: @unchecked Sendable {
        var client = UnixSocketClient()
        var pushClient = UnixSocketClient()
        private let lock = NSLock()
        private var _pushRunning = false
        var pushRunning: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _pushRunning }
            set { lock.lock(); _pushRunning = newValue; lock.unlock() }
        }
    }
    private let clientBox = ClientBox()

    /// `nonisolated` so it can serve as a default argument to `init`, which
    /// callers may construct off the main actor.
    public nonisolated static var defaultSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["SHANNON_PILL_SOCKET"] {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.shannon/pill.sock"
    }

    public init(
        socketPath: String = ShannonBridge.defaultSocketPath,
        interval: TimeInterval = UICadence.bridgeInterval
    ) {
        self.socketPath = socketPath
        self.interval = UICadence.clampBridgeInterval(interval)
    }

    public func start() {
        poll()
        startPushListener()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        let box = clientBox
        // Flag first, then close fds immediately so a blocked `recv` on the
        // push queue unblocks without waiting for that queue to drain.
        box.pushRunning = false
        box.pushClient.close()
        box.client.close()
        // Drain residual work so the next start() does not race a half-dead loop.
        pollQueue.async {
            box.client.close()
        }
        pushQueue.async {
            box.pushClient.close()
        }
    }

    public func poll() {
        let path = socketPath
        let box = clientBox
        pollQueue.async { [weak self] in
            let result: ShannonStatus? = {
                do {
                    if !box.client.isConnected {
                        try box.client.connect(to: path)
                    }
                    return try box.client.request(BridgeRequest(command: "status"))
                } catch {
                    // Drop a dead socket so the next poll reconnects cleanly.
                    box.client.close()
                    return nil
                }
            }()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyStatus(result, fromPush: false)
            }
        }
    }

    /// Apply a decoded status from any path (poll heartbeat or push event).
    ///
    /// Pure-side effects are limited to published properties; never blocks the
    /// producer socket (caller already decoded off-main).
    ///
    /// - When `result == nil` and `fromPush == false` (poll failure): clear
    ///   connected — heartbeat is the authority for liveness.
    /// - When `result == nil` and `fromPush == true`: push path lost the
    ///   producer; clear connected only if status is already gone or we force
    ///   a disconnect publish so a dead producer cannot leave a stale live flag
    ///   if poll is also quiet. Prefer poll for truth; still publish nil so a
    ///   push-only death is visible before the next poll tick.
    public func applyStatus(_ result: ShannonStatus?, fromPush: Bool) {
        let previous = status
        if result == nil {
            // Disconnect: fail closed. Poll nil always clears; push nil clears
            // when we were showing a live status so producer death is not sticky.
            if !fromPush || previous != nil {
                if connected { connected = false }
                if BridgePushLogic.shouldPublishStatus(previous: previous, next: nil) {
                    status = nil
                }
            }
            if !fromPush {
                lastUpdateWasPush = false
            }
            return
        }
        let up = true
        if connected != up { connected = up }
        if !fromPush {
            pollGeneration &+= 1
        }
        if BridgePushLogic.shouldPublishStatus(previous: previous, next: result) {
            status = result
        }
        if let result, !result.isSynthetic {
            hHistory = EntropyRailLogic.append(history: hHistory, entropy: result.entropy)
            if fromPush, BridgePushLogic.isSignificantEvent(previous: previous, next: result) {
                lastUpdateWasPush = true
                pushGeneration &+= 1
            } else if !fromPush {
                lastUpdateWasPush = false
            }
        }
    }

    /// Test / pure-entry apply of a push NDJSON frame (no socket).
    public func applyPush(_ line: Data) throws {
        let status = try BridgeCodec.decodeStatus(line)
        applyStatus(status, fromPush: true)
    }

    // MARK: - Push listener

    /// Open a long-lived `subscribe` connection on ``pushQueue`` only.
    private func startPushListener() {
        let path = socketPath
        let box = clientBox
        pushQueue.async { [weak self] in
            guard let self else { return }
            if box.pushRunning { return }
            box.pushRunning = true
            self.runPushLoop(path: path, box: box)
        }
    }

    private nonisolated func runPushLoop(path: String, box: ClientBox) {
        while box.pushRunning {
            do {
                if !box.pushClient.isConnected {
                    try box.pushClient.connect(to: path, timeout: 2.0)
                    try box.pushClient.send(try BridgeCodec.encode(BridgeRequest(command: "subscribe")))
                }
                // Read unsolicited frames until disconnect. Blocking is OK:
                // this loop owns pushQueue exclusively; poll uses pollQueue.
                let line = try box.pushClient.readLine()
                let decoded = try BridgeCodec.decodeStatus(line)
                Task { @MainActor [weak self] in
                    self?.applyStatus(decoded, fromPush: true)
                }
            } catch {
                box.pushClient.close()
                // Producer / subscribe path died — publish disconnect so a
                // stale "connected" does not linger until the next poll.
                Task { @MainActor [weak self] in
                    self?.applyStatus(nil, fromPush: true)
                }
                // Back off briefly; poll heartbeat covers the gap.
                if box.pushRunning {
                    Thread.sleep(forTimeInterval: 0.4)
                }
            }
        }
        box.pushClient.close()
    }
}
