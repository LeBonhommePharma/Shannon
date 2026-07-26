import XCTest
@testable import ShannonCore

/// UX-005 — watch / companion primary focus only when actionable.
final class CompanionFocusCopyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testQuietWhenEmpty() {
        let snap = ShannonSnapshot()
        XCTAssertNil(CompanionFocusCopy.primaryFocusLine(in: snap, now: now))
        XCTAssertEqual(
            CompanionFocusCopy.displayLine(in: snap, now: now),
            CompanionFocusCopy.quietShort
        )
        XCTAssertEqual(snap.complicationLine(now: now), "Shannon")
        XCTAssertEqual(snap.primaryFocusLine(now: now), nil)
    }

    func testIdleAgentDoesNotInventBusyChrome() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(id: "idle", name: "Quiet", activity: .idle, updatedAt: now),
            ]
        )
        XCTAssertNil(CompanionFocusCopy.primaryFocusLine(in: snap, now: now))
        XCTAssertEqual(snap.complicationLine(now: now), "Shannon")
        XCTAssertTrue(CompanionFocusCopy.actionableAgents(in: snap, now: now).isEmpty)
        XCTAssertFalse(CompanionFocusCopy.isActionable(snap.agents[0]))
    }

    func testRunningAgentIsActionable() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(id: "r", name: "Run", activity: .running, turnCount: 3, updatedAt: now),
            ]
        )
        let line = CompanionFocusCopy.primaryFocusLine(in: snap, now: now)
        XCTAssertEqual(line, snap.agents[0].compactLine())
        XCTAssertTrue(line?.contains("Run") == true)
    }

    func testNeedsYouFocusFromPendingAndBlocked() {
        let pending = ShannonSnapshot(
            agents: [
                AgentState(id: "a", name: "Claude", activity: .idle, updatedAt: now),
            ],
            confirmations: [
                PendingConfirmation(
                    id: "c1",
                    question: "Ship it?",
                    agentID: "a",
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(600)
                ),
            ]
        )
        XCTAssertEqual(
            CompanionFocusCopy.primaryFocusLine(in: pending, now: now),
            "? Ship it?"
        )

        let blocked = ShannonSnapshot(
            agents: [
                AgentState(id: "b", name: "Science", activity: .blocked, updatedAt: now),
            ]
        )
        XCTAssertEqual(
            CompanionFocusCopy.primaryFocusLine(in: blocked, now: now),
            AgentAttentionCopy.needsYouFocusLine(agentDisplayName: "Science")
        )
    }

    func testCollapsedIdleIsActionable() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(
                    id: "c",
                    name: "Gate",
                    activity: .idle,
                    entropyBits: 2.1,
                    isCollapsed: true,
                    updatedAt: now
                ),
            ]
        )
        XCTAssertTrue(CompanionFocusCopy.isActionable(snap.agents[0]))
        XCTAssertNotNil(CompanionFocusCopy.primaryFocusLine(in: snap, now: now))
    }

    func testQuietFaceTokenMatchesMacFamily() {
        XCTAssertEqual(CompanionFocusCopy.quietFace, "Shannon · idle")
        XCTAssertTrue(CompanionFocusCopy.quietFace.contains("idle"))
    }

    /// UX-017: Mac collapsed quiet path must share Core quietFace (not dual literal).
    func testMacCollapsedStatusWiresQuietFace() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let presenter = (try? String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/PillCore/SessionContentPresenter.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            presenter.contains("CompanionFocusCopy.quietFace"),
            "Mac collapsedStatusLine must use CompanionFocusCopy.quietFace"
        )
        XCTAssertFalse(
            presenter.contains("return \"Shannon · idle\""),
            "Mac presenter must not hard-code dual quiet-face literal"
        )
    }

    func testWatchFaceWiresCompanionFocusCopy() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let face = (try? String(
            contentsOf: root.appendingPathComponent(
                "watchOS/Sources/ShannonWatch/ShannonFaceView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(face.contains("CompanionFocusCopy"), "watch face must use shared focus")
        XCTAssertTrue(face.contains("quietFace") || face.contains("actionableAgents"))
    }
}
