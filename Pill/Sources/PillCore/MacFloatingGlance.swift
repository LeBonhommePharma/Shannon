// MacFloatingGlance.swift — pure Mac fleet/usage glance from live activity (UX-058).
//
// Composes AgentLiveSurfaceLogic fleet counts + SessionContentPresenter usage
// chip into ShannonCore FloatingGlancePresentation. Fail-closed: no invented
// tokens or quotas.

import Foundation
import ShannonCore

/// Pure Mac binding from gate activity → floating glance content.
public enum MacFloatingGlance: Sendable {

    /// Build glance presentation from local observations only.
    ///
    /// - Usage line uses primary-agent chip only (`collapsedUsageChip`) — never
    ///   scavenges secondary agents for density (same honesty as notch ENH-012).
    public static func present(
        agents: [AgentActivitySnapshot],
        pendingAsks: [GateDBReader.PendingAsk] = [],
        activity: [GateDBReader.ActivityEvent] = [],
        usageByAgent: [String: AgentUsageSnapshot] = [:],
        now: Date = Date()
    ) -> FloatingGlancePresentation {
        let fleet = AgentLiveSurfaceLogic.fleet(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: usageByAgent,
            now: now,
            limit: max(4, agents.count)
        )
        let active = fleet.filter {
            $0.attention == .needsYou || $0.attention == .working
        }.count
        let needsYou = fleet.filter { $0.attention == .needsYou }.count
        let usage = SessionContentPresenter.collapsedUsageChip(
            agents: agents,
            pendingAsks: pendingAsks,
            activity: activity,
            usageByAgent: usageByAgent,
            now: now
        )
        return FloatingGlance.present(
            activeFleetCount: active,
            needsYouCount: needsYou,
            usageLabel: usage
        )
    }
}
