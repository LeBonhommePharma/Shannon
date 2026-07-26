import Foundation

/// Lifecycle of one Shannon-coordinated agent, as the phone and watch see it.
public enum AgentActivity: String, Codable, Sendable, CaseIterable {
    case running
    case idle
    case blocked
    case errored
    case finished

    /// Single glyph for the watch complication, where there is room for one.
    public var glyph: String {
        switch self {
        case .running:  return "▶"
        case .idle:     return "·"
        case .blocked:  return "⏸"
        case .errored:  return "✕"
        case .finished: return "✓"
        }
    }

    /// Whether a state change into this activity deserves a haptic tap.
    public var isAlerting: Bool {
        self == .errored || self == .finished
    }
}

/// One agent's snapshot. Deliberately small — this crosses iCloud on every
/// change, so raw tool output and transcripts stay on the Mac.
public struct AgentState: CloudSyncable, Codable, Identifiable, Hashable {
    /// Stable across the agent's lifetime, e.g. "local_9c754fdc".
    public var id: String
    public var name: String
    public var activity: AgentActivity
    /// Current task title, already truncated by the publisher.
    public var taskTitle: String
    public var turnCount: Int
    /// Human summary of the most recent action, e.g. "Edited PillView.swift".
    public var lastAction: String
    /// Shannon entropy of this agent's tool-call distribution, in bits.
    public var entropyBits: Double?
    /// Sliding-window z-score delta. Negative past the threshold means collapse.
    public var entropyDelta: Double?
    public var isCollapsed: Bool
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        activity: AgentActivity,
        taskTitle: String = "",
        turnCount: Int = 0,
        lastAction: String = "",
        entropyBits: Double? = nil,
        entropyDelta: Double? = nil,
        isCollapsed: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.activity = activity
        self.taskTitle = taskTitle
        self.turnCount = turnCount
        self.lastAction = lastAction
        self.entropyBits = entropyBits
        self.entropyDelta = entropyDelta
        self.isCollapsed = isCollapsed
        self.updatedAt = updatedAt
    }

    /// "H 8.4" / "H 2.1 ▽3.4" — mirrors the Mac pill's readout so the same
    /// number reads the same way on every device.
    public var entropyLabel: String? {
        guard let h = entropyBits else { return nil }
        let base = "H \(String(format: "%.1f", h))"
        guard let d = entropyDelta, d < 0 else { return base }
        return "\(base) ▽\(String(format: "%.1f", abs(d)))"
    }

    /// One line for the watch: "▶ FlexAIDdS · 12 turns".
    public func compactLine(maxLength: Int = 34) -> String {
        let composed = "\(activity.glyph) \(name) · \(turnCount) turns"
        guard composed.count > maxLength else { return composed }
        return String(composed.prefix(max(maxLength - 1, 1))) + "…"
    }

    // MARK: CloudSyncable

    public static let recordType = "AgentState"
    public var recordName: String { "agent-\(id)" }

    enum Field {
        static let id = "agentID"
        static let name = "name"
        static let activity = "activity"
        static let taskTitle = "taskTitle"
        static let turnCount = "turnCount"
        static let lastAction = "lastAction"
        static let entropyBits = "entropyBits"
        static let entropyDelta = "entropyDelta"
        static let isCollapsed = "isCollapsed"
    }

    public var cloudFields: CloudFields {
        var f: CloudFields = [
            Field.id: .string(id),
            Field.name: .string(name),
            Field.activity: .string(activity.rawValue),
            Field.taskTitle: .string(taskTitle),
            Field.turnCount: .int(turnCount),
            Field.lastAction: .string(lastAction),
            Field.isCollapsed: .bool(isCollapsed),
            CloudKeys.updatedAt: .date(updatedAt),
        ]
        if let entropyBits { f[Field.entropyBits] = .double(entropyBits) }
        if let entropyDelta { f[Field.entropyDelta] = .double(entropyDelta) }
        return f
    }

    public init(cloudFields f: CloudFields) throws {
        let raw = try f.string(Field.activity)
        guard let activity = AgentActivity(rawValue: raw) else {
            throw CloudDecodeError.unknownEnumValue(field: Field.activity, value: raw)
        }
        self.init(
            id: try f.string(Field.id),
            name: try f.string(Field.name),
            activity: activity,
            taskTitle: try f.string(Field.taskTitle),
            turnCount: try f.int(Field.turnCount),
            lastAction: try f.string(Field.lastAction),
            entropyBits: try f.optionalDouble(Field.entropyBits),
            entropyDelta: try f.optionalDouble(Field.entropyDelta),
            isCollapsed: try f.bool(Field.isCollapsed),
            updatedAt: try f.date(CloudKeys.updatedAt)
        )
    }
}

// MARK: - Attention rank (Mac roster parity — UX-004)

/// Pure attention priority for companion agent lists.
///
/// Matches Mac `AgentLiveSurfaceLogic` / session roster:
/// **needs you → (errored) → working → finished → idle**.
///
/// Companions have no live gate surface; `blocked` activity **or** a pending
/// confirmation agent id elevates to needs-you so iPad/phone never bury an ask.
public enum AgentAttentionRank: Sendable {
    /// Lower = higher on the board.
    public static func priority(
        activity: AgentActivity,
        hasPendingConfirmation: Bool = false
    ) -> Int {
        if hasPendingConfirmation || activity == .blocked { return 0 } // needs you
        switch activity {
        case .errored: return 1
        case .running: return 2 // working
        case .finished: return 3
        case .idle: return 4
        case .blocked: return 0
        }
    }
}

public extension Array where Element == AgentState {
    /// Ordering used by every device: needs-you first (Mac roster parity), then
    /// errored, working, finished, idle — then recency, then stable id.
    ///
    /// - Parameter pendingAgentIDs: Agent ids with an open (non-expired)
    ///   confirmation. Elevates those rows to needs-you even when activity is
    ///   still `.running` / `.idle` (CloudKit mirrors asks separately).
    ///
    /// Fully stable: equal priority + equal `updatedAt` falls back to `id`
    /// ascending so phone, watch and complication never re-shuffle a tie.
    func rankedForDisplay(pendingAgentIDs: Set<String> = []) -> [AgentState] {
        sorted {
            let r0 = AgentAttentionRank.priority(
                activity: $0.activity,
                hasPendingConfirmation: pendingAgentIDs.contains($0.id)
            )
            let r1 = AgentAttentionRank.priority(
                activity: $1.activity,
                hasPendingConfirmation: pendingAgentIDs.contains($1.id)
            )
            if r0 != r1 { return r0 < r1 }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    var runningCount: Int { filter { $0.activity == .running }.count }
}

public extension ShannonSnapshot {
    /// Agents ordered for every companion surface, elevating open confirmations.
    func agentsRankedForDisplay(now: Date = Date()) -> [AgentState] {
        let pendingIDs = Set(
            confirmations
                .filter { !$0.isExpired(now: now) }
                .compactMap(\.agentID)
                .filter { !$0.isEmpty }
        )
        return agents.rankedForDisplay(pendingAgentIDs: pendingIDs)
    }
}
