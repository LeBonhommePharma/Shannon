import Foundation
import ShannonCore

// MARK: - Mac voice callout (ENH-030 / parity G8)

/// Events eligible for a spoken Mac callout.
///
/// First slice: **needs-you** (gate ask) and **task_complete** only.
/// Fail-closed — no other status invents speech.
public enum VoiceCalloutKind: String, Sendable, Equatable, CaseIterable {
    case needsYou
    case taskComplete
}

/// Pure “should announce” + spoken-text policy for Mac voice callouts.
///
/// Rules (fail closed):
/// - Pref off → never
/// - Muted → never
/// - Focus / quiet active → never
/// - Spoken text uses **real agent name + shared status tokens only**
///   (`AgentAttentionCopy`); never invents summaries or fake agent state
public enum VoiceCalloutPolicy: Sendable {

    /// Whether a callout of `kind` may speak given product gates.
    public static func shouldAnnounce(
        kind: VoiceCalloutKind,
        voiceCalloutsEnabled: Bool,
        muted: Bool = false,
        focusActive: Bool = false
    ) -> Bool {
        guard voiceCalloutsEnabled else { return false }
        guard !muted else { return false }
        guard !focusActive else { return false }
        switch kind {
        case .needsYou, .taskComplete:
            return true
        }
    }

    /// Spoken line from real tokens only.
    ///
    /// - needsYou: `AgentAttentionCopy.needsYouNotifyTitle` ("agent needs you" /
    ///   "Approval needed" when name empty — same family as local notify).
    /// - taskComplete: `"\(name) done"` when name non-empty; **nil** when empty
    ///   (never invent who finished).
    public static func spokenText(
        kind: VoiceCalloutKind,
        agentName: String
    ) -> String? {
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .needsYou:
            return AgentAttentionCopy.needsYouNotifyTitle(
                agentID: name.isEmpty ? nil : name
            )
        case .taskComplete:
            guard !name.isEmpty else { return nil }
            return "\(name) \(AgentAttentionCopy.done)"
        }
    }

    /// Combined decision: returns spoken text only when every gate passes
    /// and honest content is available; otherwise `nil` (do not speak).
    public static func decide(
        kind: VoiceCalloutKind,
        agentName: String,
        voiceCalloutsEnabled: Bool,
        muted: Bool = false,
        focusActive: Bool = false
    ) -> String? {
        guard shouldAnnounce(
            kind: kind,
            voiceCalloutsEnabled: voiceCalloutsEnabled,
            muted: muted,
            focusActive: focusActive
        ) else {
            return nil
        }
        return spokenText(kind: kind, agentName: agentName)
    }

    /// Explicit completion event types only (no fuzzy label invent).
    public static func isTaskCompleteEventType(_ type: String) -> Bool {
        let t = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t == "task_complete"
            || t == "task_completed"
            || t == "completed"
            || t == "done"
            || t == "finish"
    }

    /// New completion rows since a baseline of seen activity ids.
    ///
    /// First-slice: only events whose **type** is an explicit completion token.
    /// Does not invent completions from label prose.
    public static func newTaskCompleteCallouts(
        activity: [(id: Int64, agentId: String, type: String)],
        previouslySeenIds: Set<Int64>
    ) -> [(id: Int64, agentId: String)] {
        var out: [(id: Int64, agentId: String)] = []
        var seen = previouslySeenIds
        // Newest-first feeds are common; preserve first-seen order for speech.
        for row in activity {
            guard !seen.contains(row.id) else { continue }
            seen.insert(row.id)
            guard isTaskCompleteEventType(row.type) else { continue }
            let agent = row.agentId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !agent.isEmpty else { continue }
            out.append((id: row.id, agentId: agent))
        }
        return out
    }
}
