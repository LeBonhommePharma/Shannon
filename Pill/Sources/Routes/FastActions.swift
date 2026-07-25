import Foundation

// MARK: - Fast Actions (user-saved shell commands)

public enum FastActionRunStatus: Sendable, Equatable {
    case idle
    case running
    case succeeded
    case failed(lastLine: String)

    public var label: String {
        switch self {
        case .idle: return "idle"
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
    }
}

public struct FastAction: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var command: String

    public init(id: String = UUID().uuidString, name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}

public struct FastActionResult: Sendable, Equatable {
    public var status: FastActionRunStatus
    public var exitCode: Int32?
    public var stdout: String
    public var stderr: String

    public init(
        status: FastActionRunStatus,
        exitCode: Int32? = nil,
        stdout: String = "",
        stderr: String = ""
    ) {
        self.status = status
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var lastFailureLine: String? {
        if case .failed(let line) = status { return line }
        return nil
    }
}

/// Runs a saved command in a **login shell from `$HOME`**.
///
/// The process launcher is injectable so tests drive status transitions without
/// a real shell. Production uses `/bin/zsh -l -c`.
public struct FastActionRunner: Sendable {
    public typealias ShellRunner = @Sendable (
        _ command: String,
        _ home: String
    ) -> (exitCode: Int32, stdout: String, stderr: String)

    public var shellRunner: ShellRunner
    public var home: String

    public init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        shellRunner: ShellRunner? = nil
    ) {
        self.home = home
        self.shellRunner = shellRunner ?? Self.defaultLoginShellRunner
    }

    public func run(_ action: FastAction) -> FastActionResult {
        let trimmed = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return FastActionResult(
                status: .failed(lastLine: "Empty command"),
                exitCode: 1
            )
        }
        let (code, out, err) = shellRunner(trimmed, home)
        if code == 0 {
            return FastActionResult(status: .succeeded, exitCode: code, stdout: out, stderr: err)
        }
        let last = Self.lastLine(of: err.isEmpty ? out : err)
            ?? "exit \(code)"
        return FastActionResult(
            status: .failed(lastLine: last),
            exitCode: code,
            stdout: out,
            stderr: err
        )
    }

    /// Observable status machine helper (idle → running → terminal).
    public static func transition(
        from: FastActionRunStatus,
        event: FastActionResult
    ) -> FastActionRunStatus {
        switch from {
        case .idle, .succeeded, .failed:
            return event.status
        case .running:
            return event.status
        }
    }

    public static func lastLine(of text: String) -> String? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last.map { String($0) }
    }

    public static let defaultLoginShellRunner: ShellRunner = { command, home in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, out, err)
    }
}

// MARK: - Persistence (UserDefaults-backed, pure codec)

public enum FastActionStore {
    public static let defaultsKey = "shannon.fastActions.v1"

    public static func encode(_ actions: [FastAction]) -> Data {
        let rows = actions.map { ["id": $0.id, "name": $0.name, "command": $0.command] }
        return (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data("[]".utf8)
    }

    public static func decode(_ data: Data) -> [FastAction] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return rows.compactMap { row in
            guard let name = row["name"], let command = row["command"], !name.isEmpty else { return nil }
            return FastAction(id: row["id"] ?? UUID().uuidString, name: name, command: command)
        }
    }
}
