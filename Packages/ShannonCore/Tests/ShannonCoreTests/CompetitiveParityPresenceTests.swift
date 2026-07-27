import XCTest
@testable import ShannonCore

/// Structural pins for competitive category **present** rows in the
/// AgentNotch / AgentPeek / AgentCallout parity inventory (2026-07-26).
///
/// These drive real shipped APIs — fail-closed usage, gate verbs, attention
/// rank, empty-trace copy — so the inventory’s “present” labels cannot rot
/// without a test failure. Does not claim commercial clone depth.
final class CompetitiveParityPresenceTests: XCTestCase {

    /// C5 / C6: gate Approve/Deny + offline copy still ship in Core.
    func testGateAskActionCopyPresentForApprovals() {
        XCTAssertEqual(GateAskActionCopy.approve, "Approve")
        XCTAssertEqual(GateAskActionCopy.deny, "Deny")
        XCTAssertFalse(GateAskActionCopy.macGateOffline.isEmpty)
        XCTAssertFalse(GateAskActionCopy.companionSyncOffline.isEmpty)
        let offline = GateAskActionCopy.macGateAffordance(gateAvailable: false)
        XCTAssertFalse(offline.canInteract)
        XCTAssertEqual(offline.statusMessage, GateAskActionCopy.macGateOffline)
    }

    /// C3: needs-you elevates over idle in attention rank.
    func testAttentionRankNeedsYouElevates() {
        let idle = AgentState(id: "a", name: "A", activity: .idle)
        let working = AgentState(id: "b", name: "B", activity: .running)
        let ranked = [idle, working].rankedForDisplay(pendingAgentIDs: ["a"])
        XCTAssertEqual(ranked.first?.id, "a", "pending needs-you must rank first")
    }

    /// C2: multi-agent glance caption token exists (UX-055).
    func testMultiAgentFleetGlanceCaptionPresent() {
        XCTAssertEqual(AgentListSkim.multiAgentGlanceCaption, "agents need a glance")
        let a11y = AgentListSkim.multiAgentAccessibilityLabel(activeCount: 3)
        XCTAssertEqual(a11y, "3 agents need a glance")
    }

    /// C9 / entropy empty family still shipped (Shannon differentiator + UX-056).
    func testQuietAndEntropyEmptyChromePresent() {
        XCTAssertFalse(CompanionFocusCopy.quietFace.isEmpty)
        XCTAssertFalse(EntropyEmptyTraceCopy.short.isEmpty)
        XCTAssertTrue(EntropyEmptyTraceCopy.detail.hasPrefix("Collecting samples"))
    }

    /// C27 multi-device cadence constants still shared.
    func testMultiDeviceCadencePresent() {
        XCTAssertEqual(MultiDeviceCadence.macPublishInterval, 10)
        XCTAssertEqual(MultiDeviceCadence.companionRefreshInterval, 10)
        XCTAssertEqual(MultiDeviceCadence.worstCaseMissedPushLag, 20)
    }

    /// Pill routes/servers modules still exist on disk (C19–C21 category present).
    func testPillDevServersAndRoutesModulesExist() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in [
            "Pill/Sources/DevServers/DevServer.swift",
            "Pill/Sources/Routes/QuickRoutes.swift",
            "Pill/Sources/Routes/FastActions.swift",
        ] {
            let url = root.appendingPathComponent(rel)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "missing shipped module: \(rel)"
            )
        }
    }

    /// Session readers for works-with residual still registered as source files (C11 partial).
    func testCoreSessionReaderSourcesExist() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for name in [
            "ClaudeCodeSessionReader.swift",
            "CodexSessionReader.swift",
            "CursorSessionReader.swift",
            "CoworkSessionReader.swift",
            "KimiSessionReader.swift",
        ] {
            let url = root.appendingPathComponent("Pill/Sources/AgentReaders/\(name)")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "missing session reader: \(name)"
            )
        }
    }
}
