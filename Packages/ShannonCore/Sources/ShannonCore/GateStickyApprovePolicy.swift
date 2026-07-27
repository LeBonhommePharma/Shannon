import Foundation

// MARK: - Sticky / Always Allow gate policy (ENH-032 / parity G10)

/// Whether UI may offer **Always Allow** for a gate ask.
///
/// AgentPeek shows Always Allow only when the agent/hub offers sticky approve.
/// Shannon’s hub gate protocol is **binary only**:
/// - wire: `approval_response` payload carries `approved: Bool` (+ interaction_id)
/// - DB: `AuditDB.resolve_interaction(id, approved: bool)` → status approved|denied
/// - no session/always/scope field is accepted or persisted
///
/// **Fail-closed (Branch B):** until the hub grows a real sticky mode that
/// actually sticks, `showsAlwaysAllow` is always false. Never paint Always
/// Allow chrome that cannot stick — safety > parity chrome.
public enum GateStickyApprovePolicy: Sendable {

    /// Canonical label if/when sticky is protocol-supported and offered.
    public static let alwaysAllowLabel = "Always Allow"

    /// Audit result for the current hub socket protocol (`hub/shannon_gate.py`).
    /// `false` until the hub accepts and persists a sticky approve mode.
    public static let hubProtocolSupportsStickyApprove = false

    /// Known payload keys agents might use to *offer* sticky approve.
    /// Extracted only for forward-compat; alone they never enable the button.
    public static let stickyOfferKeys: [String] = [
        "always_allow",
        "alwaysAllow",
        "sticky_approve",
        "stickyApprove",
        "allow_always",
        "remember_approve",
        "scope",
    ]

    // MARK: - Capability

    /// UI may show Always Allow only when **both**:
    /// 1. hub protocol can actually stick the decision, and
    /// 2. the ask (or capability bit) explicitly offers sticky.
    ///
    /// Either false → no button. No auto-sticky without user action either —
    /// this helper only gates visibility; sticky would still require a tap.
    public static func showsAlwaysAllow(
        hubProtocolSupportsSticky: Bool = hubProtocolSupportsStickyApprove,
        agentOffersSticky: Bool
    ) -> Bool {
        hubProtocolSupportsSticky && agentOffersSticky
    }

    /// Convenience: evaluate against a raw approval / ask payload.
    ///
    /// With today’s hub (`hubProtocolSupportsStickyApprove == false`), this
    /// always returns `false` even if the payload contains offer-looking keys —
    /// inventing Always Allow without a sticking backend is forbidden.
    public static func showsAlwaysAllow(
        fromPayload payload: [String: Any]?,
        hubProtocolSupportsSticky: Bool = hubProtocolSupportsStickyApprove
    ) -> Bool {
        showsAlwaysAllow(
            hubProtocolSupportsSticky: hubProtocolSupportsSticky,
            agentOffersSticky: agentOffersStickyApprove(fromPayload: payload)
        )
    }

    /// Detect an explicit sticky-offer bit on a payload (forward-compat).
    ///
    /// Truthy only for real boolean `true` or known string tokens
    /// (`"always"`, `"session"`, `"sticky"`). Absent / garbage → false.
    public static func agentOffersStickyApprove(fromPayload payload: [String: Any]?) -> Bool {
        guard let payload else { return false }

        for key in stickyOfferKeys {
            guard let raw = payload[key] else { continue }
            if let b = raw as? Bool, b { return true }
            if let s = raw as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if t == "always" || t == "session" || t == "sticky" || t == "true" || t == "1" {
                    return true
                }
            }
        }
        return false
    }

    /// Keys that must **not** appear on the approval *response* wire until the
    /// hub protocol supports sticky. Used by client shape tests.
    public static let forbiddenStickyResponseKeys: [String] = [
        "always_allow",
        "alwaysAllow",
        "sticky",
        "sticky_approve",
        "stickyApprove",
        "allow_always",
        "remember",
        "scope",
    ]

    /// Pure check: approval response payload invents sticky fields.
    public static func approvalResponseInventsSticky(_ payload: [String: Any]) -> Bool {
        for key in forbiddenStickyResponseKeys {
            if payload[key] != nil { return true }
        }
        return false
    }
}
