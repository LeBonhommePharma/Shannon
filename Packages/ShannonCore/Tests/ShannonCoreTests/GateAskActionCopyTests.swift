import XCTest
@testable import ShannonCore

/// UX-003 — Approve/Deny affordance parity (Mac gate ↔ phone confirmation).
final class GateAskActionCopyTests: XCTestCase {

    private func pending(
        question: String = "Run migrate?",
        expiresAt: Date? = nil,
        createdAt: Date = Date()
    ) -> PendingConfirmation {
        PendingConfirmation(
            id: "ask-1",
            question: question,
            agentID: "science",
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    func testCanonicalVerbs() {
        XCTAssertEqual(GateAskActionCopy.approve, "Approve")
        XCTAssertEqual(GateAskActionCopy.deny, "Deny")
        XCTAssertEqual(GateAskActionCopy.needsApproval, "needs approval")
    }

    func testCompanionAnswerableWhenSyncOK() {
        let a = GateAskActionCopy.companionAffordance(
            pending: pending(),
            lastError: nil
        )
        XCTAssertTrue(a.canInteract)
        XCTAssertNil(a.statusMessage)
        XCTAssertEqual(a.approveLabel, "Approve")
        XCTAssertEqual(a.denyLabel, "Deny")
    }

    func testCompanionDisablesWhenHubOffline() {
        let a = GateAskActionCopy.companionAffordance(
            pending: pending(),
            lastError: "CKError network"
        )
        XCTAssertFalse(a.canInteract)
        XCTAssertEqual(a.statusMessage, GateAskActionCopy.companionSyncOffline)
        XCTAssertTrue(a.statusMessage?.contains("Hub offline") == true)
        // Must not look silently tappable while offline.
        XCTAssertNotEqual(a.statusMessage, nil)
    }

    func testCompanionDisablesWhenExpired() {
        let now = Date()
        let a = GateAskActionCopy.companionAffordance(
            pending: pending(expiresAt: now.addingTimeInterval(-1), createdAt: now.addingTimeInterval(-100)),
            lastError: nil,
            now: now
        )
        XCTAssertFalse(a.canInteract)
        XCTAssertEqual(a.statusMessage, GateAskActionCopy.promptUnanswerable)
    }

    func testCompanionDisablesWhenEmptyQuestion() {
        let a = GateAskActionCopy.companionAffordance(
            pending: pending(question: "   "),
            lastError: nil
        )
        XCTAssertFalse(a.canInteract)
        XCTAssertEqual(a.statusMessage, GateAskActionCopy.promptUnanswerable)
    }

    func testMacGateOfflineCopy() {
        let a = GateAskActionCopy.macGateAffordance(gateAvailable: false)
        XCTAssertFalse(a.canInteract)
        XCTAssertEqual(a.statusMessage, GateAskActionCopy.macGateOffline)
        XCTAssertEqual(
            a.statusMessage,
            "Hub offline — start the gate to approve from here"
        )
    }

    func testMacGateAvailable() {
        let a = GateAskActionCopy.macGateAffordance(gateAvailable: true)
        XCTAssertTrue(a.canInteract)
        XCTAssertNil(a.statusMessage)
    }

    func testMacGateErrorTakesStatusButSocketGatesInteract() {
        let down = GateAskActionCopy.macGateAffordance(
            gateAvailable: false,
            errorText: "Write to gate failed — retry"
        )
        XCTAssertFalse(down.canInteract)
        XCTAssertEqual(down.statusMessage, "Write to gate failed — retry")

        let up = GateAskActionCopy.macGateAffordance(
            gateAvailable: true,
            errorText: "Write to gate failed — retry"
        )
        XCTAssertTrue(up.canInteract)
        XCTAssertEqual(up.statusMessage, "Write to gate failed — retry")
    }

    func testPhoneWiresSharedCopyNotConfirmVerb() {
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
        XCTAssertTrue(phone.contains("GateAskActionCopy"), "phone must use shared affordance")
        XCTAssertTrue(phone.contains("companionAffordance") || phone.contains("GateAskActionCopy.approve"))
        // Dual-OS Confirm verb must not remain on primary answer buttons.
        XCTAssertFalse(
            phone.contains("title: \"Confirm\""),
            "phone must use Approve (Mac parity), not Confirm"
        )

        let mac = (try? String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/ShannonPill/GateAskCard.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            mac.contains("GateAskActionCopy") || mac.contains("macGateAffordance"),
            "Mac GateAskCard must share offline/action copy"
        )
    }

    /// UX-012: iPad must not hard-code dual-OS "Confirm" on primary approve actions.
    func testPadWiresApproveNotConfirmVerb() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let surfaces = [
            "iPad/Sources/ShannonPad/Views/AgentDetailView.swift",
            "iPad/Sources/ShannonPad/Views/NotificationPanelView.swift",
            "iPad/Sources/ShannonPad/Views/GateCardView.swift",
            "iPad/Sources/ShannonPad/ViewModels/PaletteCatalogue.swift",
        ]
        for rel in surfaces {
            let text = (try? String(
                contentsOf: root.appendingPathComponent(rel),
                encoding: .utf8
            )) ?? ""
            XCTAssertTrue(
                text.contains("GateAskActionCopy"),
                "\(rel) must use GateAskActionCopy"
            )
            XCTAssertFalse(
                text.contains("\"Confirm\""),
                "\(rel) must not hard-code Confirm (use Approve)"
            )
            XCTAssertTrue(
                text.contains("GateAskActionCopy.approve")
                    || text.contains("GateAskActionCopy.deny"),
                "\(rel) must reference shared approve/deny tokens"
            )
        }
    }
}
