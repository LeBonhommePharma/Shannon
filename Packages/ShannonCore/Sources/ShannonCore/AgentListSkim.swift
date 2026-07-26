import Foundation

// MARK: - Phone list skim density (Mac collapsed multi-agent parity — UX-006)

/// Pure presenters for companion agent **list skim** density.
///
/// **Mac collapsed pill** shows multi-agent count (needs-you + working) plus a
/// short primary focus — never a wall of task text. The phone card list must
/// skim the same priority (needs-you first via ``AgentAttentionRank``) with the
/// same badge vocabulary (``AgentAttentionCopy``) and a one-line secondary
/// without long task junk.
///
/// Fail-closed: no invented tokens, H, or “working” without a real signal.
public enum AgentListSkim: Sendable {

    /// Cap for secondary skim line — matches Mac collapsed label density (~42).
    public static let skimMaxLength = 42

    // MARK: Row model

    /// One ranked agent card, ready for phone (or any companion list).
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        /// Capsule badge from ``AgentAttentionCopy`` (pending elevates to needs-you).
        public let badge: String
        public let attention: AgentAttentionCopy.Kind
        /// One short secondary line, or `nil` when nothing honest to show.
        public let skimLine: String?
        /// Measured entropy readout only when bits were published (never invented).
        public let entropyLabel: String?
        public let turnCount: Int
        public let isCollapsed: Bool

        public var isNeedsYou: Bool { attention == .needsYou }

        public init(
            id: String,
            name: String,
            badge: String,
            attention: AgentAttentionCopy.Kind,
            skimLine: String?,
            entropyLabel: String?,
            turnCount: Int,
            isCollapsed: Bool
        ) {
            self.id = id
            self.name = name
            self.badge = badge
            self.attention = attention
            self.skimLine = skimLine
            self.entropyLabel = entropyLabel
            self.turnCount = turnCount
            self.isCollapsed = isCollapsed
        }
    }

    // MARK: Active fleet (Mac collapsed count chip)

    /// Whether this agent contributes to the multi-agent glance count.
    ///
    /// Mac `activeFleetCount` / collapsed chip: **needs-you or working only** —
    /// finished / idle / unknown do not inflate density.
    public static func isActiveFleet(
        activity: AgentActivity,
        hasPendingConfirmation: Bool = false
    ) -> Bool {
        let kind = AgentAttentionCopy.kind(
            for: activity,
            hasPendingConfirmation: hasPendingConfirmation
        )
        return kind == .needsYou || kind == .working
    }

    /// Count of agents that need a glance (needs-you + working), Mac parity.
    public static func activeFleetCount(
        in snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> Int {
        let pending = pendingAgentIDs(in: snapshot, now: now)
        return snapshot.agents.filter {
            isActiveFleet(
                activity: $0.activity,
                hasPendingConfirmation: pending.contains($0.id)
            )
        }.count
    }

    /// Collapsed multi-agent count chip text when more than one agent is active.
    ///
    /// Returns `"N"` (Mac pill shows the digit alone) or `nil` when a single
    /// agent / quiet fleet should not claim multi-agent density.
    public static func multiAgentCountLabel(activeCount: Int) -> String? {
        guard activeCount > 1 else { return nil }
        return "\(activeCount)"
    }

    /// Accessibility / section hint: `"2 agents need a glance"` (Mac `.help`).
    public static func multiAgentAccessibilityLabel(activeCount: Int) -> String? {
        guard activeCount > 1 else { return nil }
        return "\(activeCount) agents need a glance"
    }

    // MARK: Skim secondary line

    /// One-line secondary for a card — prefer recent action, then task title.
    ///
    /// Clips to ``skimMaxLength`` so long task strings never dominate the list
    /// the way Mac collapsed avoids dumping activity walls. Empty → `nil`
    /// (no placeholder “No task” junk on skim).
    public static func skimLine(
        taskTitle: String,
        lastAction: String,
        maxLength: Int = skimMaxLength
    ) -> String? {
        let action = lastAction.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if !action.isEmpty {
            raw = action
        } else if !task.isEmpty {
            raw = task
        } else {
            return nil
        }
        let limit = max(1, maxLength)
        guard raw.count > limit else { return raw }
        return String(raw.prefix(limit - 1)) + "…"
    }

    // MARK: Rows

    /// Build one skim row from a cloud agent (+ optional open confirmation).
    public static func row(
        for agent: AgentState,
        hasPendingConfirmation: Bool = false
    ) -> Row {
        let attention = AgentAttentionCopy.kind(
            for: agent.activity,
            hasPendingConfirmation: hasPendingConfirmation
        )
        let badge = AgentAttentionCopy.badgeLabel(
            for: agent.activity,
            hasPendingConfirmation: hasPendingConfirmation
        )
        return Row(
            id: agent.id,
            name: agent.name,
            badge: badge,
            attention: attention,
            skimLine: skimLine(taskTitle: agent.taskTitle, lastAction: agent.lastAction),
            entropyLabel: agent.entropyLabel,
            turnCount: agent.turnCount,
            isCollapsed: agent.isCollapsed
        )
    }

    /// Ranked skim rows for the phone agent list (needs-you first).
    public static func rows(
        in snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> [Row] {
        let pending = pendingAgentIDs(in: snapshot, now: now)
        return snapshot.agentsRankedForDisplay(now: now).map { agent in
            row(for: agent, hasPendingConfirmation: pending.contains(agent.id))
        }
    }

    // MARK: Internals

    private static func pendingAgentIDs(
        in snapshot: ShannonSnapshot,
        now: Date
    ) -> Set<String> {
        Set(
            snapshot.confirmations
                .filter { !$0.isExpired(now: now) }
                .compactMap(\.agentID)
                .filter { !$0.isEmpty }
        )
    }
}
