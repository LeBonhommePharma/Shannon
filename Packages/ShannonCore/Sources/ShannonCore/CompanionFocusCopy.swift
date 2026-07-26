import Foundation

// MARK: - Companion primary focus (watch · widget · quiet face)

/// When to show a primary focus line on companions vs stay quiet.
///
/// **UX-005 / Mac parity:** collapsed Mac pill only surfaces needs-you /
/// working / finished — idle does not invent busy chrome (`Shannon · idle`).
/// Watch face and complications use the same rule over CloudKit snapshots.
public enum CompanionFocusCopy: Sendable {

    /// Quiet face / Always-On when nothing needs a glance (matches Mac family).
    public static let quietFace = "Shannon · idle"

    /// Shortest quiet token for cramped complications.
    public static let quietShort = "Shannon"

    /// Whether this agent warrants a glance (Mac primarySurface family + collapse).
    public static func isActionable(_ agent: AgentState) -> Bool {
        if agent.isCollapsed { return true }
        switch agent.activity {
        case .blocked, .running, .finished, .errored:
            return true
        case .idle:
            return false
        }
    }

    /// Ranked agents that are worth a focus line (needs-you first via rank).
    public static func actionableAgents(
        in snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> [AgentState] {
        snapshot.agentsRankedForDisplay(now: now).filter(isActionable)
    }

    /// Primary focus line, or `nil` when the surface should stay quiet.
    ///
    /// Priority (honest signals only — never invents work):
    /// 1. Pending confirmation (needs you)
    /// 2. Running docking benchmark
    /// 3. Actionable agent (blocked / running / finished / errored / collapsed)
    /// 4. Now Playing when not idle
    public static func primaryFocusLine(
        in snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> String? {
        if let pending = snapshot.oldestPendingConfirmation(now: now) {
            let q = pending.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                let clipped = q.count > 28 ? String(q.prefix(27)) + "…" : q
                return "? \(clipped)"
            }
            if let agentID = pending.agentID, !agentID.isEmpty {
                return AgentAttentionCopy.needsYouFocusLine(agentDisplayName: agentID)
            }
            return "Needs you"
        }

        if let run = snapshot.docking.first(where: { $0.isRunning }) {
            var line = run.complicationLine()
            if let h = actionableAgents(in: snapshot, now: now).first?.entropyBits {
                line += " H=\(String(format: "%.2f", h))"
            }
            return line
        }

        if let agent = actionableAgents(in: snapshot, now: now).first {
            if agent.activity == .blocked {
                return AgentAttentionCopy.needsYouFocusLine(agentDisplayName: agent.name)
            }
            return agent.compactLine()
        }

        if let media = snapshot.nowPlaying, !media.isIdle, let line = media.compactLine() {
            return line
        }

        return nil
    }

    /// Focus line for Always-On / inline complication: never invents busy idle chrome.
    public static func displayLine(
        in snapshot: ShannonSnapshot,
        now: Date = Date(),
        quiet: String = quietShort
    ) -> String {
        primaryFocusLine(in: snapshot, now: now) ?? quiet
    }
}
