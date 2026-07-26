import XCTest
@testable import PillCore

/// Multi-surface identity for macOS HUD + menu bar (SharedTelemetry) aligned
/// with ShannonCore GlobalNotifyResponse wording for “needs you”.
final class GlobalNotifyMultiSurfaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    func testMacConsumersAgreeOnNeedsYouAndFocus() {
        let agent = AgentActivitySnapshot(
            id: "claude_code",
            displayName: "Claude Code",
            status: .midTask,
            lastTask: "awaiting",
            source: "gate",
            updatedAt: now.addingTimeInterval(-5),
            resumable: true,
            historyCount: 1,
            presence: .live
        )
        let ask = GateDBReader.PendingAsk(
            interactionId: "gate-ask-1",
            agentId: "claude_code",
            prompt: "Run npm migrate?",
            createdAt: now.addingTimeInterval(-2)
        )
        let snap = SharedTelemetrySnapshot.capture(
            agents: [agent],
            pendingAsks: [ask],
            agentEntropy: [],
            bridgeConnected: false,
            bridgeStatus: nil,
            gateAvailable: true,
            scannedAt: now
        )
        // Two chrome consumers freeze the same snapshot.
        XCTAssertTrue(SharedTelemetryBinding.consumersAgree([snap, snap], now: now))
        let views = SharedTelemetryBinding.agentViews(in: snap, now: now)
        XCTAssertEqual(views["claude_code"]?.needsYou, true)
        XCTAssertEqual(views["claude_code"]?.attention, .needsYou)
        let focus = SharedTelemetryBinding.primaryFocus(in: snap, now: now)
        XCTAssertEqual(focus, "Needs you · Claude Code")
    }

    func testNotifierAskContentDoesNotInventAgentWhenAbsent() {
        let c = ShannonNotifier.notificationContent(kind: .ask)
        XCTAssertEqual(c.title, "Approval needed")
        XCTAssertFalse(c.body.isEmpty)
        // With agent: title uses “needs you” family (same as GlobalNotifyResponse).
        // Pure content path via notifyAsk builders — title override.
        let withBody = ShannonNotifier.notificationContent(
            kind: .ask, title: "claude_code needs you", body: "Approve?"
        )
        XCTAssertTrue(withBody.title.contains("needs you"))
        XCTAssertEqual(withBody.body, "Approve?")
    }
}
