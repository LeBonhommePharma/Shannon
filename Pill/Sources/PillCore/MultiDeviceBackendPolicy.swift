import Foundation

// MARK: - Multi-device / CloudKit launch failsafe (pure)

/// When Shannon may construct a CloudKit backend.
///
/// macOS 27 (and earlier): `CKContainer(identifier:)` raises `EXC_BREAKPOINT`
/// when the container id is not in the app entitlements — a hard process kill,
/// not a catchable error. Homebrew / ad-hoc / `swift run` builds must stay on
/// the in-memory backend so launch never traps.
public enum MultiDeviceBackendPolicy: Sendable {
    /// Operator-facing status for the popover footer.
    public enum Status: String, Sendable, Equatable {
        /// CloudKit backend active.
        case on
        /// Opted in but no provisioning / entitlement → CloudKit not constructed.
        case off
        /// Default: no iCloud opt-in.
        case inMemory = "in-memory"
    }

    /// True only when both opt-in env and a real provisioning profile are present.
    public static func shouldUseCloudKit(
        optIn: Bool,
        hasProvisioningProfile: Bool
    ) -> Bool {
        optIn && hasProvisioningProfile
    }

    /// Status label from the same inputs the launch path uses.
    public static func status(
        optIn: Bool,
        hasProvisioningProfile: Bool,
        cloudKitConstructed: Bool
    ) -> Status {
        if cloudKitConstructed { return .on }
        if optIn { return .off }
        return .inMemory
    }

    /// Env flag `SHANNON_ICLOUD=1`.
    public static func optInFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["SHANNON_ICLOUD"] == "1"
    }

    /// Bundle has an embedded provisioning profile (Developer ID / App Store).
    public static func hasEmbeddedProvisioningProfile(
        bundlePath: String = Bundle.main.bundlePath,
        fileManager: FileManager = .default
    ) -> Bool {
        let candidates = [
            bundlePath + "/Contents/embedded.provisionprofile",
            bundlePath + "/embedded.provisionprofile",
        ]
        return candidates.contains { fileManager.fileExists(atPath: $0) }
    }
}
