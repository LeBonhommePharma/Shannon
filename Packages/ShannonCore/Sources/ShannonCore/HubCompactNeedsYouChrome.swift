import Foundation

// MARK: - iPad compact (Slide Over) needs-you pin (UX-009)

/// Pure policy for pinning **needs you** chrome in the iPad hub when the window
/// is compact (Slide Over / narrow Stage Manager).
///
/// Ranking alone (`AgentAttentionRank`) puts needs-you agents first among
/// agents, but the compact dashboard still stacks docking cards above the agent
/// grid — so a pending ask can sit below the fold. Pinning elevates needs-you
/// chrome to the top of the scroll stack when (and only when) the layout is
/// compact **and** there is a pending ask.
public enum HubCompactNeedsYouChrome: Sendable {

    /// Section header label (title case — matches the pad notification panel).
    public static let sectionTitle = "Needs You"

    /// Accessibility / a11y identity for the pinned band.
    public static let accessibilityIdentifier = "hub.compact.needsYou.pin"

    /// Whether compact hub should pin needs-you chrome at the top of the stack.
    public static func shouldPin(isCompact: Bool, hasPendingAsk: Bool) -> Bool {
        isCompact && hasPendingAsk
    }

    /// Resolve pin policy from open confirmations (filters expired).
    public static func shouldPin(
        isCompact: Bool,
        pendingConfirmations: [PendingConfirmation],
        now: Date = Date()
    ) -> Bool {
        let hasAsk = pendingConfirmations.contains { !$0.isExpired(now: now) }
        return shouldPin(isCompact: isCompact, hasPendingAsk: hasAsk)
    }

    /// Convenience over a full snapshot (Mac hub mirror).
    public static func shouldPin(
        isCompact: Bool,
        snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> Bool {
        shouldPin(
            isCompact: isCompact,
            pendingConfirmations: snapshot.confirmations,
            now: now
        )
    }

    /// Agents that belong in the pinned needs-you band (blocked **or** open confirmation).
    public static func needsYouAgents(
        from agents: [AgentState],
        pendingAgentIDs: Set<String>
    ) -> [AgentState] {
        agents.filter {
            AgentAttentionRank.priority(
                activity: $0.activity,
                hasPendingConfirmation: pendingAgentIDs.contains($0.id)
            ) == 0
        }
    }

    /// Split display order into pinned needs-you band vs the rest of the grid.
    public static func partitionForDisplay(
        agents: [AgentState],
        pendingAgentIDs: Set<String>,
        pin: Bool
    ) -> (needsYou: [AgentState], rest: [AgentState]) {
        guard pin else { return ([], agents) }
        var needsYou: [AgentState] = []
        var rest: [AgentState] = []
        needsYou.reserveCapacity(agents.count)
        rest.reserveCapacity(agents.count)
        for agent in agents {
            let isNeedsYou = AgentAttentionRank.priority(
                activity: agent.activity,
                hasPendingConfirmation: pendingAgentIDs.contains(agent.id)
            ) == 0
            if isNeedsYou {
                needsYou.append(agent)
            } else {
                rest.append(agent)
            }
        }
        return (needsYou, rest)
    }

    /// Open confirmation agent ids (non-expired, non-empty).
    public static func pendingAgentIDs(
        from confirmations: [PendingConfirmation],
        now: Date = Date()
    ) -> Set<String> {
        Set(
            confirmations
                .filter { !$0.isExpired(now: now) }
                .compactMap(\.agentID)
                .filter { !$0.isEmpty }
        )
    }
}
