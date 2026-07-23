import XCTest
@testable import PillCore

/// The pill's write path to the gate.
///
/// The socket call itself needs a live gate, so these cover the part that can be
/// got wrong silently: the exact shape of the two lines the client puts on the
/// wire. `hub/tests/test_hub_ui_actions.py` proves the equivalent envelope
/// actually resolves an interaction against a real gate.
final class GateApprovalClientTests: XCTestCase {

    func testRegistrationUsesTheReservedLocalUIAgentId() {
        let reg = GateApprovalClient.registrationPayload()
        // The gate rejects any peer whose agent_id is not in VALID_AGENTS.
        XCTAssertEqual(reg["agent_id"] as? String, "local_test")
        XCTAssertEqual(reg["task_id"] as? String, "pill_ui")
    }

    func testApprovalPayloadCarriesTheGateInteractionId() {
        let p = GateApprovalClient.approvalPayload(
            interactionId: "ask-science-42", agentId: "science", approved: true
        )
        XCTAssertEqual(p["message_type"] as? String, "approval_response")
        let inner = p["payload"] as? [String: Any]
        XCTAssertEqual(inner?["interaction_id"] as? String, "ask-science-42")
        XCTAssertEqual(inner?["target_agent"] as? String, "science")
        XCTAssertEqual(inner?["approved"] as? Bool, true)
    }

    func testDenialIsDistinctFromApproval() {
        let denied = GateApprovalClient.approvalPayload(
            interactionId: "ask-1", agentId: "codex", approved: false
        )
        let inner = denied["payload"] as? [String: Any]
        XCTAssertEqual(inner?["approved"] as? Bool, false)
    }

    /// The gate's approval branch fires on message_type plus either an
    /// "approved" field or kind == "approval_response". Carrying both means the
    /// envelope cannot be misrouted as an ordinary broadcast.
    func testPayloadSatisfiesBothGateApprovalPredicates() {
        let p = GateApprovalClient.approvalPayload(
            interactionId: "ask-2", agentId: "cowork", approved: true
        )
        let inner = p["payload"] as? [String: Any]
        XCTAssertNotNil(inner?["approved"], "gate checks for an 'approved' key")
        XCTAssertEqual(inner?["kind"] as? String, "approval_response")
    }

    func testPayloadIsJSONSerialisable() {
        let p = GateApprovalClient.approvalPayload(
            interactionId: "ask-3", agentId: "science", approved: true
        )
        XCTAssertTrue(JSONSerialization.isValidJSONObject(p))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: p))
    }

    func testResolveFailsCleanlyWhenNoSocketExists() {
        // A missing gate must surface an error, never look like a success —
        // otherwise the pill would clear an ask nobody answered.
        XCTAssertThrowsError(
            try GateApprovalClient.resolve(
                interactionId: "ask-4",
                agentId: "science",
                approved: true,
                socketPath: "/tmp/shannon-nonexistent-\(UUID().uuidString).sock"
            )
        ) { error in
            XCTAssertEqual(error as? GateApprovalClient.ApprovalError, .socketUnavailable)
        }
    }
}
