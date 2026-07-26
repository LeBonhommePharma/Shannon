import Foundation

// MARK: - Best-effort git branch probe (ENH-013)

/// Fail-closed lookup of the current git branch for a known working directory.
///
/// Used by artifact session readers to fill `AgentSession.branch` when `cwd`
/// is known. Never invents names; never blocks MainActor by itself — callers
/// must invoke from a detached / utility queue (e.g. parity collect).
public enum GitBranchProbe {
    /// Injectable process runner: returns raw stdout (or nil on any failure).
    public typealias Runner = @Sendable (_ cwd: String) -> String?

    /// Default bound for the real `git` process (~0.75s).
    public static let defaultTimeout: TimeInterval = 0.75

    /// Resolve branch for `cwd` using `runner`.
    ///
    /// Returns nil when:
    /// - cwd is nil / empty / whitespace
    /// - path is missing or not a directory
    /// - runner returns nil / empty / whitespace
    /// - name is exactly `"HEAD"` (detached HEAD without a branch name)
    public static func branch(
        for cwd: String?,
        runner: Runner = defaultRunner
    ) -> String? {
        guard let rawCwd = cwd else { return nil }
        let path = rawCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue
        else {
            return nil
        }

        guard let raw = runner(path) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "HEAD" else { return nil }
        return name
    }

    /// Production runner: `git -C cwd rev-parse --abbrev-ref HEAD`.
    ///
    /// Timeout + non-zero exit + empty stdout → nil. No network.
    public static let defaultRunner: Runner = { cwd in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // Avoid inheriting a huge environment; git only needs PATH for helpers.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        proc.environment = env

        do {
            try proc.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(defaultTimeout)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if proc.isRunning {
            proc.terminate()
            // Brief grace so we don't leave a zombie; ignore further hang.
            let killDeadline = Date().addingTimeInterval(0.15)
            while proc.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
