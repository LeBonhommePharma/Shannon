import XCTest
@testable import ShannonCore

/// ENH-032 — Always Allow only when hub sticky policy supports it (parity G10).
///
/// Branch B: hub protocol is binary approve/deny only. Fail-closed — never
/// invent Always Allow chrome that cannot stick.
final class GateStickyApprovePolicyTests: XCTestCase {

    // MARK: - Hub protocol capability (audit pin)

    func testHubProtocolDoesNotSupportStickyApprove() {
        XCTAssertFalse(
            GateStickyApprovePolicy.hubProtocolSupportsStickyApprove,
            "hub/shannon_gate resolve_interaction is binary approved: Bool only"
        )
    }

    func testShowsAlwaysAllowFalseWhenHubUnsupportedEvenIfAgentOffers() {
        XCTAssertFalse(
            GateStickyApprovePolicy.showsAlwaysAllow(
                hubProtocolSupportsSticky: false,
                agentOffersSticky: true
            ),
            "must not show Always Allow when hub cannot stick the decision"
        )
        XCTAssertFalse(
            GateStickyApprovePolicy.showsAlwaysAllow(
                fromPayload: ["always_allow": true]
            ),
            "payload offer alone must not enable Always Allow under current hub"
        )
    }

    func testShowsAlwaysAllowFalseWhenAgentDoesNotOfferEvenIfHubCould() {
        XCTAssertFalse(
            GateStickyApprovePolicy.showsAlwaysAllow(
                hubProtocolSupportsSticky: true,
                agentOffersSticky: false
            ),
            "no auto Always Allow without explicit offer"
        )
    }

    func testShowsAlwaysAllowTrueOnlyWhenBothHubAndAgentSupport() {
        XCTAssertTrue(
            GateStickyApprovePolicy.showsAlwaysAllow(
                hubProtocolSupportsSticky: true,
                agentOffersSticky: true
            )
        )
    }

    func testDefaultHubCapabilityKeepsAlwaysAllowHidden() {
        // Production default: hub unsupported → never show, any agent offer.
        XCTAssertFalse(
            GateStickyApprovePolicy.showsAlwaysAllow(agentOffersSticky: true)
        )
        XCTAssertFalse(
            GateStickyApprovePolicy.showsAlwaysAllow(agentOffersSticky: false)
        )
        XCTAssertFalse(
            GateStickyApprovePolicy.showsAlwaysAllow(fromPayload: nil)
        )
        XCTAssertFalse(
            GateStickyApprovePolicy.showsAlwaysAllow(fromPayload: [:])
        )
    }

    // MARK: - Payload offer extraction (forward-compat only)

    func testAgentOffersStickyFromKnownKeys() {
        for key in GateStickyApprovePolicy.stickyOfferKeys {
            if key == "scope" {
                XCTAssertTrue(
                    GateStickyApprovePolicy.agentOffersStickyApprove(
                        fromPayload: [key: "always"]
                    ),
                    "scope=always should offer sticky"
                )
                XCTAssertFalse(
                    GateStickyApprovePolicy.agentOffersStickyApprove(
                        fromPayload: [key: "once"]
                    ),
                    "scope=once is not sticky"
                )
                continue
            }
            XCTAssertTrue(
                GateStickyApprovePolicy.agentOffersStickyApprove(
                    fromPayload: [key: true]
                ),
                "key \(key)=true should offer sticky"
            )
        }
    }

    func testAgentDoesNotOfferStickyOnGarbage() {
        XCTAssertFalse(
            GateStickyApprovePolicy.agentOffersStickyApprove(
                fromPayload: ["always_allow": false]
            )
        )
        XCTAssertFalse(
            GateStickyApprovePolicy.agentOffersStickyApprove(
                fromPayload: ["always_allow": "maybe"]
            )
        )
        XCTAssertFalse(
            GateStickyApprovePolicy.agentOffersStickyApprove(
                fromPayload: ["prompt": "please always allow this"]
            ),
            "must not invent offer from prose"
        )
        XCTAssertFalse(
            GateStickyApprovePolicy.agentOffersStickyApprove(
                fromPayload: ["text": "Always Allow"]
            )
        )
    }

    // MARK: - Response wire: no invented sticky fields

    func testApprovalResponseMustNotInventStickyFields() {
        let binary: [String: Any] = [
            "target_agent": "science",
            "approved": true,
            "interaction_id": "ask-1",
            "source": "pill_ui",
            "kind": "approval_response",
        ]
        XCTAssertFalse(
            GateStickyApprovePolicy.approvalResponseInventsSticky(binary)
        )

        for key in GateStickyApprovePolicy.forbiddenStickyResponseKeys {
            var bad = binary
            bad[key] = true
            XCTAssertTrue(
                GateStickyApprovePolicy.approvalResponseInventsSticky(bad),
                "response must not invent sticky key \(key) without hub support"
            )
        }
    }

    // MARK: - Structural: Mac gate cards do not ship fake Always Allow

    func testMacGateCardsDoNotHardcodeAlwaysAllow() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let cards = [
            "Pill/Sources/ShannonPill/GateAskCard.swift",
            "Pill/Sources/ShannonPill/GateInlineCard.swift",
        ]
        for rel in cards {
            let text = (try? String(
                contentsOf: root.appendingPathComponent(rel),
                encoding: .utf8
            )) ?? ""
            XCTAssertFalse(
                text.isEmpty,
                "expected source at \(rel)"
            )
            XCTAssertFalse(
                text.contains("Always Allow"),
                "\(rel) must not hard-code Always Allow (hub cannot stick)"
            )
            XCTAssertFalse(
                text.contains(GateStickyApprovePolicy.alwaysAllowLabel)
                    && text.contains("answerButton"),
                "\(rel) must not wire Always Allow button without hub sticky support"
            )
        }
    }

    func testGateApprovalClientPayloadDoesNotInventSticky() {
        // Read GateApprovalClient source: approvalPayload builder must stay binary.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let client = (try? String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/PillCore/GateApprovalClient.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertFalse(client.isEmpty, "GateApprovalClient.swift must exist")
        for key in ["always_allow", "alwaysAllow", "sticky_approve", "stickyApprove"] {
            XCTAssertFalse(
                client.contains("\"\(key)\""),
                "GateApprovalClient must not put sticky key \(key) on the wire"
            )
        }
        XCTAssertTrue(
            client.contains("\"approved\""),
            "GateApprovalClient must keep binary approved field"
        )
    }

    func testAlwaysAllowLabelIsDefinedForFutureBranchA() {
        XCTAssertEqual(GateStickyApprovePolicy.alwaysAllowLabel, "Always Allow")
        XCTAssertFalse(GateStickyApprovePolicy.alwaysAllowLabel.isEmpty)
    }
}
