import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Pure + best-effort helpers to auto-attach the Shannon hub (gate).
///
/// The pill reads `/tmp/shannon.sock` and `~/.shannon/agent_hub.db`. Starting
/// `hub/shannon_gate.py` is best-effort: missing script or spawn failure is
/// fail-closed with a reason — never a hang on the main thread.
///
/// **Stale sockets:** a leftover `*.sock` file after a dead gate must not be
/// treated as “already running”. Readiness requires a successful connect (or an
/// injectable probe); stale paths are unlinked so a fresh gate can bind.
public enum HubEnsure {

    public static let defaultSocketPath = GateApprovalClient.defaultSocketPath

    /// Outcome of an ensure-running decision or spawn attempt.
    public enum Result: Equatable, Sendable {
        case alreadyRunning
        case started
        case missingScript
        case spawnFailed(String)

        public var isUp: Bool {
            switch self {
            case .alreadyRunning, .started: return true
            case .missingScript, .spawnFailed: return false
            }
        }

        public var shortLabel: String {
            switch self {
            case .alreadyRunning: return "hub already running"
            case .started: return "hub started"
            case .missingScript: return "hub script missing"
            case .spawnFailed(let r): return "hub start failed: \(r)"
            }
        }
    }

    /// Result of probing the gate Unix socket for a live listener.
    public enum SocketProbe: Equatable, Sendable {
        /// `connect()` succeeded — a process is accepting connections.
        case listening
        /// Path does not exist (or was cleaned after stale).
        case absent
        /// Path exists but is not accepting connections (dead gate leftover).
        case stale
    }

    // MARK: Pure policy (unit-tested)

    /// Whether we should attempt to spawn the gate.
    ///
    /// - Parameters:
    ///   - listening: true only when a process is accepting on the socket.
    ///   - scriptExists: `shannon_gate.py` found on disk.
    public static func shouldStart(listening: Bool, scriptExists: Bool) -> Bool {
        !listening && scriptExists
    }

    /// Back-compat alias: `socketUp` means **listening**, not mere path existence.
    public static func shouldStart(socketUp: Bool, scriptExists: Bool) -> Bool {
        shouldStart(listening: socketUp, scriptExists: scriptExists)
    }

    /// Plan the ensure action without I/O (tests).
    ///
    /// - Parameter listening: true when the gate is known to accept connections.
    public static func plan(
        listening: Bool,
        scriptExists: Bool
    ) -> Result {
        if listening { return .alreadyRunning }
        if !scriptExists { return .missingScript }
        return .started
    }

    /// Back-compat: `socketUp` == listening.
    public static func plan(socketUp: Bool, scriptExists: Bool) -> Result {
        plan(listening: socketUp, scriptExists: scriptExists)
    }

    /// Pure decision after a probe: stale is treated as not listening.
    public static func isListening(_ probe: SocketProbe) -> Bool {
        if case .listening = probe { return true }
        return false
    }

    // MARK: Socket readiness (connect, not mere fileExists)

    /// True only when a process accepts connections on `path`.
    ///
    /// Stale sock files are unlinked (when `unlinkStale`) so a new gate can bind.
    public static func isSocketUp(
        path: String = defaultSocketPath,
        unlinkStale: Bool = true
    ) -> Bool {
        isListening(probeSocket(path: path, unlinkStale: unlinkStale))
    }

    /// Probe the socket: connect with a short timeout; classify listening/absent/stale.
    public static func probeSocket(
        path: String = defaultSocketPath,
        unlinkStale: Bool = true,
        fileManager: FileManager = .default
    ) -> SocketProbe {
        #if canImport(Darwin)
        let exists = fileManager.fileExists(atPath: path)
        if !exists { return .absent }

        if canConnect(toUnixSocket: path) {
            return .listening
        }

        // Path present but not accepting — dead gate / garbage file.
        if unlinkStale {
            try? fileManager.removeItem(atPath: path)
            // After unlink, treat as absent for ensure logic.
            return fileManager.fileExists(atPath: path) ? .stale : .absent
        }
        return .stale
        #else
        return fileManager.fileExists(atPath: path) ? .stale : .absent
        #endif
    }

