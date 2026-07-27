import Foundation

// MARK: - Status board columns (needs-you / working / done — UX-057)

/// Kanban-style column for multi-agent status boards (AgentPeek parity G4).
///
/// Only **actionable / terminal** attention maps into a column:
/// - ``needsYou`` — blocked or open confirmation
/// - ``working`` — actively running
/// - ``done`` — finished
///
/// Idle and unknown stay **out** of the three columns (honest: they are not
/// working and not done). Surfaces may still list them after the board.
public enum StatusBoardColumn: Int, Sendable, CaseIterable, Comparable, Hashable {
    case needsYou = 0
    case working = 1
    case done = 2

    public static func < (lhs: StatusBoardColumn, rhs: StatusBoardColumn) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Agents partitioned into status-board columns, preserving input order within
/// each column (callers should pass ``rankedForDisplay`` order).
public struct StatusBoardBuckets<Element: Sendable>: Sendable, Equatable
where Element: Equatable {
    public var needsYou: [Element]
    public var working: [Element]
    public var done: [Element]
    /// Ranked items that do not map to a column (idle / unknown).
    public var other: [Element]

    public init(
        needsYou: [Element] = [],
        working: [Element] = [],
        done: [Element] = [],
        other: [Element] = []
    ) {
        self.needsYou = needsYou
        self.working = working
        self.done = done
        self.other = other
    }

    public var isEmpty: Bool {
        needsYou.isEmpty && working.isEmpty && done.isEmpty && other.isEmpty
    }

    /// True when at least one of the three status columns has a row.
    public var hasColumnContent: Bool {
        !needsYou.isEmpty || !working.isEmpty || !done.isEmpty
    }

    public func agents(in column: StatusBoardColumn) -> [Element] {
        switch column {
        case .needsYou: return needsYou
        case .working: return working
        case .done: return done
        }
    }
}

/// Pure presenters for status-board columns shared by Mac CompanionBoard and
/// pad hub (and any future surface).
///
/// **Fail-closed:** never invents a column without a real attention signal.
/// Section titles share ``AgentAttentionCopy`` vocabulary so dual-OS wording
/// cannot fork from badge/focus tokens.
public enum StatusBoardColumns: Sendable {

    /// Board order: needs-you → working → done.
    public static let displayOrder: [StatusBoardColumn] = [.needsYou, .working, .done]

    // MARK: Section titles

    /// Section header for a column (sentence case — matches focus / badge family).
    public static func title(for column: StatusBoardColumn) -> String {
        switch column {
        case .needsYou:
            // Same capitalisation as `AgentAttentionCopy.needsYouFocusLine`.
            return "Needs you"
        case .working:
            return AgentAttentionCopy.working.capitalized
        case .done:
            return AgentAttentionCopy.done.capitalized
        }
    }

    /// Accessibility identity prefix for a column section.
    public static func accessibilityIdentifier(for column: StatusBoardColumn) -> String {
        switch column {
        case .needsYou: return "statusBoard.needsYou"
        case .working: return "statusBoard.working"
        case .done: return "statusBoard.done"
        }
    }

    // MARK: Column resolution

    /// Map shared attention kind → board column. Idle/unknown → `nil`.
    public static func column(for kind: AgentAttentionCopy.Kind) -> StatusBoardColumn? {
        switch kind {
        case .needsYou: return .needsYou
        case .working: return .working
        case .finished: return .done
        case .idle, .unknown: return nil
        }
    }

    /// Map cloud / mobile activity (+ optional open confirmation) → column.
    public static func column(
        activity: AgentActivity,
        hasPendingConfirmation: Bool = false
    ) -> StatusBoardColumn? {
        column(
            for: AgentAttentionCopy.kind(
                for: activity,
                hasPendingConfirmation: hasPendingConfirmation
            )
        )
    }

    // MARK: Partition

    /// Generic partition preserving input order within each column.
    public static func partition<T: Sendable>(
        _ items: [T],
        columnFor: (T) -> StatusBoardColumn?
    ) -> StatusBoardBuckets<T> where T: Equatable {
        var needsYou: [T] = []
        var working: [T] = []
        var done: [T] = []
        var other: [T] = []
        needsYou.reserveCapacity(items.count)
        working.reserveCapacity(items.count)
        done.reserveCapacity(items.count)
        other.reserveCapacity(items.count)
        for item in items {
            switch columnFor(item) {
            case .needsYou: needsYou.append(item)
            case .working: working.append(item)
            case .done: done.append(item)
            case nil: other.append(item)
            }
        }
        return StatusBoardBuckets(
            needsYou: needsYou,
            working: working,
            done: done,
            other: other
        )
    }

    /// Bucket ranked agents for the three-column board.
    ///
    /// - Parameters:
    ///   - agents: Unordered or pre-ranked agents; re-ranked when `rank` is true.
    ///   - pendingAgentIDs: Open confirmation agent ids (elevates to needs-you).
    ///   - rank: When true (default), apply ``rankedForDisplay`` first.
    public static func bucket(
        agents: [AgentState],
        pendingAgentIDs: Set<String> = [],
        rank: Bool = true
    ) -> StatusBoardBuckets<AgentState> {
        let ordered = rank
            ? agents.rankedForDisplay(pendingAgentIDs: pendingAgentIDs)
            : agents
        return partition(ordered) { agent in
            column(
                activity: agent.activity,
                hasPendingConfirmation: pendingAgentIDs.contains(agent.id)
            )
        }
    }

    /// Convenience over a full snapshot (non-expired confirmations only).
    public static func bucket(
        snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> StatusBoardBuckets<AgentState> {
        let pending = HubCompactNeedsYouChrome.pendingAgentIDs(
            from: snapshot.confirmations,
            now: now
        )
        return bucket(agents: snapshot.agents, pendingAgentIDs: pending)
    }
}
