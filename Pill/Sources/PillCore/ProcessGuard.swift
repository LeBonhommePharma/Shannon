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
