// PetCodexMotion.swift — pure signal → Codex-aligned motion vocabulary.
//
// Maps live agent/hub evidence onto standard Codex v2 atlas rows:
//   idle | running | waiting | failed | review | waving | jumping
//
// Parallel to hub/pet_codex_motion.py (same precedence and honesty rules).
// CompanionMood remains the procedural Canvas mood; this enum drives atlas
// frame selection when a Codex package is available.

import Foundation

/// Codex-compatible animation state for companion surfaces.
public enum PetCodexMotion: String, CaseIterable, Hashable, Sendable {
    case idle
    case running          // busy work (atlas row 7)
    case waiting
    case failed
    case review
    case waving           // approval / greeting one-shot
    case jumping          // optional celebration polish
    case runningRight = "running-right"
    case runningLeft = "running-left"

    /// Motions required by Shannon companion responsiveness.
    public static let core: [PetCodexMotion] = [
        .idle, .running, .waiting, .failed, .review,
    ]

    /// True only for motions that assert the agent is doing work.
    public var claimsWork: Bool {
        switch self {
        case .running, .runningRight, .runningLeft: return true
        default: return false
        }
    }

    /// Foot-walk atlas rows (`running-left` / `running-right`) vs busy-in-place `running`.
    public var isLocomotion: Bool {
        switch self {
        case .runningLeft, .runningRight: return true
        default: return false
        }
    }

    /// Busy-in-place work row (atlas row 7) — not foot locomotion.
    public var isBusyInPlace: Bool { self == .running }

    /// Seconds per foot-walk direction half-cycle on the desktop companion.
    public static let locomotionStrideSeconds: Double = 2.4

    /// Atlas playback motion for a resolved base motion.
    ///
    /// - Busy-in-place `running` can intentionally become `running-left` /
    ///   `running-right` for desktop walk polish (phase-stable on `tSeconds`).
    /// - Already-directed locomotion is preserved.
    /// - Non-work motions are unchanged (never invent walk for idle/wait/fail).
    /// - `allowLocomotion: false` keeps busy-in-place (procedural / Reduce Motion).
    public static func atlasPlaybackMotion(
        base: PetCodexMotion,
        tSeconds: Double,
        agentSeed: String = "",
        allowLocomotion: Bool = true
    ) -> PetCodexMotion {
        switch base {
        case .runningLeft, .runningRight:
            return base
        case .running:
            guard allowLocomotion else { return .running }
            return locomotionDirection(tSeconds: tSeconds, agentSeed: agentSeed)
        default:
            return base
        }
    }

    /// Phase-stable left/right foot-walk from wall time + agent seed.
    public static func locomotionDirection(
        tSeconds: Double,
        agentSeed: String = ""
    ) -> PetCodexMotion {
        let period = max(0.5, locomotionStrideSeconds)
        let t = max(0.0, tSeconds)
        var hash = 0
        for b in agentSeed.utf8 {
            hash = hash &* 31 &+ Int(b)
        }
        // Bucket flips every `period` seconds; seed biases start side.
        let bucket = Int(floor(t / period)) &+ (hash & 1)
        return (bucket & 1) == 0 ? .runningRight : .runningLeft
    }

    /// Evidence inputs for deterministic motion selection.
    public struct Signals: Sendable, Equatable {
        public var presence: AgentPresence
        public var status: AgentRunStatus
        public var hasPendingAsk: Bool
        public var lastOutcome: String?
        public var justApproved: Bool
        public var entropyCollapse: Bool
        public var celebrateAsJump: Bool

        public init(
            presence: AgentPresence = .observed,
            status: AgentRunStatus = .idle,
            hasPendingAsk: Bool = false,
            lastOutcome: String? = nil,
            justApproved: Bool = false,
            entropyCollapse: Bool = false,
            celebrateAsJump: Bool = false
        ) {
            self.presence = presence
            self.status = status
            self.hasPendingAsk = hasPendingAsk
            self.lastOutcome = lastOutcome
            self.justApproved = justApproved
            self.entropyCollapse = entropyCollapse
            self.celebrateAsJump = celebrateAsJump
        }
    }

    private static let failedOutcomes: Set<String> = [
        "failed", "fail", "error", "errored", "failure", "crash", "crashed",
    ]
    private static let reviewOutcomes: Set<String> = [
        "review", "done", "success", "succeeded", "completed", "complete", "passed",
    ]

    /// Pure mapping. Precedence matches hub/pet_codex_motion.py.
    public static func map(_ signals: Signals) -> PetCodexMotion {
        let live = signals.presence.canBeBusy
        let outcome = (signals.lastOutcome ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // 1. Collapse outranks celebration.
        if live, signals.entropyCollapse { return .failed }

        // 2. Approval one-shot.
        if signals.justApproved {
            return signals.celebrateAsJump ? .jumping : .waving
        }

        // 3–6 only from live-capable presence.
        if live {
            if signals.hasPendingAsk || signals.status == .blocked {
                return .waiting
            }
            if failedOutcomes.contains(outcome) { return .failed }
            if signals.status == .active || signals.status == .midTask {
                return .running
            }
            if reviewOutcomes.contains(outcome) { return .review }
        }

        return .idle
    }

    /// Bridge from procedural CompanionMood (+ optional status cues).
    public static func from(
        mood: CompanionMood,
        status: AgentRunStatus = .idle,
        hasPendingAsk: Bool = false,
        lastOutcome: String? = nil
    ) -> PetCodexMotion {
        switch mood {
        case .wary:
            return .failed
        case .happy:
            return .waving
        case .alert:
            if hasPendingAsk || status == .blocked { return .waiting }
            if let o = lastOutcome?.lowercased(), failedOutcomes.contains(o) {
                return .failed
            }
            return .running
        case .idle, .sleepy:
            if let o = lastOutcome?.lowercased(), reviewOutcomes.contains(o) {
                return .review
            }
            return .idle
        }
    }

    /// Resolve from a live activity snapshot.
    public static func resolve(
        for agent: AgentActivitySnapshot,
        now: Date = Date(),
        approvedAt: Date? = nil,
        hasPendingAsk: Bool = false,
        lastOutcome: String? = nil,
        entropyDelta: Double? = nil,
        collapseThreshold: Double = CompanionMood.defaultCollapseThreshold
    ) -> PetCodexMotion {
        let collapse: Bool = {
            guard agent.presence == .live, let d = entropyDelta else { return false }
            return d <= collapseThreshold
        }()
        let approved: Bool = {
            guard let at = approvedAt else { return false }
            let age = now.timeIntervalSince(at)
            return age >= 0 && age <= CompanionMood.happyDuration
        }()
        return map(Signals(
            presence: agent.presence,
            status: agent.status,
            hasPendingAsk: hasPendingAsk,
            lastOutcome: lastOutcome,
            justApproved: approved,
            entropyCollapse: collapse
        ))
    }
}
