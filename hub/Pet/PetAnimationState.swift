// PetAnimationState.swift — the four moods a companion pet can be in.
//
// Each state maps to a real signal on the agent card, never to decoration:
//
//   idle    → agents.status == idle, seen recently
//   alert   → the agent is active/waiting, or streaming gate messages right now
//   happy   → a human just approved one of this agent's asks (0.4 s, one-shot)
//   sleepy  → agents.last_seen_ns is older than `sleepyAfter`
//
// The mapping itself lives in `PetAnimationState.forAgent(...)` so the hub card
// and the previews agree on it.

import Foundation

enum PetAnimationState: String, CaseIterable, Hashable {
    case idle, alert, happy, sleepy

    /// How long an agent must go unseen before its pet nods off.
    static let sleepyAfter: TimeInterval = 300   // 5 min

    /// How long the `happy` bounce runs before the pet returns to its
    /// underlying state.
    static let happyDuration: TimeInterval = 0.4

    /// Derives the mood from the signals an agent card already has.
    ///
    /// - Parameters:
    ///   - isActive: the gate reports this agent as active or waiting.
    ///   - isStreaming: a gate message arrived within the streaming window.
    ///   - justApproved: a human approved an ask within `happyDuration`.
    ///   - secondsSinceLastSeen: age of agents.last_seen_ns, nil if never seen.
    static func forAgent(isActive: Bool,
                         isStreaming: Bool,
                         justApproved: Bool,
                         secondsSinceLastSeen: TimeInterval?) -> PetAnimationState {
        if justApproved { return .happy }
        if isActive || isStreaming { return .alert }
        if let age = secondsSinceLastSeen, age > sleepyAfter { return .sleepy }
        return .idle
    }
}
