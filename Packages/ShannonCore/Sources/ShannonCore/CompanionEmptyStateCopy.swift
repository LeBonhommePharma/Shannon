import Foundation

// MARK: - Fail-closed empty states (phone · pad · watch)

/// Shared empty-screen copy when companions have no agents to show.
///
/// **Fail-closed (UX-002):** a missing CloudKit / hub link must **not** read
/// as quiet healthy idle. Mac already says "hub offline"; phone and pad must
/// use the same conceptual split:
///
/// | Condition              | Tone                         |
/// |------------------------|------------------------------|
/// | `lastError == nil`     | Quiet idle — no work running |
/// | `lastError != nil`     | Hub offline — act on sync    |
///
/// Callers pass only `lastError` from `ShannonStore` (or equivalent). Never
/// invents "healthy" or agent counts.
public enum CompanionEmptyStateCopy: Sendable {

    // MARK: Canonical titles

    /// Quiet empty when sync is fine and nothing is published.
    public static let idleTitle = "No agents running"

    /// Detail under idle title (phone/pad body).
    public static let idleDetail = "Agent state from your Mac appears here."

    /// Fail-closed title when sync/hub is down (matches Mac "Hub offline" family).
    public static let offlineTitle = "Hub offline"

    /// Actionable detail — iCloud is the companion link path, not the gate socket.
    public static let offlineDetail =
        "Can't reach the Mac hub. Check that this device is signed in to iCloud."

    /// Compact chip when content exists but hub is unreachable (phone bottom bar).
    public static let offlineChip = "Hub offline"

    /// Accessibility for the offline chip.
    public static let offlineAccessibility = "Mac hub unreachable"

    // MARK: Resolved content

    public struct Content: Equatable, Sendable {
        public var title: String
        public var detail: String
        /// True when `lastError` was non-nil — UI should use offline chrome.
        public var isOffline: Bool
        /// SF Symbol name for empty illustrations (`moon.zzz` / `icloud.slash`).
        public var systemImage: String

        public init(
            title: String,
            detail: String,
            isOffline: Bool,
            systemImage: String
        ) {
            self.title = title
            self.detail = detail
            self.isOffline = isOffline
            self.systemImage = systemImage
        }
    }

    /// Resolve empty-state copy from store error presence only (fail-closed).
    ///
    /// - Parameter lastError: `ShannonStore.lastError` or nil when last refresh succeeded.
    public static func content(lastError: String?) -> Content {
        if hasSyncError(lastError) {
            return Content(
                title: offlineTitle,
                detail: offlineDetail,
                isOffline: true,
                systemImage: "icloud.slash"
            )
        }
        return Content(
            title: idleTitle,
            detail: idleDetail,
            isOffline: false,
            systemImage: "moon.zzz"
        )
    }

    /// Non-empty technical line for secondary display (pad shows raw store error).
    /// Never used as the primary title — keeps dual-OS title tokens stable.
    public static func technicalDetail(lastError: String?) -> String? {
        guard let raw = lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    /// True when companions must not present a healthy empty roster.
    public static func hasSyncError(_ lastError: String?) -> Bool {
        technicalDetail(lastError: lastError) != nil
    }
}
