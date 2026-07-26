import XCTest
@testable import PillCore

private func snap(
    id: String,
    status: AgentRunStatus = .active,
    presence: AgentPresence = .live,
    secondsAgo: TimeInterval = 1,
    now: Date = Date()
) -> AgentActivitySnapshot {
    AgentActivitySnapshot(
        id: id,
        displayName: AgentStyleCatalog.style(for: id).displayName,
        status: status,
        lastTask: "task",
        source: "test",
        updatedAt: now.addingTimeInterval(-secondsAgo),
        resumable: false,
        historyCount: 0,
        presence: presence
    )
}

final class DesktopCompanionCycleTests: XCTestCase {
    func testClampedIndexEmptyAndBounds() {
        XCTAssertEqual(DesktopCompanionCycle.clampedIndex(3, count: 0), 0)
        XCTAssertEqual(DesktopCompanionCycle.clampedIndex(-1, count: 3), 0)
        XCTAssertEqual(DesktopCompanionCycle.clampedIndex(0, count: 3), 0)
        XCTAssertEqual(DesktopCompanionCycle.clampedIndex(2, count: 3), 2)
        XCTAssertEqual(DesktopCompanionCycle.clampedIndex(99, count: 3), 2)
    }

    func testNextIndexWraps() {
        XCTAssertEqual(DesktopCompanionCycle.nextIndex(after: 0, count: 0), 0)
        XCTAssertEqual(DesktopCompanionCycle.nextIndex(after: 0, count: 1), 0)
        XCTAssertEqual(DesktopCompanionCycle.nextIndex(after: 0, count: 3), 1)
        XCTAssertEqual(DesktopCompanionCycle.nextIndex(after: 1, count: 3), 2)
        XCTAssertEqual(DesktopCompanionCycle.nextIndex(after: 2, count: 3), 0)
        XCTAssertEqual(DesktopCompanionCycle.nextIndex(after: 99, count: 3), 0)
        XCTAssertEqual(DesktopCompanionCycle.nextIndex(after: -1, count: 3), 1)
    }

    func testTopAgentsLimit() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(id: "a", secondsAgo: 1, now: now),
            snap(id: "b", secondsAgo: 2, now: now),
            snap(id: "c", status: .idle, presence: .observed, secondsAgo: 10, now: now),
            snap(id: "d", status: .idle, presence: .observed, secondsAgo: 20, now: now),
        ], scannedAt: now)
        let roster = CompanionRoster.build(from: summary, now: now)
        XCTAssertEqual(DesktopCompanionCycle.topAgents(roster, limit: 0), [])
        XCTAssertEqual(DesktopCompanionCycle.topAgents(roster, limit: 2).count, 2)
        XCTAssertEqual(DesktopCompanionCycle.topAgents(roster, limit: 10).count, roster.count)
        XCTAssertEqual(DesktopCompanionCycle.topAgents(roster).count, min(roster.count, DesktopCompanionCycle.defaultTopN))
    }

    func testResolveSelectedIndexPrefersId() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(id: "chatgpt", status: .idle, presence: .observed, secondsAgo: 90, now: now),
            snap(id: "science", secondsAgo: 1, now: now),
            snap(id: "grok", secondsAgo: 2, now: now),
        ], scannedAt: now)
        let roster = CompanionRoster.build(from: summary, now: now)
        let cycle = DesktopCompanionCycle.topAgents(roster)
        let idx = DesktopCompanionCycle.resolveSelectedIndex(roster: cycle, preferredId: "grok", fallbackIndex: 0)
        XCTAssertEqual(cycle[idx].id, "grok")
        let fallback = DesktopCompanionCycle.resolveSelectedIndex(roster: cycle, preferredId: "missing", fallbackIndex: 1)
        XCTAssertEqual(fallback, DesktopCompanionCycle.clampedIndex(1, count: cycle.count))
    }

    func testPresentSelectedIndexCyclesSecondaryAgent() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(id: "chatgpt", status: .idle, presence: .observed, secondsAgo: 90, now: now),
            snap(id: "science", secondsAgo: 1, now: now),
            snap(id: "grok", secondsAgo: 2, now: now),
        ], scannedAt: now)
        let p0 = DesktopCompanionCycle.present(summary: summary, now: now, selectedIndex: 0)
        let p1 = DesktopCompanionCycle.present(summary: summary, now: now, selectedIndex: 1)
        XCTAssertEqual(p0.presentation.state?.id, "science")
        XCTAssertNotEqual(p0.presentation.state?.id, p1.presentation.state?.id)
        XCTAssertGreaterThanOrEqual(p0.cycleCount, 2)
        var idx = 0
        var seen: [String] = []
        let roster = DesktopCompanionCycle.topAgents(CompanionRoster.build(from: summary, now: now))
        for _ in 0..<roster.count {
            seen.append(roster[idx].id)
            idx = DesktopCompanionCycle.nextIndex(after: idx, count: roster.count)
        }
        XCTAssertEqual(Set(seen).count, roster.count)
        XCTAssertEqual(idx, 0)
    }

    func testPresentPreferredIdStickyAcrossRefresh() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(id: "science", secondsAgo: 1, now: now),
            snap(id: "grok", secondsAgo: 2, now: now),
        ], scannedAt: now)
        let p = DesktopCompanionCycle.present(summary: summary, now: now, selectedIndex: 0, preferredId: "grok")
        XCTAssertEqual(p.presentation.state?.id, "grok")
    }

    func testSelectorExtensionForwardsHelpers() {
        XCTAssertEqual(DesktopCompanionSelector.defaultTopN, DesktopCompanionCycle.defaultTopN)
        XCTAssertEqual(DesktopCompanionSelector.nextIndex(after: 2, count: 3), 0)
        XCTAssertEqual(DesktopCompanionSelector.clampedIndex(9, count: 2), 1)
    }

    func testEmptyRosterPresentResult() {
        let r = DesktopCompanionCycle.present(roster: [], selectedIndex: 3)
        XCTAssertNil(r.presentation.state)
        XCTAssertEqual(r.cycleCount, 0)
        XCTAssertEqual(r.selectedIndex, 0)
        XCTAssertFalse(r.presentation.bubble.claimsWork)
    }
}
