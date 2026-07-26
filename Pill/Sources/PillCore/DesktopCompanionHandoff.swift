// DesktopCompanionHandoff.swift — pure focus-id policy for desktop → notch (E4).
import Foundation

public enum DesktopCompanionHandoff: Sendable {
    public static let expandsNotchOnActivate: Bool = true

    public static func focusAgentId(from presentation: DesktopCompanionPresentation) -> String? {
        focusAgentId(presentation.state?.id)
    }

    public static func focusAgentId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    public static func isFocusedRow(rowAgentId: String, focusedAgentId: String?) -> Bool {
        guard let focused = focusAgentId(focusedAgentId) else { return false }
        return rowAgentId == focused
    }
}
