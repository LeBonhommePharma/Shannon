import XCTest
@testable import ShannonCore

/// UX-006 — phone list skim density matches Mac multi-agent collapsed semantics.
final class AgentListSkimTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testActiveFleetNeedsYouAndWorkingOnly() {
        XCTAssertTrue(AgentListSkim.isActiveFleet(activity: .blocked))
        XCTAssertTrue(AgentListSkim.isActiveFleet(activity: .running))
        XCTAssertTrue(
            AgentListSkim.isActiveFleet(activity: .idle, hasPendingConfirmation: true)
        )
        XCTAssertFalse(AgentListSkim.isActiveFleet(activity: .finished))
        XCTAssertFalse(AgentListSkim.isActiveFleet(activity: .idle))
        XCTAssertFalse(AgentListSkim.isActiveFleet(activity: .errored))
    }

    func testActiveFleetCountAndMultiAgentLabel() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(id: "a", name: "A", activity: .running, updatedAt: now),
                AgentState(id: "b", name: "B", activity: .blocked, updatedAt: now),
                AgentState(id: "c", name: "C", activity: .finished, updatedAt: now),
                AgentState(id: "d", name: "D", activity: .idle, updatedAt: now),
            ],
            capturedAt: now
        )
        XCTAssertEqual(AgentListSkim.activeFleetCount(in: snap, now: now), 2)
        XCTAssertEqual(AgentListSkim.multiAgentCountLabel(activeCount: 2), "2")
        XCTAssertEqual(AgentListSkim.multiAgentGlanceCaption, "agents need a glance")
        XCTAssertEqual(
            AgentListSkim.multiAgentAccessibilityLabel(activeCount: 2),
            "2 \(AgentListSkim.multiAgentGlanceCaption)"
        )
        XCTAssertEqual(
            AgentListSkim.multiAgentAccessibilityLabel(activeCount: 2),
            "2 agents need a glance"
        )
        XCTAssertNil(AgentListSkim.multiAgentCountLabel(activeCount: 1))
        XCTAssertNil(AgentListSkim.multiAgentCountLabel(activeCount: 0))
        XCTAssertNil(AgentListSkim.multiAgentAccessibilityLabel(activeCount: 1))
    }

    func testPendingConfirmationElevatesFleetCount() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(id: "idle-ask", name: "Idle", activity: .idle, updatedAt: now),
                AgentState(id: "run", name: "Run", activity: .running, updatedAt: now),
            ],
            confirmations: [
                PendingConfirmation(
                    id: "c1",
                    question: "Ship?",
                    agentID: "idle-ask",
                    createdAt: now
                ),
            ],
            capturedAt: now
        )
        XCTAssertEqual(AgentListSkim.activeFleetCount(in: snap, now: now), 2)
    }

    func testSkimLinePrefersLastActionOverTaskTitle() {
        XCTAssertEqual(
            AgentListSkim.skimLine(
                taskTitle: "Very long task that should not win",
                lastAction: "Edited Package.swift"
            ),
            "Edited Package.swift"
        )
    }

    func testSkimLineFallsBackToTaskTitleAndClips() {
        XCTAssertEqual(
            AgentListSkim.skimLine(taskTitle: "Dock 1of6", lastAction: "  "),
            "Dock 1of6"
        )
        let long = String(repeating: "x", count: 80)
        let clipped = AgentListSkim.skimLine(taskTitle: long, lastAction: "")
        XCTAssertNotNil(clipped)
        XCTAssertEqual(clipped?.count, AgentListSkim.skimMaxLength)
        XCTAssertTrue(clipped?.hasSuffix("…") == true)
    }

    func testSkimLineEmptyIsNil() {
        XCTAssertNil(AgentListSkim.skimLine(taskTitle: "", lastAction: ""))
        XCTAssertNil(AgentListSkim.skimLine(taskTitle: "   ", lastAction: "\n"))
    }

    func testRowsRankNeedsYouFirstWithElevatedBadge() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(
                    id: "run",
                    name: "Runner",
                    activity: .running,
                    taskTitle: String(repeating: "task junk ", count: 20),
                    turnCount: 3,
                    lastAction: "Edited core.py",
                    updatedAt: now
                ),
                AgentState(
                    id: "ask",
                    name: "Asker",
                    activity: .idle,
                    taskTitle: "Waiting",
                    turnCount: 1,
                    lastAction: "",
                    updatedAt: now.addingTimeInterval(-60)
                ),
            ],
            confirmations: [
                PendingConfirmation(
                    id: "c1",
                    question: "Approve?",
                    agentID: "ask",
                    createdAt: now
                ),
            ],
            capturedAt: now
        )
        let rows = AgentListSkim.rows(in: snap, now: now)
        XCTAssertEqual(rows.map { $0.id }, ["ask", "run"])
        XCTAssertEqual(rows[0].badge, AgentAttentionCopy.needsYou)
        XCTAssertTrue(rows[0].isNeedsYou)
        XCTAssertEqual(rows[0].attention, AgentAttentionCopy.Kind.needsYou)
        XCTAssertEqual(rows[1].badge, AgentAttentionCopy.working)
        XCTAssertEqual(rows[1].skimLine, "Edited core.py")
        XCTAssertEqual(rows[0].skimLine, "Waiting")
        let longTaskRow = AgentListSkim.row(
            for: AgentState(
                id: "junk",
                name: "Junk",
                activity: .running,
                taskTitle: String(repeating: "task junk ", count: 20),
                lastAction: "",
                updatedAt: now
            )
        )
        XCTAssertEqual(longTaskRow.skimLine?.count, AgentListSkim.skimMaxLength)
        XCTAssertTrue(longTaskRow.skimLine?.hasSuffix("…") == true)
    }

    func testRowDoesNotInventEntropy() {
        let agent = AgentState(
            id: "a",
            name: "A",
            activity: .running,
            entropyBits: nil,
            updatedAt: now
        )
        let row = AgentListSkim.row(for: agent)
        XCTAssertNil(row.entropyLabel)
        XCTAssertEqual(row.badge, "working")
    }

    func testRowKeepsMeasuredEntropyLabel() {
        let agent = AgentState(
            id: "a",
            name: "A",
            activity: .running,
            entropyBits: 2.1,
            entropyDelta: -3.4,
            isCollapsed: true,
            updatedAt: now
        )
        let row = AgentListSkim.row(for: agent)
        XCTAssertEqual(row.entropyLabel, agent.entropyLabel)
        XCTAssertTrue(row.isCollapsed)
    }

    func testPhoneHomeWiresAgentListSkim() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let phone = (try? String(
            contentsOf: root.appendingPathComponent("iOS/Sources/ShannonPhone/HomeView.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            phone.contains("AgentListSkim"),
            "phone HomeView must use AgentListSkim for list density"
        )
        XCTAssertTrue(
            phone.contains("AgentListSkim.rows") || phone.contains("AgentListSkim.row"),
            "phone must build cards from shared skim rows"
        )
        XCTAssertTrue(
            phone.contains("multiAgentCountLabel") || phone.contains("activeFleetCount"),
            "phone must surface multi-agent count when >1 active"
        )
        // UX-055: phone caption must use Core token, not dual hard-coded prose.
        XCTAssertTrue(
            phone.contains("AgentListSkim.multiAgentGlanceCaption"),
            "phone fleet chip must use multiAgentGlanceCaption"
        )
        XCTAssertFalse(
            phone.contains("Text(\"agents need a glance\")"),
            "phone must not hard-code dual agents-need-a-glance caption"
        )

        let mac = (try? String(
            contentsOf: root.appendingPathComponent("Pill/Sources/ShannonPill/PillView.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            mac.contains("multiAgentAccessibilityLabel")
                || mac.contains("multiAgentGlanceCaption"),
            "Mac collapsed fleet help must use AgentListSkim glance token (UX-055)"
        )
        XCTAssertFalse(
            mac.contains("\"\\(collapsedActiveCount) agents need a glance\""),
            "Mac must not hard-code dual agents-need-a-glance help"
        )
    }
}
