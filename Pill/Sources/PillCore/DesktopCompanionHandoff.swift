// DesktopCompanionHandoff.swift — pure focus-id policy for desktop → notch (E4).
//
// Click bubble/pet expands the notch board and highlights the matching agent
// row when the desktop companion is bound to a roster agent.

import Foundation

/// Pure policy for E4: click the desktop pet/bubble → expand the notch board
/// and optionally focus the matching agent row.
///
/// No AppKit: unit tests assert focus-id selection without a window server.
public enum DesktopCompanionHandoff: Sendable {

    /// Always expand the notch when the desktop companion is deliberately clicked.
    public static let expandsNotchOnActivate: Bool = true

    /// Agent id to highlight on the expanded board, or nil when the desktop
    /// surface is showing the empty/watching companion (no roster row).
    public static func focusAgentId(from presentation: DesktopCompanionPresentation) -> String? {
        focusAgentId(presentation.state?.id)
    }

    /// Normalize a raw agent id into a focus target (nil when blank).
    public static func focusAgentId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// Whether `rowAgentId` should paint as the focused board row.
    public static func isFocusedRow(rowAgentId: String, focusedAgentId: String?) -> Bool {
        guard let focused = focusAgentId(focusedAgentId) else { return false }
        return rowAgentId == focused
    }
}
