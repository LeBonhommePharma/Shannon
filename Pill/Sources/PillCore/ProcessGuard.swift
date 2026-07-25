import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Single-instance lock so double-clicking Shannon.app does not spawn a second
/// invisible agent. Uses an exclusive flock on `~/.shannon/pill.lock`.
public enum ProcessGuard {
    public enum Outcome: Equatable {
        case acquired
        case alreadyRunning(pid: pid_t)
        case failed(String)
    }

    /// File descriptor kept open for the process lifetime (held by caller).
    public final class LockHandle: @unchecked Sendable {
        public let fd: Int32
        public let path: String
        init(fd: Int32, path: String) {
            self.fd = fd
            self.path = path
        }
        deinit {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    public static var defaultLockPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.shannon/pill.lock"
    }

    /// Try to acquire an exclusive non-blocking lock. On success the returned
    /// handle must be retained until the process exits.
    public static func acquire(path: String = defaultLockPath) -> (Outcome, LockHandle?) {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return (.failed("mkdir \(dir): \(error)"), nil)
        }

        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            return (.failed("open \(path): errno=\(errno)"), nil)
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Read the pid of the holder for a useful message.
            var buf = [UInt8](repeating: 0, count: 32)
            let n = read(fd, &buf, buf.count)
            let text = n > 0 ? String(bytes: buf[0..<n], encoding: .utf8) ?? "" : ""
            let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            close(fd)
            return (.alreadyRunning(pid: pid), nil)
        }

        // Record our pid so a second instance can report it.
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        let pidStr = "\(getpid())\n"
        _ = pidStr.withCString { write(fd, $0, strlen($0)) }

        return (.acquired, LockHandle(fd: fd, path: path))
    }
}

// MARK: - Kill-safety primitive (shared by DevServers stop, session end, …)

/// Why a process stop was refused. Fail-closed: when in doubt, do not kill.
public enum ProcessStopRefusal: String, Sendable, Equatable, Error {
    case invalidPid
    case protectedSystem
    case protectedShannon
    case notSameUser
    case notRunning
    case policyDenied

    public var message: String {
        switch self {
        case .invalidPid: return "Invalid process id"
        case .protectedSystem: return "Refusing to stop a system process"
        case .protectedShannon: return "Refusing to stop Shannon itself"
        case .notSameUser: return "Process is not owned by the current user"
        case .notRunning: return "Process is not running"
        case .policyDenied: return "Stop blocked by safety policy"
        }
    }
}

/// Shared kill-safety checks used by dev-server stop and future session-end.
public enum ProcessKillSafety {
    /// Bundle-id / path prefixes that must never be killed from the pill.
    public static let protectedNameFragments: [String] = [
        "shannon", "WindowServer", "kernel_task", "launchd", "loginwindow",
        "Finder", "Dock", "SystemUIServer",
    ]

    public static let protectedPathPrefixes: [String] = [
        "/System/", "/usr/sbin/", "/sbin/",
    ]

    /// Pure policy check — injectable evidence for unit tests.
    public static func canStop(
        pid: Int32,
        name: String? = nil,
        path: String? = nil,
        isAlive: (Int32) -> Bool = ProcessAttach.isProcessAlive
    ) -> Result<Void, ProcessStopRefusal> {
        guard pid > 1 else { return .failure(.invalidPid) }
        if !isAlive(pid) { return .failure(.notRunning) }

        let lowerName = (name ?? "").lowercased()
        let lowerPath = (path ?? "").lowercased()
        if lowerName.contains("shannon") || lowerPath.contains("shannonpill")
            || lowerPath.contains("/shannon") {
            return .failure(.protectedShannon)
        }
        for frag in protectedNameFragments {
            if lowerName == frag.lowercased() {
                return .failure(.protectedSystem)
            }
        }
        if let path, protectedPathPrefixes.contains(where: { path.hasPrefix($0) }) {
            return .failure(.protectedSystem)
        }
        // pid 0 / 1 already rejected; never SIGTERM ourselves.
        if pid == getpid() { return .failure(.protectedShannon) }
        return .success(())
    }

    /// Send SIGTERM after policy check. Returns the refusal without signaling.
    @discardableResult
    public static func requestStop(
        pid: Int32,
        name: String? = nil,
        path: String? = nil
    ) -> Result<Void, ProcessStopRefusal> {
        switch canStop(pid: pid, name: name, path: path) {
        case .failure(let reason):
            return .failure(reason)
        case .success:
            #if canImport(Darwin)
            let rc = kill(pid, SIGTERM)
            if rc != 0, errno == ESRCH {
                return .failure(.notRunning)
            }
            if rc != 0, errno == EPERM {
                return .failure(.notSameUser)
            }
            #endif
            return .success(())
        }
    }
}

