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

    /// UX-024: Mac pill quiet header + watch face screen title use quietShort.
    func testMacPillAndWatchScreenWireQuietShort() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let pill = (try? String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/ShannonPill/PillView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            pill.contains("CompanionFocusCopy.quietShort"),
            "Mac pill quiet headerTitle must use CompanionFocusCopy.quietShort"
        )
        XCTAssertFalse(
            pill.contains("return \"Shannon\""),
            "Mac pill must not hard-code dual quiet short literal"
        )

        let watchModel = (try? String(
            contentsOf: root.appendingPathComponent(
                "watchOS/Sources/ShannonWatch/WatchModel.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            watchModel.contains("CompanionFocusCopy.quietShort"),
            "watch face screen title must use CompanionFocusCopy.quietShort"
        )
        XCTAssertFalse(
            watchModel.contains("return \"Shannon\""),
            "watch face title must not hard-code dual quiet short literal"
        )
    }

    /// UX-025: residual glance/menu brand chrome uses quietShort (not dual "Shannon").
    func testGlanceAndMenuBrandChromeWireQuietShort() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let surfaces: [(String, String)] = [
            ("iOS/Sources/ShannonWidget/ShannonWidget.swift", "widget rect header"),
            (
                "watchOS/Sources/ShannonWatchComplication/ShannonComplication.swift",
                "complication quiet brand"
            ),
            ("Pill/Sources/ShannonPill/MenuBarPopoverView.swift", "menu-bar header"),
            ("iOS/Sources/ShannonPhone/HomeView.swift", "phone navigation title"),
        ]
        for (rel, label) in surfaces {
            let text = (try? String(
                contentsOf: root.appendingPathComponent(rel),
                encoding: .utf8
            )) ?? ""
            XCTAssertTrue(
                text.contains("CompanionFocusCopy.quietShort"),
                "\(label) (\(rel)) must use CompanionFocusCopy.quietShort"
            )
            XCTAssertFalse(
                text.contains("Text(\"Shannon\")"),
                "\(label) must not hard-code Text(\"Shannon\")"
            )
            XCTAssertFalse(
                text.contains("navigationTitle(\"Shannon\")"),
                "\(label) must not hard-code navigationTitle Shannon"
            )
        }
    }

    /// UX-026: iPad hub brand chrome uses quietShort (phone Home parity).
    func testPadHubBrandChromeWireQuietShort() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let hub = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/AgentHubView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            hub.contains("CompanionFocusCopy.quietShort"),
            "pad hub brand titles must use CompanionFocusCopy.quietShort"
        )
        XCTAssertFalse(
            hub.contains("navigationTitle(\"Shannon\")"),
            "pad hub must not hard-code navigationTitle Shannon"
        )

        let gate = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/GateCardView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            gate.contains("CompanionFocusCopy.quietShort"),
            "pad GateCard unknown-agent fallback must use quietShort"
        )
        XCTAssertFalse(
            gate.contains("?? \"Shannon\""),
            "pad GateCard must not hard-code dual Shannon agent fallback"
        )

        let notify = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/NotificationPanelView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            notify.contains("CompanionFocusCopy.quietShort"),
            "pad notification unknown-agent fallback must use quietShort"
        )
        XCTAssertFalse(
            notify.contains("?? \"Shannon\""),
            "pad notification must not hard-code dual Shannon agent fallback"
        )
    }
}
