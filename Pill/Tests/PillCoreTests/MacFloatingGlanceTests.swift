import XCTest
@testable import PillCore
import ShannonCore

/// UX-058 — Mac floating glance pure binding (fleet + usage, fail-closed).
final class MacFloatingGlanceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snap(
        id: String,
        status: AgentRunStatus = .idle,
        presence: AgentPresence = .live,
        lastTask: String = "task",
        secondsAgo: TimeInterval = 1
    ) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            id: id,
            displayName: id,
            status: status,
            lastTask: lastTask,
            source: "test",
            updatedAt: now.addingTimeInterval(-secondsAgo),
            resumable: false,
            historyCount: 0,
            presence: presence
        )
    }

    func testEmptyWhenNoAgents() {
        let p = MacFloatingGlance.present(agents: [], now: now)
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.emptyCaption, FloatingGlance.emptyCaption)
    }

    func testFleetLineForActiveAgents() {
        let agents = [
            snap(id: "a", status: .active),
            snap(id: "b", status: .midTask),
        ]
        let p = MacFloatingGlance.present(agents: agents, now: now)
        XCTAssertFalse(p.isEmpty)
        XCTAssertEqual(p.fleetLine, "2 agents need a glance")
        XCTAssertNil(p.usageLine)
    }

    func testUsageOnlyWhenSourced() {
        let agent = snap(id: "a", status: .active)
        let usage: [String: AgentUsageSnapshot] = [
            "a": UsageSnapshot(contextPercent: 42),
        ]
        let p = MacFloatingGlance.present(
            agents: [agent],
            usageByAgent: usage,
            now: now
        )
        XCTAssertEqual(p.fleetLine, "1 working")
        XCTAssertEqual(p.usageLine, "ctx 42%")
    }

    func testNoUsageInventedWithoutMap() {
        let agent = snap(id: "a", status: .active)
        let p = MacFloatingGlance.present(agents: [agent], now: now)
        XCTAssertNil(p.usageLine)
    }

    func testPendingAskElevatesNeedsYou() {
        let agent = snap(id: "a", status: .idle)
        let ask = GateDBReader.PendingAsk(
            interactionId: "i1",
            agentId: "a",
            prompt: "Approve?",
            createdAt: now
        )
        let p = MacFloatingGlance.present(
            agents: [agent],
            pendingAsks: [ask],
            now: now
        )
        XCTAssertEqual(p.fleetLine, "1 needs you")
    }

    func testWindowPolicyAlwaysOnTopDefaults() {
        XCTAssertTrue(FloatingGlanceWindowPolicy.isAlwaysOnTopLevel(
            FloatingGlanceWindowPolicy.windowLevelRawValue
        ))
        XCTAssertFalse(FloatingGlanceWindowPolicy.canBecomeKey)
        XCTAssertFalse(FloatingGlanceWindowPolicy.hidesOnDeactivate)
        XCTAssertTrue(FloatingGlanceWindowPolicy.joinsAllSpaces)
        XCTAssertGreaterThan(FloatingGlanceWindowPolicy.defaultWidth, 0)
        XCTAssertGreaterThan(FloatingGlanceWindowPolicy.defaultHeight, 0)
    }
}
