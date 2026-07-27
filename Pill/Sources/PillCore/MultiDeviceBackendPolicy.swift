import Foundation
import ShannonCore

// MARK: - Multi-device / CloudKit launch failsafe (pure)

/// When Shannon may construct a CloudKit backend.
///
/// macOS 27 (and earlier): `CKContainer(identifier:)` raises `EXC_BREAKPOINT`
/// when the container id is not in the app entitlements — a hard process kill,
/// not a catchable Swift error. Homebrew / ad-hoc / `swift run` builds must stay on
/// the in-memory backend so launch never traps.
///
/// iCloud **authentication** is system Apple ID only (System Settings). Shannon
/// never collects credentials. CloudKit is fail-closed unless
/// ``ICloudAccountStatus/available``.
public enum MultiDeviceBackendPolicy: Sendable {
    /// Operator-facing status for the popover footer (legacy short tokens).
    public enum Status: String, Sendable, Equatable {
        /// CloudKit backend active (account available + constructed).
        case on
        /// Opted in but blocked (no profile / no account / restricted / …).
        case off
        /// Default: no iCloud opt-in.
        case inMemory = "in-memory"
        /// System has no iCloud account (sign in via System Settings).
        case noAccount = "no-account"
        /// iCloud restricted by parental controls / MDM.
        case restricted
        /// Account status not yet known.
        case undetermined
        /// Transient CloudKit / network failure.
        case temporary
        /// Non-Apple host — multi-device iCloud is Apple-only.
        case unsupported
    }

    /// True only when opt-in, provisioning profile, **and** iCloud available.
    public static func shouldUseCloudKit(
        optIn: Bool,
        hasProvisioningProfile: Bool,
        accountStatus: ICloudAccountStatus = .couldNotDetermine
    ) -> Bool {
        ICloudAccountPolicy.shouldUseCloudKit(
            optIn: optIn,
            hasProvisioningProfile: hasProvisioningProfile,
            accountStatus: accountStatus
        )
    }

    /// Status from the same inputs the launch path uses.
    public static func status(
        optIn: Bool,
        hasProvisioningProfile: Bool,
        cloudKitConstructed: Bool,
        accountStatus: ICloudAccountStatus = .couldNotDetermine
    ) -> Status {
        let token = ICloudAccountPolicy.statusToken(
            optIn: optIn,
            hasProvisioningProfile: hasProvisioningProfile,
            accountStatus: accountStatus,
            cloudKitConstructed: cloudKitConstructed
        )
        return Status(rawValue: token) ?? .off
    }

    /// Full operator-facing multi-device footer line (honest iCloud login guidance).
    public static func operatorStatusLine(
        optIn: Bool,
        hasProvisioningProfile: Bool,
        cloudKitConstructed: Bool,
        accountStatus: ICloudAccountStatus
    ) -> String {
        ICloudAccountPolicy.operatorStatusLine(
            optIn: optIn,
            hasProvisioningProfile: hasProvisioningProfile,
            accountStatus: accountStatus,
            cloudKitConstructed: cloudKitConstructed
        )
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
