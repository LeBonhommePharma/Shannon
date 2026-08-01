// PetAnimationState.swift — companion pet moods for the hub HUD.
//
// Procedural Canvas moods (original four):
//   idle    → agents.status == idle, seen recently
//   alert   → the agent is active/waiting, or streaming gate messages right now
//   happy   → a human just approved one of this agent's asks (0.4 s, one-shot)
//   sleepy  → agents.last_seen_ns is older than `sleepyAfter`
//
// Codex-aligned motion (for optional spritesheet atlas) is derived via
// `codexMotion(...)` — vocabulary: idle / running / waiting / failed / review
// (+ waving for happy). Pure mapping mirrors hub/pet_codex_motion.py and
// PillCore.PetCodexMotion.
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

    /// A one-word label suitable for display in the HUD header.
    var moodLabel: String {
        switch self {
        case .idle:   return "resting"
        case .alert:  return "focused"
        case .happy:  return "celebrating"
        case .sleepy: return "sleeping"
        }
    }

    /// Codex atlas motion label for this procedural mood (default bridge).
    var codexMotionLabel: String {
        switch self {
        case .idle:   return "idle"
        case .alert:  return "running"
        case .happy:  return "waving"
        case .sleepy: return "idle"
        }
    }

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

    /// Codex-aligned motion from richer hub signals. Deterministic.
    ///
    /// Precedence: collapse → failed; approval → waving; waiting/ask → waiting;
    /// failed outcome → failed; busy → running; review outcome → review; else idle.
    static func codexMotion(
        isActive: Bool,
        isStreaming: Bool,
        isWaiting: Bool = false,
        justApproved: Bool = false,
        entropyCollapse: Bool = false,
        lastOutcome: String? = nil,
        isLivePresence: Bool = true
    ) -> String {
        let live = isLivePresence
        let outcome = (lastOutcome ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let failed: Set<String> = ["failed", "fail", "error", "errored", "failure"]
        let review: Set<String> = ["review", "done", "success", "succeeded", "completed", "complete", "passed"]

        if live && entropyCollapse { return "failed" }
        if justApproved { return "waving" }
        if live {
            if isWaiting { return "waiting" }
            if failed.contains(outcome) { return "failed" }
            if isActive || isStreaming { return "running" }
            if review.contains(outcome) { return "review" }
        }
        return "idle"
    }
}
