import XCTest
@testable import ShannonCore

/// UX-009 — iPad compact (Slide Over) pins needs-you chrome when any pending ask.
final class HubCompactNeedsYouChromeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testShouldPinOnlyWhenCompactAndPendingAsk() {
        XCTAssertTrue(HubCompactNeedsYouChrome.shouldPin(isCompact: true, hasPendingAsk: true))
        XCTAssertFalse(HubCompactNeedsYouChrome.shouldPin(isCompact: true, hasPendingAsk: false))
        XCTAssertFalse(HubCompactNeedsYouChrome.shouldPin(isCompact: false, hasPendingAsk: true))
        XCTAssertFalse(HubCompactNeedsYouChrome.shouldPin(isCompact: false, hasPendingAsk: false))
    }

    func testShouldPinFiltersExpiredConfirmations() {
        let live = PendingConfirmation(
            id: "live", question: "Approve deploy?", agentID: "science",
            createdAt: now, expiresAt: now.addingTimeInterval(600)
        )
        let stale = PendingConfirmation(
            id: "stale", question: "Old?", agentID: "science",
            createdAt: now.addingTimeInterval(-3_600), expiresAt: now.addingTimeInterval(-60)
        )
        XCTAssertTrue(HubCompactNeedsYouChrome.shouldPin(isCompact: true, pendingConfirmations: [live], now: now))
        XCTAssertFalse(HubCompactNeedsYouChrome.shouldPin(isCompact: true, pendingConfirmations: [stale], now: now))
        XCTAssertFalse(HubCompactNeedsYouChrome.shouldPin(isCompact: true, pendingConfirmations: [], now: now))
        XCTAssertFalse(HubCompactNeedsYouChrome.shouldPin(isCompact: false, pendingConfirmations: [live], now: now))
    }

    func testShouldPinFromSnapshot() {
        let snap = ShannonSnapshot(
            agents: [AgentState(id: "a", name: "Claude", activity: .idle, updatedAt: now)],
            confirmations: [
                PendingConfirmation(
                    id: "c1", question: "Ship?", agentID: "a",
                    createdAt: now, expiresAt: now.addingTimeInterval(300)
                ),
            ]
        )
        XCTAssertTrue(HubCompactNeedsYouChrome.shouldPin(isCompact: true, snapshot: snap, now: now))
        XCTAssertFalse(HubCompactNeedsYouChrome.shouldPin(isCompact: false, snapshot: snap, now: now))
        XCTAssertFalse(HubCompactNeedsYouChrome.shouldPin(isCompact: true, snapshot: ShannonSnapshot(), now: now))
    }

    func testNeedsYouAgentsIncludesBlockedAndPending() {
        let agents = [
            AgentState(id: "run", name: "Run", activity: .running, updatedAt: now),
            AgentState(id: "ask", name: "Ask", activity: .idle, updatedAt: now),
            AgentState(id: "block", name: "Block", activity: .blocked, updatedAt: now),
        ]
        let needs = HubCompactNeedsYouChrome.needsYouAgents(from: agents, pendingAgentIDs: ["ask"])
        XCTAssertEqual(needs.map(\.id), ["ask", "block"])
    }

    func testPartitionForDisplayWhenPinning() {
        let agents = [
            AgentState(id: "pin", name: "Pinned", activity: .idle, updatedAt: now),
            AgentState(id: "need", name: "Needs", activity: .blocked, updatedAt: now),
            AgentState(id: "run", name: "Run", activity: .running, updatedAt: now),
        ]
        let (needsYou, rest) = HubCompactNeedsYouChrome.partitionForDisplay(
            agents: agents, pendingAgentIDs: [], pin: true
        )
        XCTAssertEqual(needsYou.map(\.id), ["need"])
        XCTAssertEqual(rest.map(\.id), ["pin", "run"])
    }

    func testPartitionNoReorderWhenNotPinning() {
        let agents = [
            AgentState(id: "a", name: "A", activity: .blocked, updatedAt: now),
            AgentState(id: "b", name: "B", activity: .running, updatedAt: now),
        ]
        let (needsYou, rest) = HubCompactNeedsYouChrome.partitionForDisplay(
            agents: agents, pendingAgentIDs: [], pin: false
        )
        XCTAssertTrue(needsYou.isEmpty)
        XCTAssertEqual(rest.map(\.id), ["a", "b"])
    }

    func testPendingAgentIDsSkipsExpiredAndEmpty() {
        let ids = HubCompactNeedsYouChrome.pendingAgentIDs(
            from: [
                PendingConfirmation(id: "1", question: "Q", agentID: "science",
                                    createdAt: now, expiresAt: now.addingTimeInterval(60)),
                PendingConfirmation(id: "2", question: "Q", agentID: "",
                                    createdAt: now, expiresAt: now.addingTimeInterval(60)),
                PendingConfirmation(id: "3", question: "Q", agentID: "old",
                                    createdAt: now, expiresAt: now.addingTimeInterval(-1)),
            ],
            now: now
        )
        XCTAssertEqual(ids, ["science"])
    }

    func testSectionTitleMatchesAttentionFamily() {
        XCTAssertEqual(HubCompactNeedsYouChrome.sectionTitle, "Needs You")
        XCTAssertTrue(
            HubCompactNeedsYouChrome.sectionTitle.lowercased().contains(AgentAttentionCopy.needsYou)
        )
    }

    func testPadHubWiresCompactNeedsYouPin() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let hub = (try? String(contentsOf: root.appendingPathComponent(
            "iPad/Sources/ShannonPad/Views/AgentHubView.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(hub.contains("HubCompactNeedsYouChrome"),
                      "AgentHubView must use HubCompactNeedsYouChrome for compact pin")
        XCTAssertTrue(hub.contains("shouldPin"),
                      "AgentHubView must gate compact pin via shouldPin")
        let grid = (try? String(contentsOf: root.appendingPathComponent(
            "iPad/Sources/ShannonPad/Views/DashboardGridView.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(grid.contains("pinNeedsYou") || grid.contains("HubCompactNeedsYouChrome"),
                      "DashboardGridView must accept / apply pinNeedsYou for compact elevate")
        XCTAssertTrue(grid.contains("partitionForDisplay") || grid.contains("needsYou"),
                      "DashboardGridView must elevate needs-you band when pinned")
    }
}
