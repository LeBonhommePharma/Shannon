import Foundation
import PillCore
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Open Terminal here (ENH-029 / parity G7)

/// Action decided for "Open Terminal here" — launch a terminal workspace at cwd.
///
/// Distinct from ENH-028 jump-to-host (activate running host / open Finder folder):
/// this **always** wants a terminal shell at the project cwd when evidence exists.
///
/// Fail-closed: never invents a cwd. Missing / non-directory / whitespace → `.none`.
public enum OpenTerminalHereAction: Sendable, Equatable {
    /// Open `cwd` with the given terminal app (bundle id).
    case launch(cwd: String, terminalBundleID: String)
    /// No known existing directory cwd — no-op.
    case none

    public var isAvailable: Bool {
        if case .none = self { return false }
        return true
    }

    /// Short button / menu label for the affordance.
    public var affordanceLabel: String {
        switch self {
        case .launch: return "Open Terminal here"
        case .none: return "Open Terminal unavailable"
        }
    }
}

/// Known evidence for an open-terminal-here decision — only fields the source reported.
public struct OpenTerminalHereInput: Sendable, Equatable {
    /// Project working directory when reported (required for launch).
    public var cwd: String?
    /// Preferred terminal app bundle id when known (⌘D attach / process map).
    public var preferredBundleID: String?
    /// Emulator label from session meta (`"Ghostty"`, `"iTerm"`, …).
    public var preferredTerminalLabel: String?

    public init(
        cwd: String? = nil,
        preferredBundleID: String? = nil,
        preferredTerminalLabel: String? = nil
    ) {
        self.cwd = Self.nonEmpty(cwd)
        self.preferredBundleID = Self.nonEmpty(preferredBundleID)
        self.preferredTerminalLabel = Self.nonEmpty(preferredTerminalLabel)
    }

    /// From a session row — cwd + optional host terminal label only.
    public init(session: AgentSession) {
        self.init(
            cwd: session.cwd,
            preferredBundleID: nil,
            preferredTerminalLabel: session.hostTerminal
        )
    }

    /// Compose from live process-attach + optional session meta.
    public init(attachBundle: String?, session: AgentSession?) {
        self.init(
            cwd: session?.cwd,
            preferredBundleID: attachBundle,
            preferredTerminalLabel: session?.hostTerminal
        )
    }

    /// From a live agent snapshot + optional session row.
    public init(agent: AgentActivitySnapshot, session: AgentSession?) {
        self.init(
            cwd: session?.cwd,
            preferredBundleID: agent.attachBundle,
            preferredTerminalLabel: session?.hostTerminal
        )
    }

    /// True when a real cwd string is present (UI may show the control; decide still checks disk).
    public var hasWorkspaceEvidence: Bool { cwd != nil }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Pure policy: given a known existing directory cwd → launch terminal workspace / no-op.
///
/// Priority (fail-closed on cwd):
/// 1. Existing directory `cwd` required — otherwise `.none`
/// 2. Preferred bundle id when that terminal is installed
/// 3. Emulator label → first installed candidate bundle
/// 4. Default `com.apple.Terminal` when installed
/// 5. Otherwise → `.none`
///
/// Reuses `HostTerminalJumpPolicy.bundleIDs(forHostTerminalLabel:)` for label→bundle
/// mapping so jump and open-here stay consistent.
public enum OpenTerminalHerePolicy: Sendable {

    /// macOS stock Terminal — always the last-resort workspace host.
    public static let defaultTerminalBundleID = "com.apple.Terminal"

    /// Prefer preferred terminal when installed; else label; else Terminal.app.
    public static func decide(
        input: OpenTerminalHereInput,
        cwdExists: @escaping (String) -> Bool = { path in
            HostTerminalJumpPolicy.defaultDirectoryExists(path)
        },
        isTerminalInstalled: @escaping (String) -> Bool = { bid in
            Self.defaultIsTerminalInstalled(bid)
        }
    ) -> OpenTerminalHereAction {
        // 1) Fail-closed: real directory cwd only — never invent paths.
        guard let cwd = input.cwd, cwdExists(cwd) else {
            return .none
        }

        // 2) Explicit preferred bundle when that app is installed.
        if let bid = input.preferredBundleID, isTerminalInstalled(bid) {
            return .launch(cwd: cwd, terminalBundleID: bid)
        }

        // 3) Emulator label → candidate bundles; first *installed* candidate wins.
        if let label = input.preferredTerminalLabel {
            for bid in HostTerminalJumpPolicy.bundleIDs(forHostTerminalLabel: label) {
                if isTerminalInstalled(bid) {
                    return .launch(cwd: cwd, terminalBundleID: bid)
                }
            }
        }

        // 4) Default Terminal.app when present.
        if isTerminalInstalled(defaultTerminalBundleID) {
            return .launch(cwd: cwd, terminalBundleID: defaultTerminalBundleID)
        }

        return .none
    }

    /// Convenience from session only.
    public static func decide(
        session: AgentSession,
        cwdExists: @escaping (String) -> Bool = { path in
            HostTerminalJumpPolicy.defaultDirectoryExists(path)
        },
        isTerminalInstalled: @escaping (String) -> Bool = { bid in
            Self.defaultIsTerminalInstalled(bid)
        }
    ) -> OpenTerminalHereAction {
        decide(
            input: OpenTerminalHereInput(session: session),
            cwdExists: cwdExists,
            isTerminalInstalled: isTerminalInstalled
        )
    }

