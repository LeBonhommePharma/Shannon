import Foundation

// MARK: - Mac floating glance (fleet + usage — UX-058 / parity G6)

/// Content for a pref-gated Mac floating glance panel (AgentPeek widget parity).
///
/// **Fail-closed:** never invents fleet counts or usage. Missing usage stays
/// missing (`usageLine == nil`). Empty fleet yields no fleet line.
public struct FloatingGlancePresentation: Equatable, Sendable {
    /// Fleet skim line (e.g. multi-agent caption or single-agent attention).
    public var fleetLine: String?
    /// Usage chip only when a real local source provided a label.
    public var usageLine: String?
    /// Honest body when both lines are absent (panel still may show chrome).
    public var emptyCaption: String

    public init(
        fleetLine: String? = nil,
        usageLine: String? = nil,
        emptyCaption: String = FloatingGlance.emptyCaption
    ) {
        self.fleetLine = FloatingGlance.nonEmpty(fleetLine)
        self.usageLine = FloatingGlance.nonEmpty(usageLine)
        let empty = emptyCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emptyCaption = empty.isEmpty ? FloatingGlance.emptyCaption : empty
    }

    /// True when there is nothing sourced to show (fleet + usage both absent).
    public var isEmpty: Bool {
        fleetLine == nil && usageLine == nil
    }

    /// Lines for the glance surface (fleet then usage); empty → empty caption only.
    public var displayLines: [String] {
        var lines: [String] = []
        if let fleetLine { lines.append(fleetLine) }
        if let usageLine { lines.append(usageLine) }
        return lines
    }

    /// Combined accessibility label.
    public var accessibilityLabel: String {
        if isEmpty { return emptyCaption }
        return displayLines.joined(separator: ". ")
    }
}

/// Pure presenters for the Mac floating fleet/usage glance (UX-058).
///
/// Shares ``AgentListSkim`` multi-agent caption and ``AgentAttentionCopy``
/// tokens so notch / phone / glance cannot fork vocabulary.
public enum FloatingGlance: Sendable {

    /// Quiet empty body when the panel is visible but nothing is sourced.
    public static let emptyCaption = "No fleet activity"

    /// Accessibility identity for the floating glance surface.
    public static let accessibilityIdentifier = "floatingGlance"

    /// Section title for the glance chrome (not a fake metric).
    public static let title = "Fleet"

    /// Usage section label when a real usage chip is present.
    public static let usageTitle = "Usage"

    // MARK: Present

    /// Build glance content from fleet counts + optional real usage label.
    ///
    /// - Parameters:
    ///   - activeFleetCount: Needs-you + working agents (never invent).
    ///   - needsYouCount: Subset that needs the human (elevates single-agent line).
    ///   - usageLabel: Provider-sourced chip (e.g. `UsageSnapshot.shortLabel`); nil when unknown.
    public static func present(
        activeFleetCount: Int,
        needsYouCount: Int = 0,
        usageLabel: String? = nil
    ) -> FloatingGlancePresentation {
        FloatingGlancePresentation(
            fleetLine: fleetLine(
                activeFleetCount: max(0, activeFleetCount),
                needsYouCount: max(0, needsYouCount)
            ),
            usageLine: nonEmpty(usageLabel)
        )
    }

    /// Convenience over a cloud/mobile snapshot (+ optional usage chip).
    public static func present(
        snapshot: ShannonSnapshot,
        usageLabel: String? = nil,
        now: Date = Date()
    ) -> FloatingGlancePresentation {
        let pending = HubCompactNeedsYouChrome.pendingAgentIDs(
            from: snapshot.confirmations,
            now: now
        )
        let active = AgentListSkim.activeFleetCount(in: snapshot, now: now)
        let needsYou = snapshot.agents.filter { agent in
            AgentAttentionCopy.kind(
                for: agent.activity,
                hasPendingConfirmation: pending.contains(agent.id)
            ) == .needsYou
        }.count
        return present(
            activeFleetCount: active,
            needsYouCount: needsYou,
            usageLabel: usageLabel
        )
    }

    // MARK: Fleet line

    /// Fleet skim line only — nil when the fleet is quiet.
    public static func fleetLine(
        activeFleetCount: Int,
        needsYouCount: Int = 0
    ) -> String? {
        let active = max(0, activeFleetCount)
        guard active > 0 else { return nil }

        if active > 1 {
            return AgentListSkim.multiAgentAccessibilityLabel(activeCount: active)
        }

        // Single active agent: share attention vocabulary (no multi-agent caption).
        if needsYouCount > 0 {
            return "1 \(AgentAttentionCopy.needsYou)"
        }
        return "1 \(AgentAttentionCopy.working)"
    }

    // MARK: Internals

    fileprivate static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
