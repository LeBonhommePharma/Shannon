import Foundation
import PillCore

// MARK: - Dev server discovery (ports 3000–9999)

/// One listening process in the common local-dev port range.
public struct DevServer: Sendable, Equatable, Identifiable {
    public var id: String { "\(port)-\(pid)" }
    public var port: Int
    public var pid: Int32
    public var project: String?
    public var cwd: String?
    public var framework: String?
    public var runtime: String?
    public var commandLine: String?

    public init(
        port: Int,
        pid: Int32,
        project: String? = nil,
        cwd: String? = nil,
        framework: String? = nil,
        runtime: String? = nil,
        commandLine: String? = nil
    ) {
        self.port = port
        self.pid = pid
        self.project = project
        self.cwd = cwd
        self.framework = framework
        self.runtime = runtime
        self.commandLine = commandLine
    }

    public var url: String { "http://127.0.0.1:\(port)" }

    public var label: String {
        if let framework, !framework.isEmpty { return framework }
        if let runtime, !runtime.isEmpty { return runtime }
        return "port \(port)"
    }

    public var detailLine: String {
        let proj = project ?? (cwd as NSString?)?.lastPathComponent
        if let proj, !proj.isEmpty {
            return ":\(port) · \(label) · \(proj)"
        }
        return ":\(port) · \(label)"
    }
}

/// Raw listener evidence — discovery can be fed from libproc, `lsof`, or tests.
public struct DevServerListener: Sendable, Equatable {
    public var port: Int
    public var pid: Int32
    public var commandLine: String
    public var cwd: String?

    public init(port: Int, pid: Int32, commandLine: String = "", cwd: String? = nil) {
        self.port = port
        self.pid = pid
        self.commandLine = commandLine
        self.cwd = cwd
    }
}

public enum DevServerPolicy {
    public static let minPort = 3000
    public static let maxPort = 9999

    public static func isInRange(_ port: Int) -> Bool {
        port >= minPort && port <= maxPort
    }

    /// Framework / runtime labels from argv + cwd. Pure.
    public static func classify(
        commandLine: String,
        cwd: String? = nil
    ) -> (framework: String?, runtime: String?) {
        let blob = (commandLine + " " + (cwd ?? "")).lowercased()
        var framework: String?
        if blob.contains("next") || blob.contains("next-server") { framework = "Next.js" }
        else if blob.contains("vite") { framework = "Vite" }
        else if blob.contains("astro") { framework = "Astro" }
        else if blob.contains("wrangler") { framework = "Wrangler" }
        else if blob.contains("storybook") { framework = "Storybook" }
        else if blob.contains("playwright") { framework = "Playwright" }
        else if blob.contains("webpack-dev-server") || blob.contains("webpack") { framework = "Webpack" }
        else if blob.contains("http.server") || blob.contains("python -m http") { framework = "static" }

        var runtime: String?
        if blob.contains("node") || blob.contains("nodejs") { runtime = "Node" }
        else if blob.contains("bun") { runtime = "Bun" }
        else if blob.contains("deno") { runtime = "Deno" }
        else if blob.contains("python") || blob.contains("uvicorn") || blob.contains("gunicorn") {
            runtime = "Python"
        } else if blob.contains("ruby") || blob.contains("rails") || blob.contains("puma") {
            runtime = "Ruby"
        } else if blob.contains("cargo") || blob.contains("target/debug") { runtime = "Rust" }
        else if blob.contains("go run") || blob.contains("/go ") || blob.hasPrefix("go ") {
            runtime = "Go"
        }

        return (framework, runtime)
    }

    public static func projectName(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

public enum DevServerDiscovery {
    /// Build server rows from listener fixtures / live enumeration.
    public static func fromListeners(_ listeners: [DevServerListener]) -> [DevServer] {
        var byPort: [Int: DevServer] = [:]
        for listener in listeners where DevServerPolicy.isInRange(listener.port) {
            let classed = DevServerPolicy.classify(
                commandLine: listener.commandLine,
                cwd: listener.cwd
            )
            let server = DevServer(
                port: listener.port,
                pid: listener.pid,
                project: DevServerPolicy.projectName(cwd: listener.cwd),
                cwd: listener.cwd,
                framework: classed.framework,
                runtime: classed.runtime,
                commandLine: listener.commandLine.isEmpty ? nil : listener.commandLine
            )
            // Prefer lower pid when two claim the same port (stable).
            if let existing = byPort[listener.port] {
                if listener.pid < existing.pid {
                    byPort[listener.port] = server
                }
            } else {
                byPort[listener.port] = server
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    /// Live discovery via `lsof` (best-effort). Empty on failure — never invents.
    public static func discoverLive() -> [DevServer] {
        let listeners = enumerateViaLsof()
        return fromListeners(listeners)
    }

    /// Open in default browser / copy helpers (pure URL strings).
    public static func openURL(for server: DevServer) -> URL? {
        URL(string: server.url)
    }

    /// Identity passed into `ProcessKillSafety` for a discovered server.
    ///
    /// Live `lsof` rows typically only set `commandLine` (the COMMAND column).
    /// That string must be the primary name — not only `runtime`/`framework` —
    /// so protected processes are still refused when labels are missing or wrong.
    public static func stopIdentity(
        for server: DevServer,
        name: String? = nil,
        path: String? = nil
    ) -> (name: String?, path: String?) {
        let resolvedName = name
            ?? server.commandLine
            ?? server.runtime
            ?? server.framework
        let resolvedPath = path ?? server.commandLine
        return (resolvedName, resolvedPath)
    }

    /// Stop after ProcessKillSafety check.
    public static func stop(
        _ server: DevServer,
        name: String? = nil,
        path: String? = nil
    ) -> Result<Void, ProcessStopRefusal> {
        let id = stopIdentity(for: server, name: name, path: path)
        return ProcessKillSafety.requestStop(
            pid: server.pid,
            name: id.name,
            path: id.path
        )
    }

    // MARK: - lsof (macOS)

    private static func enumerateViaLsof() -> [DevServerListener] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -nP: no DNS / port name resolution; -iTCP -sTCP:LISTEN
        proc.arguments = ["-nP", "-iTCP:\(DevServerPolicy.minPort)-\(DevServerPolicy.maxPort)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
        return parseLsof(text)
    }

    /// Parse `lsof -nP` LISTEN lines. Exposed for tests.
    public static func parseLsof(_ text: String) -> [DevServerListener] {
        var out: [DevServerListener] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
            // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [(LISTEN)]
            guard cols.count >= 9 else { continue }
            if cols[0] == "COMMAND" { continue }
            guard let pid = Int32(cols[1]) else { continue }
            // NAME may be followed by "(LISTEN)" as its own token.
            guard let port = cols.compactMap(parsePort(from:)).first,
                  DevServerPolicy.isInRange(port) else { continue }
            out.append(DevServerListener(port: port, pid: pid, commandLine: cols[0], cwd: nil))
        }
        return out
    }

    private static func parsePort(from name: String) -> Int? {
        // *:3000, 127.0.0.1:5173, [::1]:8080 — not bare "(LISTEN)"
        guard name.contains(":"), !name.hasPrefix("(") else { return nil }
        if let idx = name.lastIndex(of: ":") {
            let portStr = name[name.index(after: idx)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            return Int(portStr)
        }
        return nil
    }
}