    /// Convenience from attach + session.
    public static func decide(
        attachBundle: String?,
        session: AgentSession?,
        cwdExists: @escaping (String) -> Bool = { path in
            HostTerminalJumpPolicy.defaultDirectoryExists(path)
        },
        isTerminalInstalled: @escaping (String) -> Bool = { bid in
            Self.defaultIsTerminalInstalled(bid)
        }
    ) -> OpenTerminalHereAction {
        decide(
            input: OpenTerminalHereInput(attachBundle: attachBundle, session: session),
            cwdExists: cwdExists,
            isTerminalInstalled: isTerminalInstalled
        )
    }

    /// Accessibility / help string for the affordance.
    public static func helpText(for action: OpenTerminalHereAction) -> String {
        switch action {
        case .launch(let path, let bid):
            let leaf = (path as NSString).lastPathComponent
            let name = TerminalAgentProbe.emulatorName(bundleID: bid, appName: nil)
                ?? TerminalAgentProbe.emulatorName(bundleID: bid.lowercased(), appName: nil)
                ?? "Terminal"
            if leaf.isEmpty {
                return "Open \(name) here"
            }
            return "Open \(name) in \(leaf)"
        case .none:
            return "Project folder unknown"
        }
    }

    /// Context-menu title when action is available; nil hides the item.
    public static func menuTitle(for action: OpenTerminalHereAction) -> String? {
        action.isAvailable ? action.affordanceLabel : nil
    }

    /// Default install probe — AppKit when available; Terminal.app assumed on non-AppKit.
    public static func defaultIsTerminalInstalled(_ bid: String) -> Bool {
        #if canImport(AppKit)
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil {
            return true
        }
        // Probe table keys are lowercased; stock Terminal is `com.apple.Terminal`.
        if bid.lowercased() == "com.apple.terminal",
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil
        {
            return true
        }
        return false
        #else
        return bid.lowercased() == defaultTerminalBundleID.lowercased()
        #endif
    }
}

// MARK: - Compatibility alias

/// Alias used by board / roster / routes call sites.
public enum OpenTerminalHere {
    public static func resolve(
        cwd: String?,
        preferredBundleID: String? = nil,
        preferredTerminalLabel: String? = nil,
        cwdExists: @escaping (String) -> Bool = { path in
            HostTerminalJumpPolicy.defaultDirectoryExists(path)
        },
        isTerminalInstalled: @escaping (String) -> Bool = { bid in
            OpenTerminalHerePolicy.defaultIsTerminalInstalled(bid)
        }
    ) -> OpenTerminalHereAction {
        OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(
                cwd: cwd,
                preferredBundleID: preferredBundleID,
                preferredTerminalLabel: preferredTerminalLabel
            ),
            cwdExists: cwdExists,
            isTerminalInstalled: isTerminalInstalled
        )
    }

    public static func resolve(
        session: AgentSession,
        cwdExists: @escaping (String) -> Bool = { path in
            HostTerminalJumpPolicy.defaultDirectoryExists(path)
        },
        isTerminalInstalled: @escaping (String) -> Bool = { bid in
            OpenTerminalHerePolicy.defaultIsTerminalInstalled(bid)
        }
    ) -> OpenTerminalHereAction {
        OpenTerminalHerePolicy.decide(
            session: session,
            cwdExists: cwdExists,
            isTerminalInstalled: isTerminalInstalled
        )
    }

    public static func menuTitle(for action: OpenTerminalHereAction) -> String? {
        OpenTerminalHerePolicy.menuTitle(for: action)
    }
}

#if canImport(AppKit)
/// Performs an open-terminal-here decision via `NSWorkspace`.
///
/// Pure policy stays in `OpenTerminalHerePolicy`; this is the AppKit side effect.
/// Opens the directory with the chosen terminal app so a new workspace shell
/// starts at that cwd (Terminal / iTerm / Ghostty / Warp when installed).
public enum OpenTerminalHereExecutor {
    /// Decide with live install checks + default filesystem, then perform.
    @discardableResult
    public static func open(
        input: OpenTerminalHereInput,
        cwdExists: @escaping (String) -> Bool = { path in
            HostTerminalJumpPolicy.defaultDirectoryExists(path)
        }
    ) -> OpenTerminalHereAction {
        let action = OpenTerminalHerePolicy.decide(
            input: input,
            cwdExists: cwdExists
        )
        _ = perform(action)
        return action
    }

    /// Launch terminal at cwd. Returns whether the side effect ran.
    @discardableResult
    public static func perform(_ action: OpenTerminalHereAction) -> Bool {
        switch action {
        case .launch(let path, let bid):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  isDir.boolValue
            else {
                return false
            }
            let dirURL = URL(fileURLWithPath: path, isDirectory: true)
            let resolvedBid = resolveInstalledBundleID(bid)
                ?? resolveInstalledBundleID(OpenTerminalHerePolicy.defaultTerminalBundleID)
            guard let appURL = resolvedBid.flatMap({
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }) else {
                return false
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(
                [dirURL],
                withApplicationAt: appURL,
                configuration: config,
                completionHandler: nil
            )
            return true
        case .none:
            return false
        }
    }

    /// Prefer the exact bundle id; fall back to case-insensitive scan of known terminals.
    private static func resolveInstalledBundleID(_ bid: String) -> String? {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil {
            return bid
        }
        let lower = bid.lowercased()
        if lower == "com.apple.terminal",
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil
        {
            return "com.apple.Terminal"
        }
        for known in TerminalAgentProbe.terminalBundleNames.keys {
            if known.lowercased() == lower,
               NSWorkspace.shared.urlForApplication(withBundleIdentifier: known) != nil
            {
                return known
            }
        }
        return nil
    }
}

/// Alias for board/roster call sites.
public enum OpenTerminalHerePerformer {
    @discardableResult
    public static func perform(_ action: OpenTerminalHereAction) -> Bool {
        OpenTerminalHereExecutor.perform(action)
    }
}
#endif
