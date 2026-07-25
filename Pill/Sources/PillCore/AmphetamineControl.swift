import Foundation

// MARK: - Session state

/// Snapshot of Amphetamine keep-awake session (Amphetamine.app AppleScript suite).
///
/// Pure value — no I/O. Built from script results or fail-closed when the app
/// is missing / Automation is denied.
public struct AmphetamineSession: Sendable, Equatable {
    public var isActive: Bool
    /// Seconds remaining when finite; `nil` when inactive or infinite.
    public var secondsRemaining: Int?
    /// True when session has no timed end (Amphetamine “indefinite”).
    public var isIndefinite: Bool
    /// Whether display sleep is allowed while the session runs.
    public var displaySleepAllowed: Bool
    /// App missing, scripting failed, or not yet queried.
    public var availability: Availability

    public enum Availability: String, Sendable, Equatable {
        case available
        case notInstalled
        case scriptFailed
        case unknown
    }

    public init(
        isActive: Bool = false,
        secondsRemaining: Int? = nil,
        isIndefinite: Bool = false,
        displaySleepAllowed: Bool = true,
        availability: Availability = .unknown
    ) {
        self.isActive = isActive
        self.secondsRemaining = secondsRemaining
        self.isIndefinite = isIndefinite
        self.displaySleepAllowed = displaySleepAllowed
        self.availability = availability
    }

    /// Compact menu / popover label.
    public var shortLabel: String {
        switch availability {
        case .notInstalled: return "Amphetamine: not installed"
        case .scriptFailed: return "Amphetamine: unavailable"
        case .unknown: return "Amphetamine: …"
        case .available:
            if !isActive { return "Amphetamine: off" }
            if isIndefinite { return "Amphetamine: ∞" }
            if let s = secondsRemaining {
                return "Amphetamine: \(Self.formatDuration(s))"
            }
            return "Amphetamine: on"
        }
    }

    public static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            let h = s / 3600
            let m = (s % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        if s >= 60 {
            let m = s / 60
            let r = s % 60
            return r > 0 ? "\(m)m \(r)s" : "\(m)m"
        }
        return "\(s)s"
    }
}

/// Options for starting a new Amphetamine session.
public struct AmphetamineStartOptions: Sendable, Equatable {
    /// Duration value in `interval` units. `nil` = indefinite session.
    public var duration: Int?
    public enum Interval: String, Sendable, Equatable {
        case minutes
        case hours
    }
    public var interval: Interval
    public var displaySleepAllowed: Bool

    public init(
        duration: Int? = 60,
        interval: Interval = .minutes,
        displaySleepAllowed: Bool = false
    ) {
        self.duration = duration
        self.interval = interval
        self.displaySleepAllowed = displaySleepAllowed
    }

    /// Default: 2 hours, display may not sleep — useful for long agent runs.
    public static let agentBusyDefault = AmphetamineStartOptions(
        duration: 2,
        interval: .hours,
        displaySleepAllowed: false
    )
}

// MARK: - Pure AppleScript plan + parse (unit-tested)

/// Builds / parses Amphetamine AppleScript. UI and Process runner stay thin.
public enum AmphetamineScript {
    public static let appName = "Amphetamine"
    public static let defaultAppPath = "/Applications/Amphetamine.app"

    /// Query script: session active, time remaining, display sleep allowed.
    /// Commands match Amphetamine.sdef (`session is active`, `session time remaining`,
    /// `display sleep allowed`) — not English-property paraphrases.
    public static func statusQueryScript() -> String {
        """
        tell application "\(appName)"
          set a to session is active
          set t to session time remaining
          set d to display sleep allowed
          return (a as text) & "|" & (t as text) & "|" & (d as text)
        end tell
        """
    }

    /// End current session.
    public static func endSessionScript() -> String {
        """
        tell application "\(appName)"
          end session
        end tell
        """
    }

    /// Start a new session (optional timed duration + display-sleep flag).
    ///
    /// Amphetamine options record: `{duration:integer, interval:hours|minutes,
    /// displaySleepAllowed:true|false}`. Duration 0 + interval 0 = infinite.
    public static func startSessionScript(options: AmphetamineStartOptions) -> String {
        if let dur = options.duration, dur > 0 {
            let unit = options.interval.rawValue
            let disp = options.displaySleepAllowed ? "true" : "false"
            return """
            tell application "\(appName)"
              start new session with options {duration:\(dur), interval:\(unit), displaySleepAllowed:\(disp)}
            end tell
            """
        }
        // Indefinite: duration 0, interval 0 per Amphetamine.sdef.
        let disp = options.displaySleepAllowed ? "true" : "false"
        return """
        tell application "\(appName)"
          start new session with options {duration:0, interval:0, displaySleepAllowed:\(disp)}
        end tell
        """
    }

