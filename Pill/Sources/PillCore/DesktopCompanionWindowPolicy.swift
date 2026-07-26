// DesktopCompanionWindowPolicy.swift — always-on-top panel policy (pure values).
//
// Keeps level / collection-behavior / reassert contracts out of AppKit call
// sites so unit tests can assert the desktop pet stays above normal windows
// without needing a live window server. The ShannonPill controller applies
// these constants when building the NSPanel.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Always-on-top configuration for the floating desktop companion (pet + bubble).
///
/// Distinct from the notch `PillPanel`: raising the pet must not expand the
/// notch board. Same *class* of level (status-window family) so the pet stays
/// visible over ordinary app windows and across Spaces.
public enum DesktopCompanionWindowPolicy: Sendable {

    // MARK: - Level

    /// Offset above `CGWindowLevelKey.statusWindow`.
    /// Matches the notch pill (`statusWindow + 2`) so the pet stays in the
    /// same stacking band as Shannon chrome without fighting Keynote presenter.
    public static let levelOffsetAboveStatusWindow: Int = 2

    /// Raw window level integer (status-window class or above).
    ///
    /// When AppKit is available this is the real CG level; tests can also
    /// assert the offset constant without constructing a panel.
    public static var windowLevelRawValue: Int {
        #if canImport(AppKit)
        return Int(CGWindowLevelForKey(.statusWindow)) + levelOffsetAboveStatusWindow
        #else
        // Documented status-window baseline on macOS is 25; +2 = 27.
        return 25 + levelOffsetAboveStatusWindow
        #endif
    }

    /// True when `level` is at least status-window class (not normal / floating only).
    public static func isAlwaysOnTopLevel(_ rawValue: Int) -> Bool {
        #if canImport(AppKit)
        let status = Int(CGWindowLevelForKey(.statusWindow))
        return rawValue >= status
        #else
        return rawValue >= 25
        #endif
    }

    // MARK: - Activation / visibility

    /// Panel must not steal key focus from the user's editor.
    public static let canBecomeKey: Bool = false
    public static let canBecomeMain: Bool = false
    /// Non-activating panel style so clicks do not activate Shannon as a full app.
    public static let usesNonactivatingPanelStyle: Bool = true
    /// Switching apps must not hide the companion.
    public static let hidesOnDeactivate: Bool = false
    /// Keep the panel process-owned after close for re-show.
    public static let isReleasedWhenClosed: Bool = false
    /// Movable by the user (drag the pet around the desktop).
    public static let isMovable: Bool = true
    public static let isMovableByWindowBackground: Bool = true

    // MARK: - Spaces / fullscreen

    /// Join every Space so Mission Control desktop switches keep the pet.
    public static let joinsAllSpaces: Bool = true
    /// Stay put when Spaces rearrange.
    public static let stationary: Bool = true
    /// Visible as an auxiliary window over full-screen apps when possible.
    public static let fullScreenAuxiliary: Bool = true
    /// Skip Cmd-` window cycle (accessory chrome).
    public static let ignoresCycle: Bool = true

    #if canImport(AppKit)
    /// Collection behavior bitset applied to the desktop companion panel.
    public static var collectionBehavior: NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = []
        if joinsAllSpaces { behavior.insert(.canJoinAllSpaces) }
        if stationary { behavior.insert(.stationary) }
        if fullScreenAuxiliary { behavior.insert(.fullScreenAuxiliary) }
        if ignoresCycle { behavior.insert(.ignoresCycle) }
        return behavior
    }

    /// Style mask for the floating pet panel.
    public static var styleMask: NSWindow.StyleMask {
        usesNonactivatingPanelStyle
            ? [.borderless, .nonactivatingPanel]
            : [.borderless]
    }
    #endif

    // MARK: - Reassert

    /// Re-order after Mission Control / active Space changes.
    public static let reassertOnActiveSpaceChange: Bool = true
    /// Reposition after display plug / resolution change.
    public static let reassertOnScreenParametersChange: Bool = true
    /// Brief reassert burst after show (seconds between ticks, tick count).
    public static let launchReassertInterval: TimeInterval = 1.0
    public static let launchReassertTickCount: Int = 6

    /// Pure checklist of policy facts tests and launch diagnostics can dump.
    public static var policySnapshot: [String: String] {
        [
            "levelOffsetAboveStatusWindow": "\(levelOffsetAboveStatusWindow)",
            "windowLevelRawValue": "\(windowLevelRawValue)",
            "canBecomeKey": "\(canBecomeKey)",
            "canBecomeMain": "\(canBecomeMain)",
            "usesNonactivatingPanelStyle": "\(usesNonactivatingPanelStyle)",
            "hidesOnDeactivate": "\(hidesOnDeactivate)",
            "joinsAllSpaces": "\(joinsAllSpaces)",
            "stationary": "\(stationary)",
            "fullScreenAuxiliary": "\(fullScreenAuxiliary)",
            "ignoresCycle": "\(ignoresCycle)",
            "reassertOnActiveSpaceChange": "\(reassertOnActiveSpaceChange)",
            "reassertOnScreenParametersChange": "\(reassertOnScreenParametersChange)",
            "isAlwaysOnTopLevel": "\(isAlwaysOnTopLevel(windowLevelRawValue))",
        ]
    }

    /// True when a configured panel matches always-on-top contracts.
    public static func matchesAlwaysOnTop(
        levelRawValue: Int,
        hidesOnDeactivate: Bool,
        canBecomeKey: Bool,
        joinsAllSpaces: Bool
    ) -> Bool {
        isAlwaysOnTopLevel(levelRawValue)
            && hidesOnDeactivate == Self.hidesOnDeactivate
            && canBecomeKey == Self.canBecomeKey
            && joinsAllSpaces == Self.joinsAllSpaces
    }
}
