import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Jump-to-host-terminal (ENH-028 / parity G3)

/// Action decided for "jump to host terminal".
///
/// Fail-closed: never invents host process or cwd. When evidence is missing
/// or the host is not running and cwd is absent/missing on disk → `.none`.
public enum HostTerminalJumpAction: Sendable, Equatable {
    /// Activate a known running host app by bundle id.
    case activateApp(bundleID: String)
    /// Activate the process that owns a live attach pid (⌘D host/CLI).
    case activatePid(pid: Int32)
    /// Open an existing project cwd (Finder / default folder handler).
    case openCwd(path: String)
    /// No known running host and no existing cwd — no-op.
    case none

    public var isAvailable: Bool {
        if case .none = self { return false }
        return true
    }

    /// Short button / menu label for the affordance.
    public var affordanceLabel: String {
        switch self {
        case .activateApp, .activatePid: return "Jump to terminal"
        case .openCwd: return "Open project folder"
        case .none: return "Jump unavailable"
        }
    }
}

/// Known evidence for a jump decision — only fields the source reported.
public struct HostTerminalJumpInput: Sendable, Equatable {
    /// Host app bundle id (⌘D attach / process map).
    public var hostBundleID: String?
    /// Host/CLI process id from ⌘D attach (0 / nil = unknown).
    public var attachPid: Int32?
    /// Emulator label from session meta (`"Ghostty"`, `"iTerm"`, …).
    public var hostTerminalLabel: String?
    /// Project working directory when reported.
    public var cwd: String?

    public init(
        hostBundleID: String? = nil,
        attachPid: Int32? = nil,
        hostTerminalLabel: String? = nil,
        cwd: String? = nil
    ) {
        self.hostBundleID = Self.nonEmpty(hostBundleID)
        self.attachPid = (attachPid ?? 0) > 0 ? attachPid : nil
        self.hostTerminalLabel = Self.nonEmpty(hostTerminalLabel)
        self.cwd = Self.nonEmpty(cwd)
    }

    /// Compose from live process-attach + optional session meta (both optional).
    public init(attachBundle: String?, attachPid: Int32? = nil, session: AgentSession?) {
        self.init(
            hostBundleID: attachBundle,
            attachPid: attachPid,
            hostTerminalLabel: session?.hostTerminal,
            cwd: session?.cwd
        )
    }

    /// From a live agent snapshot + optional session row.
    public init(agent: AgentActivitySnapshot, session: AgentSession?) {
        self.init(
            hostBundleID: agent.attachBundle,
            attachPid: agent.attachPid,
            hostTerminalLabel: session?.hostTerminal,
            cwd: session?.cwd
        )
    }

    /// True when any real signal is present (UI may show a jump control).
    public var hasJumpEvidence: Bool {
        hostBundleID != nil || attachPid != nil || hostTerminalLabel != nil || cwd != nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Pure policy: given known host process and/or cwd → activate / open / no-op.
///
/// Priority (fail-closed):
/// 1. Running `attachBundle` / host bundle id → activate app
/// 2. Emulator label resolves to a running terminal bundle → activate app
/// 3. Live `attachPid` → activate that process
/// 4. Existing directory `cwd` → open folder
/// 5. Otherwise → `.none`
public enum HostTerminalJumpPolicy: Sendable {

    /// Prefer activating a known **running** host; else open an **existing** cwd.
    public static func decide(
        input: HostTerminalJumpInput,
        runningBundleIDs: Set<String>,
        cwdExists: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && isDir.boolValue
        },
        pidAlive: (Int32) -> Bool = ProcessAttach.isProcessAlive
    ) -> HostTerminalJumpAction {
        let running = Set(runningBundleIDs.map { $0.lowercased() })

        // 1) Explicit host bundle id when that app is still running.
        if let bid = input.hostBundleID {
            if running.contains(bid.lowercased()) {
                return .activateApp(bundleID: bid)
            }
        }

        // 2) Emulator label → candidate bundles; first *running* candidate wins.
        if let label = input.hostTerminalLabel {
            for bid in bundleIDs(forHostTerminalLabel: label) {
                if running.contains(bid.lowercased()) {
                    return .activateApp(bundleID: bid)
                }
            }
        }

        // 3) Live attach pid — activate the process (host terminal or CLI host).
        if let pid = input.attachPid, pidAlive(pid) {
            return .activatePid(pid: pid)
        }

        // 4) Fallback: open cwd only when it exists as a directory (fail-closed).
        if let cwd = input.cwd, cwdExists(cwd) {
            return .openCwd(path: cwd)
        }

        return .none
    }

    /// Convenience: attach bundle + session meta.
    public static func decide(
        attachBundle: String?,
        attachPid: Int32? = nil,
        session: AgentSession?,
        runningBundleIDs: Set<String>,
        cwdExists: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && isDir.boolValue
        },
        pidAlive: (Int32) -> Bool = ProcessAttach.isProcessAlive
    ) -> HostTerminalJumpAction {
        decide(
            input: HostTerminalJumpInput(
                attachBundle: attachBundle,
                attachPid: attachPid,
                session: session
            ),
            runningBundleIDs: runningBundleIDs,
            cwdExists: cwdExists,
            pidAlive: pidAlive
        )
    }

