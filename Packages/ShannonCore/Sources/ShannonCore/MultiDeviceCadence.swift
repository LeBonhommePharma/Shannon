import Foundation

// MARK: - Multi-device publish / refresh cadence

/// Shared Mac → companion timing budget (local CloudKit private zone + WC relay).
///
/// Worst-case lag without silent push ≈ ``macPublishInterval`` + ``companionRefreshInterval``.
/// ``ShannonPublisher`` still suppresses unchanged records so shorter companion polls
/// do not burn the CloudKit request quota when nothing changed.
///
/// CloudKit multi-device sync is **Apple-only** (macOS hub → iPhone → Watch).
/// Windows / Linux get the science library + installer, not this cadence path.
public enum MultiDeviceCadence: Sendable {
    /// Mac `CloudPublisher` timer (seconds). Documented in MULTI_DEVICE.md (~10 s).
    public static let macPublishInterval: TimeInterval = 10

    /// Phone / pad `ShannonStore` safety-net refresh when push is missed.
    /// Must not exceed the Mac publish interval by a large factor — a 30 s poll
    /// after a 10 s publish added an unnecessary ~20 s floor to approvals.
    public static let companionRefreshInterval: TimeInterval = 10

    /// WatchKit background refresh preferred interval (seconds).
    /// The watch does not poll CloudKit; it reloads App Group cache / WC push.
    /// 15 minutes balances wrist-up freshness against wake budget (watchOS guidance).
    public static let watchBackgroundRefreshInterval: TimeInterval = 15 * 60

    /// Upper bound for end-to-end Mac→phone lag when both sides use defaults
    /// and a silent push is missed (publish period + one companion poll).
    public static var worstCaseMissedPushLag: TimeInterval {
        macPublishInterval + companionRefreshInterval
    }
}
