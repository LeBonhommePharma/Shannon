import Foundation

// MARK: - Approve / Deny affordance (multi-OS)

/// Canonical primary-action copy and enablement for gate / confirmation asks.
///
/// **UX-003:** Mac `GateAskCard` and phone confirmation banner must agree on
/// Approve/Deny verbs and must not look tappable when the answer cannot land
/// (gate socket down on Mac; CloudKit/hub offline on companions).
///
/// Fail-closed: unknown/expired prompts and offline hubs disable interaction
/// and surface an honest status line — never invent success.
public enum GateAskActionCopy: Sendable {

    // MARK: Canonical verbs (Mac GateAskCard family)

    public static let approve = "Approve"
    public static let deny = "Deny"

    /// Capsule over the ask (Mac gate cards). Distinct from badge "needs you".
    public static let needsApproval = "needs approval"

    // MARK: Disabled / offline status lines

    /// Mac: local gate Unix socket missing — approvals would fail on tap.
    public static let macGateOffline =
        "Hub offline — start the gate to approve from here"

    /// Companion: CloudKit/hub unreachable — answer cannot write back.
    public static let companionSyncOffline =
        "Hub offline — open the Mac to approve, or fix iCloud"

    /// Expired or empty question — `GlobalNotifyResponse.canAnswer` is false.
    public static let promptUnanswerable =
        "This prompt is no longer answerable"

    /// In-flight answer (Mac gate cards + watch gate status).
    public static let sending = "Sending…"

    /// Phone/Mac acknowledged the answer (watch face + gate status — UX-023).
    public static let sent = "Sent ✓"

    /// Phone unreachable; system will deliver later (watch delivery chrome).
    public static let queuedForPhone = "Queued — delivers when iPhone is back"

    /// Compact menu-bar roster tertiary hint when an ask is answerable (UX-027).
    /// Distinct from full-width Approve buttons — density-preserving, same verb root.
    public static let rosterApproveHint = "Gate · approve"

    /// Accessibility when `rosterApproveHint` is shown.
    public static let rosterApproveAccessibility = "Gate approve available"

    // MARK: Affordance resolution

    /// Resolved UI policy for one ask surface.
    public struct Affordance: Equatable, Sendable {
        /// When false, Approve/Deny must be disabled (or omitted).
        public var canInteract: Bool
        /// Inline status when the user cannot (or should not) tap.
        public var statusMessage: String?
        public var approveLabel: String
        public var denyLabel: String

        public init(
            canInteract: Bool,
            statusMessage: String? = nil,
            approveLabel: String = GateAskActionCopy.approve,
            denyLabel: String = GateAskActionCopy.deny
        ) {
            self.canInteract = canInteract
            self.statusMessage = statusMessage
            self.approveLabel = approveLabel
            self.denyLabel = denyLabel
        }
    }

    /// Phone / pad / watch: answer path is CloudKit write-back.
    ///
    /// - Parameters:
    ///   - pending: Mirrored confirmation.
    ///   - lastError: `ShannonStore.lastError` (nil = last sync OK).
    ///   - now: Clock for expiry (injectable in tests).
    public static func companionAffordance(
        pending: PendingConfirmation,
        lastError: String?,
        now: Date = Date()
    ) -> Affordance {
        if !GlobalNotifyResponse.canAnswer(pending, now: now) {
            return Affordance(canInteract: false, statusMessage: promptUnanswerable)
        }
        if CompanionEmptyStateCopy.hasSyncError(lastError) {
            return Affordance(canInteract: false, statusMessage: companionSyncOffline)
        }
        return Affordance(canInteract: true, statusMessage: nil)
    }

    /// Mac notch / popover: answer path is local gate socket.
    ///
    /// - Parameters:
    ///   - gateAvailable: Gate Unix socket present.
    ///   - errorText: Last resolve failure (takes precedence for status line).
    public static func macGateAffordance(
        gateAvailable: Bool,
        errorText: String? = nil
    ) -> Affordance {
        let trimmed = errorText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            // Error shown, but only re-enable if the socket is back.
            return Affordance(
                canInteract: gateAvailable,
                statusMessage: trimmed
            )
        }
        if !gateAvailable {
            return Affordance(canInteract: false, statusMessage: macGateOffline)
        }
        return Affordance(canInteract: true, statusMessage: nil)
    }
}