    /// Convenience from agent row + session.
    public static func decide(
        agent: AgentActivitySnapshot,
        session: AgentSession?,
        runningBundleIDs: Set<String>,
        cwdExists: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && isDir.boolValue
        },
        pidAlive: (Int32) -> Bool = ProcessAttach.isProcessAlive
    ) -> HostTerminalJumpAction {
        decide(
            input: HostTerminalJumpInput(agent: agent, session: session),
            runningBundleIDs: runningBundleIDs,
            cwdExists: cwdExists,
            pidAlive: pidAlive
        )
    }

    /// Candidate bundle IDs for an emulator display label via `TerminalAgentProbe`.
    ///
    /// Accepts exact labels (`"Ghostty"`) and prefixed forms (`"Ghostty · claude"`).
    /// Returns a stable sorted list; empty when the label is unknown — never invents.
    public static func bundleIDs(forHostTerminalLabel label: String) -> [String] {
        let raw = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let needle = raw.lowercased()

        var matches: [String] = []
        for (bid, name) in TerminalAgentProbe.terminalBundleNames {
            let n = name.lowercased()
            // Exact / leading-token only — avoid bare substring so
            // "NotATerminal".contains("terminal") never invents a host.
            let isExact = needle == n
            let isLeadingToken =
                needle.hasPrefix(n + " ")
                || needle.hasPrefix(n + "·")
                || needle.hasPrefix(n + " ·")
                || needle.hasPrefix(n + "-")
            let isWholeWord: Bool = {
                guard needle.contains(n) else { return false }
                let tokens = needle.split { !$0.isLetter && !$0.isNumber }.map(String.init)
                return tokens.contains(n)
            }()
            if isExact || isLeadingToken || isWholeWord {
                matches.append(bid)
            }
        }
        return matches.sorted()
    }

    /// Default fail-closed path check: must exist **and** be a directory.
    public static func defaultDirectoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    /// Accessibility / help string for the affordance.
    public static func helpText(for action: HostTerminalJumpAction) -> String {
        switch action {
        case .activateApp(let bid):
            let name = TerminalAgentProbe.emulatorName(bundleID: bid, appName: nil) ?? bid
            return "Activate \(name)"
        case .activatePid(let pid):
            return "Activate host process \(pid)"
        case .openCwd(let path):
            let leaf = (path as NSString).lastPathComponent
            return leaf.isEmpty ? "Open project folder" : "Open \(leaf)"
        case .none:
            return "Host terminal and project folder unknown"
        }
    }

    /// Context-menu title when action is available; nil hides the item.
    public static func menuTitle(for action: HostTerminalJumpAction) -> String? {
        action.isAvailable ? action.affordanceLabel : nil
    }
}

// MARK: - Compatibility aliases (call sites / tests)

/// Alias used by board / roster context menus.
public enum HostTerminalJump {
    public static func resolve(
        attachBundle: String?,
        attachPid: Int32? = nil,
        cwd: String? = nil,
        hostTerminalLabel: String? = nil,
        runningBundleIDs: Set<String>,
        cwdExists: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && isDir.boolValue
        },
        pidAlive: (Int32) -> Bool = ProcessAttach.isProcessAlive
    ) -> HostTerminalJumpAction {
        HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(
                hostBundleID: attachBundle,
                attachPid: attachPid,
                hostTerminalLabel: hostTerminalLabel,
                cwd: cwd
            ),
            runningBundleIDs: runningBundleIDs,
            cwdExists: cwdExists,
            pidAlive: pidAlive
        )
    }

    public static func resolve(
        agent: AgentActivitySnapshot,
        session: AgentSession?,
        runningBundleIDs: Set<String>,
        cwdExists: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && isDir.boolValue
        },
        pidAlive: (Int32) -> Bool = ProcessAttach.isProcessAlive
    ) -> HostTerminalJumpAction {
        HostTerminalJumpPolicy.decide(
            agent: agent,
            session: session,
            runningBundleIDs: runningBundleIDs,
            cwdExists: cwdExists,
            pidAlive: pidAlive
        )
    }

    public static func menuTitle(for action: HostTerminalJumpAction) -> String? {
        HostTerminalJumpPolicy.menuTitle(for: action)
    }
}

#if canImport(AppKit)
/// Performs a jump decision via `NSRunningApplication` / `NSWorkspace`.
///
/// Pure policy stays in `HostTerminalJumpPolicy`; this is the AppKit side effect.
public enum HostTerminalJumpExecutor {
    /// Snapshot of lowercased running bundle ids for policy input.
    public static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap {
            $0.bundleIdentifier?.lowercased()
        })
    }

    /// Activate host app / pid or open cwd. Returns whether the side effect ran.
    @discardableResult
    public static func perform(_ action: HostTerminalJumpAction) -> Bool {
        switch action {
        case .activateApp(let bid):
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            let app = apps.first(where: \.isActive) ?? apps.first
            guard let app else { return false }
            return app.activate(options: [.activateIgnoringOtherApps])
        case .activatePid(let pid):
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                return false
            }
            return app.activate(options: [.activateIgnoringOtherApps])
        case .openCwd(let path):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                return false
            }
            return NSWorkspace.shared.open(
                URL(fileURLWithPath: path, isDirectory: isDir.boolValue)
            )
        case .none:
            return false
        }
    }

    /// Decide with live running apps + default filesystem, then perform.
    @discardableResult
    public static func jump(
        input: HostTerminalJumpInput,
        cwdExists: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && isDir.boolValue
        }
    ) -> HostTerminalJumpAction {
        let action = HostTerminalJumpPolicy.decide(
            input: input,
            runningBundleIDs: runningBundleIDs(),
            cwdExists: cwdExists
        )
        _ = perform(action)
        return action
    }
}

/// Alias for board/roster call sites that import `HostTerminalJumpPerformer`.
public enum HostTerminalJumpPerformer {
    @discardableResult
    public static func perform(_ action: HostTerminalJumpAction) -> Bool {
        HostTerminalJumpExecutor.perform(action)
    }
}
#endif
