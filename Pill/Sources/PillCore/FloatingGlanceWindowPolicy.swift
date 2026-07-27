// FloatingGlanceWindowPolicy.swift — always-on-top policy for fleet/usage glance.
//
// Same stacking band as the desktop companion pet; separate surface so users
// can show glance without the pet (or both). Pure values for unit tests.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Always-on-top configuration for the Mac floating fleet/usage glance (UX-058).
public enum FloatingGlanceWindowPolicy: Sendable {

    /// Offset above status-window — matches desktop companion / notch band.
    public static let levelOffsetAboveStatusWindow: Int = 2

    public static var windowLevelRawValue: Int {
        #if canImport(AppKit)
        return Int(CGWindowLevelForKey(.statusWindow)) + levelOffsetAboveStatusWindow
        #else
        return 25 + levelOffsetAboveStatusWindow
        #endif
    }

    public static func isAlwaysOnTopLevel(_ rawValue: Int) -> Bool {
        #if canImport(AppKit)
        let status = Int(CGWindowLevelForKey(.statusWindow))
        return rawValue >= status
        #else
        return rawValue >= 25
        #endif
    }

    public static let canBecomeKey: Bool = false
    public static let canBecomeMain: Bool = false
    public static let usesNonactivatingPanelStyle: Bool = true
    public static let hidesOnDeactivate: Bool = false
    public static let isReleasedWhenClosed: Bool = false
    public static let isMovable: Bool = true
    public static let isMovableByWindowBackground: Bool = true

    public static let joinsAllSpaces: Bool = true
    public static let stationary: Bool = true
    public static let fullScreenAuxiliary: Bool = true
    public static let ignoresCycle: Bool = true

    #if canImport(AppKit)
    public static var collectionBehavior: NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = []
        if joinsAllSpaces { behavior.insert(.canJoinAllSpaces) }
        if stationary { behavior.insert(.stationary) }
        if fullScreenAuxiliary { behavior.insert(.fullScreenAuxiliary) }
        if ignoresCycle { behavior.insert(.ignoresCycle) }
        return behavior
    }

    public static var styleMask: NSWindow.StyleMask {
        usesNonactivatingPanelStyle
            ? [.borderless, .nonactivatingPanel]
            : [.borderless]
    }
    #endif

    public static let reassertOnActiveSpaceChange: Bool = true
    public static let reassertOnScreenParametersChange: Bool = true
    public static let launchReassertInterval: TimeInterval = 1.0
    public static let launchReassertTickCount: Int = 4

    /// Default panel width (compact glance card).
    public static let defaultWidth: Double = 220
    /// Default panel height (compact glance card).
    public static let defaultHeight: Double = 88

    /// Margin from screen edges when placing the glance.
    public static let screenMargin: Double = 24
    /// Vertical offset above the desktop pet default corner (avoid overlap).
    public static let stackAboveCompanion: Double = 180

    public static var policySnapshot: [String: String] {
        [
            "levelOffsetAboveStatusWindow": "\(levelOffsetAboveStatusWindow)",
            "windowLevelRawValue": "\(windowLevelRawValue)",
            "canBecomeKey": "\(canBecomeKey)",
            "hidesOnDeactivate": "\(hidesOnDeactivate)",
            "joinsAllSpaces": "\(joinsAllSpaces)",
            "isAlwaysOnTopLevel": "\(isAlwaysOnTopLevel(windowLevelRawValue))",
        ]
    }

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
