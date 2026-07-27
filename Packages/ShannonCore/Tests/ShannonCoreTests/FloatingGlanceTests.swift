import XCTest
@testable import ShannonCore

/// UX-058 — Mac floating glance pure presenter (fleet skim + optional usage).
final class FloatingGlanceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Empty / fail-closed

    func testEmptyWhenNoFleetAndNoUsage() {
        let p = FloatingGlance.present(activeFleetCount: 0)
        XCTAssertTrue(p.isEmpty)
        XCTAssertNil(p.fleetLine)
        XCTAssertNil(p.usageLine)
        XCTAssertEqual(p.emptyCaption, FloatingGlance.emptyCaption)
        XCTAssertEqual(p.accessibilityLabel, FloatingGlance.emptyCaption)
        XCTAssertTrue(p.displayLines.isEmpty)
    }

    func testBlankUsageLabelIsNotInvented() {
        let p = FloatingGlance.present(
            activeFleetCount: 0,
            usageLabel: "   "
        )
        XCTAssertTrue(p.isEmpty)
        XCTAssertNil(p.usageLine)
    }

    func testNegativeCountsClampToEmptyFleet() {
        let p = FloatingGlance.present(activeFleetCount: -3, needsYouCount: -1)
        XCTAssertTrue(p.isEmpty)
        XCTAssertNil(p.fleetLine)
    }

    // MARK: Fleet lines share AgentListSkim / attention vocabulary

    func testMultiAgentFleetLineUsesSkimCaption() {
        let p = FloatingGlance.present(activeFleetCount: 3)
        XCTAssertEqual(
            p.fleetLine,
            AgentListSkim.multiAgentAccessibilityLabel(activeCount: 3)
        )
        XCTAssertEqual(p.fleetLine, "3 agents need a glance")
        XCTAssertFalse(p.isEmpty)
        XCTAssertEqual(p.displayLines, ["3 agents need a glance"])
    }

    func testSingleWorkingFleetLine() {
        let p = FloatingGlance.present(activeFleetCount: 1, needsYouCount: 0)
        XCTAssertEqual(p.fleetLine, "1 \(AgentAttentionCopy.working)")
        XCTAssertEqual(p.fleetLine, "1 working")
    }

    func testSingleNeedsYouFleetLine() {
        let p = FloatingGlance.present(activeFleetCount: 1, needsYouCount: 1)
        XCTAssertEqual(p.fleetLine, "1 \(AgentAttentionCopy.needsYou)")
        XCTAssertEqual(p.fleetLine, "1 needs you")
    }

    func testNeedsYouDoesNotFabricateFleetWhenCountZero() {
        // needsYou without active fleet is inconsistent input — still fail-closed.
        let p = FloatingGlance.present(activeFleetCount: 0, needsYouCount: 2)
        XCTAssertNil(p.fleetLine)
        XCTAssertTrue(p.isEmpty)
    }

    // MARK: Usage when real

    func testUsageLineOnlyWhenSourced() {
        let with = FloatingGlance.present(
            activeFleetCount: 2,
            usageLabel: "ctx 42%"
        )
        XCTAssertEqual(with.usageLine, "ctx 42%")
        XCTAssertEqual(with.displayLines, ["2 agents need a glance", "ctx 42%"])
        XCTAssertEqual(with.accessibilityLabel, "2 agents need a glance. ctx 42%")

        let usageOnly = FloatingGlance.present(
            activeFleetCount: 0,
            usageLabel: "1200 tok"
        )
        XCTAssertTrue(usageOnly.fleetLine == nil)
        XCTAssertEqual(usageOnly.usageLine, "1200 tok")
        XCTAssertFalse(usageOnly.isEmpty)
        XCTAssertEqual(usageOnly.displayLines, ["1200 tok"])
    }

    // MARK: Snapshot path

    func testPresentFromSnapshot() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(id: "a", name: "A", activity: .running, updatedAt: now),
                AgentState(id: "b", name: "B", activity: .blocked, updatedAt: now),
                AgentState(id: "c", name: "C", activity: .idle, updatedAt: now),
            ],
            confirmations: [],
            capturedAt: now
        )
        let p = FloatingGlance.present(snapshot: snap, now: now)
        // active fleet = running + blocked = 2
        XCTAssertEqual(p.fleetLine, "2 agents need a glance")
        XCTAssertNil(p.usageLine)

        let withUsage = FloatingGlance.present(
            snapshot: snap,
            usageLabel: "ctx 10%",
            now: now
        )
        XCTAssertEqual(withUsage.usageLine, "ctx 10%")
    }

    func testPresentFromSnapshotElevatesPendingNeedsYou() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(id: "idle", name: "Idle", activity: .idle, updatedAt: now),
            ],
            confirmations: [
                PendingConfirmation(
                    id: "c1", question: "Approve?", agentID: "idle",
                    createdAt: now, expiresAt: now.addingTimeInterval(600)
                ),
            ],
            capturedAt: now
        )
        let p = FloatingGlance.present(snapshot: snap, now: now)
        XCTAssertEqual(p.fleetLine, "1 needs you")
    }

    // MARK: Chrome tokens

    func testChromeTokensStable() {
        XCTAssertEqual(FloatingGlance.title, "Fleet")
        XCTAssertEqual(FloatingGlance.usageTitle, "Usage")
        XCTAssertEqual(FloatingGlance.accessibilityIdentifier, "floatingGlance")
        XCTAssertFalse(FloatingGlance.emptyCaption.isEmpty)
    }
}