    /// Parse status script stdout. Fail-closed on garbage.
    ///
    /// Amphetamine `session time remaining` codes (sdef):
    /// - `> 0` — seconds left
    /// - `0` — infinite duration session
    /// - `-1` — Trigger-based
    /// - `-2` — app-based or date-based
    /// - `-3` — no active session
    public static func parseStatusOutput(_ raw: String) -> AmphetamineSession? {
        let line = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard parts.count >= 2 else { return nil }

        let active: Bool = {
            switch parts[0] {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return false
            }
        }()

        let tRaw = parts[1]
        let tVal = Int(tRaw)
        var seconds: Int?
        var indefinite = false
        if let t = tVal {
            switch t {
            case ...(-3):
                // -3 no session; treat as inactive remaining
                seconds = nil
                indefinite = false
            case -2, -1:
                // Trigger / app / date based — active but not a simple countdown
                indefinite = active
                seconds = nil
            case 0:
                // Infinite duration when active
                indefinite = active
                seconds = nil
            default:
                seconds = t
                indefinite = false
            }
        } else if tRaw.contains("inf") || tRaw == "∞" {
            indefinite = active
        }

        let displaySleep: Bool = {
            guard parts.count >= 3 else { return true }
            switch parts[2] {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return true
            }
        }()

        return AmphetamineSession(
            isActive: active,
            secondsRemaining: seconds,
            isIndefinite: indefinite,
            displaySleepAllowed: displaySleep,
            availability: .available
        )
    }

    /// Whether to auto-start keep-awake when agents become busy.
    public static func shouldAutoStartForAgents(
        agentsBusy: Bool,
        sessionActive: Bool,
        autoKeepAwakeEnabled: Bool
    ) -> Bool {
        autoKeepAwakeEnabled && agentsBusy && !sessionActive
    }

    /// Whether to suggest ending keep-awake when all agents go idle.
    public static func shouldAutoEndForAgents(
        agentsBusy: Bool,
        sessionActive: Bool,
        autoKeepAwakeEnabled: Bool
    ) -> Bool {
        autoKeepAwakeEnabled && !agentsBusy && sessionActive
    }
}

// MARK: - Live runner

/// Runs Amphetamine AppleScript via `/usr/bin/osascript`. Fail-closed.
public enum AmphetamineRunner {
    public static func isInstalled(
        path: String = AmphetamineScript.defaultAppPath,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func runScript(_ source: String, timeout: TimeInterval = 4.0) -> Result<String, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return .failure(error)
        }
        // Bounded wait — never hang the UI if osascript wedges.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .failure(NSError(
                domain: "AmphetamineRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "osascript timed out"]
            ))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(NSError(
                domain: "AmphetamineRunner",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: e.isEmpty ? "script failed" : e]
            ))
        }
        return .success(text)
    }

    public static func querySession() -> AmphetamineSession {
        guard isInstalled() else {
            return AmphetamineSession(availability: .notInstalled)
        }
        switch runScript(AmphetamineScript.statusQueryScript()) {
        case .success(let out):
            return AmphetamineScript.parseStatusOutput(out)
                ?? AmphetamineSession(availability: .scriptFailed)
        case .failure:
            return AmphetamineSession(availability: .scriptFailed)
        }
    }

    @discardableResult
    public static func startSession(_ options: AmphetamineStartOptions = .agentBusyDefault) -> Bool {
        guard isInstalled() else { return false }
        return runScript(AmphetamineScript.startSessionScript(options: options)).isSuccess
    }

    @discardableResult
    public static func endSession() -> Bool {
        guard isInstalled() else { return false }
        return runScript(AmphetamineScript.endSessionScript()).isSuccess
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Monitor

/// Polls Amphetamine and optionally keeps the Mac awake while agents are busy.
@MainActor
public final class AmphetamineMonitor: ObservableObject {
    @Published public private(set) var session = AmphetamineSession()
    /// When true, busy agents auto-start a keep-awake session; idle ends it.
    @Published public var autoKeepAwakeWithAgents: Bool = true

    private var timer: Timer?
    private let interval: TimeInterval
    private var lastBusy: Bool = false

    public init(interval: TimeInterval = 5.0) {
        self.interval = max(2.0, interval)
    }

    public func start() {
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = interval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        Task.detached(priority: .utility) {
            let snap = AmphetamineRunner.querySession()
            await MainActor.run { [weak self] in
                self?.session = snap
            }
        }
    }

    /// Call when agent busy-ness changes (from activity summary).
    public func syncWithAgents(busyCount: Int) {
        let busy = busyCount > 0
        defer { lastBusy = busy }
        guard autoKeepAwakeWithAgents else { return }
        guard session.availability == .available || session.availability == .unknown else { return }

        if AmphetamineScript.shouldAutoStartForAgents(
            agentsBusy: busy,
            sessionActive: session.isActive,
            autoKeepAwakeEnabled: autoKeepAwakeWithAgents
        ) {
            Task.detached(priority: .utility) {
                _ = AmphetamineRunner.startSession(.agentBusyDefault)
                let snap = AmphetamineRunner.querySession()
                await MainActor.run { [weak self] in self?.session = snap }
            }
        } else if AmphetamineScript.shouldAutoEndForAgents(
            agentsBusy: busy,
            sessionActive: session.isActive,
            autoKeepAwakeEnabled: autoKeepAwakeWithAgents
        ), lastBusy, !busy {
            // Only auto-end if we transitioned busy→idle (not on first poll).
            Task.detached(priority: .utility) {
                _ = AmphetamineRunner.endSession()
                let snap = AmphetamineRunner.querySession()
                await MainActor.run { [weak self] in self?.session = snap }
            }
        }
    }

    public func startSession(_ options: AmphetamineStartOptions = .agentBusyDefault) {
        Task.detached(priority: .utility) {
            _ = AmphetamineRunner.startSession(options)
            let snap = AmphetamineRunner.querySession()
            await MainActor.run { [weak self] in self?.session = snap }
        }
    }

    public func endSession() {
        Task.detached(priority: .utility) {
            _ = AmphetamineRunner.endSession()
            let snap = AmphetamineRunner.querySession()
            await MainActor.run { [weak self] in self?.session = snap }
        }
    }
}
