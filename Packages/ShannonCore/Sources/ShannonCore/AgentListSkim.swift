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

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let badge: String
        public let attention: AgentAttentionCopy.Kind
        public let skimLine: String?
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

    public static func multiAgentCountLabel(activeCount: Int) -> String? {
        guard activeCount > 1 else { return nil }
        return "\(activeCount)"
    }

    /// Secondary fleet caption after the count chip (phone HomeView + Mac collapsed help).
    /// **UX-055:** one token so Mac/phone “need a glance” cannot fork.
    public static let multiAgentGlanceCaption = "agents need a glance"

    public static func multiAgentAccessibilityLabel(activeCount: Int) -> String? {
        guard activeCount > 1 else { return nil }
        return "\(activeCount) \(multiAgentGlanceCaption)"
    }

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

    public static func rows(
        in snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> [Row] {
        let pending = pendingAgentIDs(in: snapshot, now: now)
        return snapshot.agentsRankedForDisplay(now: now).map { agent in
            row(for: agent, hasPendingConfirmation: pending.contains(agent.id))
        }
    }

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
