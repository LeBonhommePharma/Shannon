// DesktopCompanionCycle.swift — pure multi-agent desktop pet selection (E3).
import Foundation

/// Pure selection helpers for multi-agent desktop companion cycling / stacking.
public enum DesktopCompanionCycle: Sendable {
    public static let defaultTopN = 5

    public static func clampedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        if index < 0 { return 0 }
        if index >= count { return count - 1 }
        return index
    }

    public static func nextIndex(after current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let base = clampedIndex(current, count: count)
        return (base + 1) % count
    }

    public static func topAgents(
        _ roster: [CompanionState],
        limit: Int = defaultTopN
    ) -> [CompanionState] {
        guard limit > 0 else { return [] }
        return Array(roster.prefix(limit))
    }

    public static func resolveSelectedIndex(
        roster: [CompanionState],
        preferredId: String?,
        fallbackIndex: Int = 0
    ) -> Int {
        if let preferredId,
           let i = roster.firstIndex(where: { $0.id == preferredId }) {
            return i
        }
        return clampedIndex(fallbackIndex, count: roster.count)
    }

    public struct PresentResult: Sendable, Equatable {
        public let presentation: DesktopCompanionPresentation
        public let selectedIndex: Int
        public let cycleCount: Int
        public init(presentation: DesktopCompanionPresentation, selectedIndex: Int, cycleCount: Int) {
            self.presentation = presentation
            self.selectedIndex = selectedIndex
            self.cycleCount = cycleCount
        }
    }

    public static func present(
        roster: [CompanionState],
        selectedIndex: Int = 0,
        preferredId: String? = nil,
        cycleLimit: Int = defaultTopN,
        packagePetId: String? = nil
    ) -> PresentResult {
        let cycle = topAgents(roster, limit: cycleLimit)
        let idx = resolveSelectedIndex(roster: cycle, preferredId: preferredId, fallbackIndex: selectedIndex)
        let slice: [CompanionState] = cycle.isEmpty ? [] : [cycle[idx]]
        let presentation = DesktopCompanionSelector.present(
            roster: slice,
            packagePetId: packagePetId ?? PetPackageResolver.defaultPetId
        )
        return PresentResult(presentation: presentation, selectedIndex: idx, cycleCount: cycle.count)
    }

    public static func present(
        summary: AgentActivitySummary,
        now: Date = Date(),
        approvals: [String: Date] = [:],
        entropyDeltas: [String: Double] = [:],
        entropyDelta: Double? = nil,
        pendingAsks: [GateDBReader.PendingAsk] = [],
        lastOutcomes: [String: String] = [:],
        activity: [GateDBReader.ActivityEvent] = [],
        selectedIndex: Int = 0,
        preferredId: String? = nil,
        cycleLimit: Int = defaultTopN,
        packagePetId: String? = nil
    ) -> PresentResult {
        let full = CompanionRoster.build(
            from: summary, now: now, approvals: approvals,
            entropyDeltas: entropyDeltas, entropyDelta: entropyDelta,
            pendingAsks: pendingAsks, lastOutcomes: lastOutcomes, activity: activity
        )
        return present(
            roster: full, selectedIndex: selectedIndex, preferredId: preferredId,
            cycleLimit: cycleLimit, packagePetId: packagePetId
        )
    }
}

extension DesktopCompanionSelector {
    public static var defaultTopN: Int { DesktopCompanionCycle.defaultTopN }
    public static func clampedIndex(_ index: Int, count: Int) -> Int {
        DesktopCompanionCycle.clampedIndex(index, count: count)
    }
    public static func nextIndex(after current: Int, count: Int) -> Int {
        DesktopCompanionCycle.nextIndex(after: current, count: count)
    }
    public static func topAgents(_ roster: [CompanionState], limit: Int = DesktopCompanionCycle.defaultTopN) -> [CompanionState] {
        DesktopCompanionCycle.topAgents(roster, limit: limit)
    }
    public static func resolveSelectedIndex(roster: [CompanionState], preferredId: String?, fallbackIndex: Int = 0) -> Int {
        DesktopCompanionCycle.resolveSelectedIndex(roster: roster, preferredId: preferredId, fallbackIndex: fallbackIndex)
    }
}