    #if canImport(Darwin)
    /// Non-blocking-ish connect attempt (uses SO_SNDTIMEO/RCVTIMEO).
    private static func canConnect(toUnixSocket path: String, timeout: TimeInterval = 0.25) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }
    #endif

    /// Locate `hub/shannon_gate.py` from env / common layouts.
    ///
    /// When `SHANNON_ROOT` or `SHANNON_REPO` is set, **only** those roots are
    /// searched (fail-closed for tests / explicit installs). Otherwise fall
    /// back to common developer checkouts under `home`.
    public static func resolveGateScript(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        home: URL? = nil
    ) -> URL? {
        let homeURL = home ?? fileManager.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        let envRoot = environment["SHANNON_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
        let envRepo = environment["SHANNON_REPO"].flatMap { $0.isEmpty ? nil : $0 }
        if let root = envRoot {
            candidates.append(URL(fileURLWithPath: root).appendingPathComponent("hub/shannon_gate.py"))
        }
        if let repo = envRepo {
            candidates.append(URL(fileURLWithPath: repo).appendingPathComponent("hub/shannon_gate.py"))
        }
        let envPinned = envRoot != nil || envRepo != nil
        if !envPinned {
            candidates.append(homeURL.appendingPathComponent("Projects/Shannon/hub/shannon_gate.py"))
            candidates.append(homeURL.appendingPathComponent("Developer/Shannon/hub/shannon_gate.py"))
            candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("hub/shannon_gate.py"))
            candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("../hub/shannon_gate.py"))
        }

        for url in candidates {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                return url
            }
        }
        return nil
    }

    // MARK: Live ensure (best-effort, off-main friendly)

    /// Ensure the gate is up. Safe to call from a background queue.
    ///
    /// Idempotent when a **listening** socket is present. Stale sock files are
    /// removed and the gate is spawned when the script is available.
    @discardableResult
    public static func ensureRunning(
        socketPath: String = defaultSocketPath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        home: URL? = nil,
        pythonPath: String? = nil,
        spawn: ((URL, String) throws -> Void)? = nil,
        waitForSocket: TimeInterval = 1.2,
        /// Injectable probe for tests (defaults to real connect/unlink).
        probe: ((String) -> SocketProbe)? = nil
    ) -> Result {
        let probeFn = probe ?? { path in
            probeSocket(path: path, unlinkStale: true, fileManager: fileManager)
        }
        let state = probeFn(socketPath)
        if isListening(state) { return .alreadyRunning }

        guard let script = resolveGateScript(
            environment: environment,
            fileManager: fileManager,
            home: home
        ) else {
            return .missingScript
        }

        let py = pythonPath
            ?? environment["SHANNON_PYTHON"]
            ?? (fileManager.fileExists(atPath: "/usr/bin/python3") ? "/usr/bin/python3" : "python3")

        do {
            if let spawn {
                try spawn(script, py)
            } else {
                try defaultSpawn(script: script, python: py, environment: environment, fileManager: fileManager)
            }
        } catch {
            return .spawnFailed(error.localizedDescription)
        }

        // Brief poll for a **listening** socket — never hang forever.
        let deadline = Date().addingTimeInterval(max(0.1, waitForSocket))
        while Date() < deadline {
            if isListening(probeFn(socketPath)) { return .started }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isListening(probeFn(socketPath)) { return .started }
        return .spawnFailed("socket not listening at \(socketPath)")
    }

    private static func defaultSpawn(
        script: URL,
        python: String,
        environment: [String: String],
        fileManager: FileManager
    ) throws {
        let logDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".shannon")
        try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("gate.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        _ = try? logHandle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path]
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.qualityOfService = .utility
        var env = environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        try process.run()
    }
}
