import Foundation

// MARK: - Shared attention / badge wording (multi-OS)

/// Canonical capsule and focus strings for agent attention on **every** OS.
///
/// Mac (`AgentLiveSurfaceLogic.badgeLabel`), iPhone/iPad activity labels, and
/// notify focus lines must call this API so dual-OS wording drift cannot reappear
/// without a failing test (UX-001).
///
/// Fail-closed: unknown attention uses the caller's fallback — never invents
/// "working" or "needs you" without a real signal.
public enum AgentAttentionCopy: Sendable {

    // MARK: Canonical tokens (lowercase capsule style — matches Mac notch)

    public static let needsYou = "needs you"
    public static let working = "working"
    public static let done = "done"
    public static let live = "live"

    /// Conceptual attention shared across Mac live surface and cloud `AgentActivity`.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case needsYou
        case working
        case finished
        case idle
        case unknown
    }

    // MARK: Badge labels

    /// Capsule badge for a resolved attention kind.
    ///
    /// - Parameters:
    ///   - kind: Attention state.
    ///   - toolKindRaw: Optional tool category (`edit`, `read`, …) when working.
    ///     Empty / nil → `"working"`.
    ///   - fallback: Used only for `.unknown` (e.g. `"seen 2m ago"`).
    public static func badgeLabel(
        kind: Kind,
        toolKindRaw: String? = nil,
        fallback: String = ""
    ) -> String {
        switch kind {
        case .needsYou: return needsYou
        case .working:
            let tool = toolKindRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if tool.isEmpty || tool == "none" { return working }
            return tool
        case .finished: return done
        case .idle: return live
        case .unknown: return fallback
        }
    }

    /// Map cloud / mobile `AgentActivity` (+ optional open confirmation) → kind.
    public static func kind(
        for activity: AgentActivity,
        hasPendingConfirmation: Bool = false
    ) -> Kind {
        if hasPendingConfirmation { return .needsYou }
        switch activity {
        case .blocked: return .needsYou
        case .running: return .working
        case .finished: return .finished
        case .idle: return .idle
        case .errored: return .unknown
        }
    }

    /// Badge for a cloud agent row (phone / pad / watch).
    public static func badgeLabel(
        for activity: AgentActivity,
        hasPendingConfirmation: Bool = false,
        fallback: String = ""
    ) -> String {
        badgeLabel(
            kind: kind(for: activity, hasPendingConfirmation: hasPendingConfirmation),
            toolKindRaw: nil,
            fallback: fallback.isEmpty ? activity.rawValue : fallback
        )
    }

    /// Sentence-ish card label (pad cards / palette). Uses the same tokens so
    /// "Waiting on you" cannot diverge from Mac `"needs you"`.
    public static func activityLabel(
        for activity: AgentActivity,
        hasPendingConfirmation: Bool = false
    ) -> String {
        let k = kind(for: activity, hasPendingConfirmation: hasPendingConfirmation)
        switch k {
        case .needsYou: return needsYou
        case .working: return working
        case .finished: return done
        case .idle: return live
        case .unknown:
            // Errored is the only unknown mapping today — keep readable.
            return activity == .errored ? "errored" : activity.rawValue
        }
    }

    // MARK: Focus lines

    /// Collapsed / HUD focus: `"Needs you · Agent"` (capital N for sentence start).
    public static func needsYouFocusLine(agentDisplayName: String) -> String {
        let name = agentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Needs you" }
        return "Needs you · \(name)"
    }

    /// Notification title fragment: `"agentId needs you"` (matches GlobalNotify).
    public static func needsYouNotifyTitle(agentID: String?) -> String {
        let agent = agentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let agent, !agent.isEmpty {
            return "\(agent) \(needsYou)"
        }
        return "Approval needed"
    }
}
