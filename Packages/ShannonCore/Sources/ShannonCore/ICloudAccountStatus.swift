import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - iCloud account status (system Apple ID presence — no custom login)

/// System iCloud account presence for the Shannon multi-device container.
///
/// Shannon never collects Apple ID credentials. Sign-in is **System Settings →
/// Apple ID / iCloud**. This type is the pure mirror of `CKAccountStatus` plus
/// an `unsupported` case for hosts without CloudKit (Windows / Linux science path).
public enum ICloudAccountStatus: String, Sendable, Equatable, CaseIterable {
    /// Signed in and allowed to use CloudKit for this process.
    case available
    /// No iCloud account on this device (user must sign in via System Settings).
    case noAccount
    /// Parental controls / MDM / managed restriction blocks iCloud.
    case restricted
    /// CloudKit has not answered yet (or returned couldNotDetermine).
    case couldNotDetermine
    /// Transient network / service failure — retry later; fail-closed for publish.
    case temporarilyUnavailable
    /// Non-Apple host or CloudKit not linked — multi-device iCloud is Apple-only.
    case unsupported
}

// MARK: - Pure policy (unit-testable without a live container)

/// Pure decisions: account status → may publish, operator labels, backend readiness.
///
/// All multi-device CloudKit I/O must fail closed unless status is ``available``.
public enum ICloudAccountPolicy: Sendable {

    /// Container identity every Apple target must match (Signing & Capabilities).
    public static var containerID: String { ShannonSyncConfig.containerID }

    /// Only ``available`` may construct / use a live CloudKit session for publish.
    public static func canUseCloudKit(_ status: ICloudAccountStatus) -> Bool {
        status == .available
    }

    /// Fail-closed backend selection inputs (pure).
    ///
    /// CloudKit is selected only when the operator opted in, the process has a
    /// real provisioning profile (unsigned builds must not touch `CKContainer`),
    /// **and** the system iCloud account is available.
    public static func shouldUseCloudKit(
        optIn: Bool,
        hasProvisioningProfile: Bool,
        accountStatus: ICloudAccountStatus
    ) -> Bool {
        optIn && hasProvisioningProfile && canUseCloudKit(accountStatus)
    }

    /// Multi-device path classification for operator chrome / tests.
    public enum PathKind: String, Sendable, Equatable {
        /// Live CloudKit private-DB backend active.
        case cloudKitOn = "on"
        /// Opt-in requested but blocked (no profile, no account, restricted, …).
        case cloudKitOff = "off"
        /// Default local-only (no `SHANNON_ICLOUD=1`).
        case inMemory = "in-memory"
    }

    /// Pure status from the same inputs the Mac launch path uses.
    public static func pathKind(
        optIn: Bool,
        hasProvisioningProfile: Bool,
        accountStatus: ICloudAccountStatus,
        cloudKitConstructed: Bool
    ) -> PathKind {
        // Constructed backend is authoritative only when policy still allows it.
        if cloudKitConstructed, canUseCloudKit(accountStatus), optIn, hasProvisioningProfile {
            return .cloudKitOn
        }
        if optIn {
            return .cloudKitOff
        }
        return .inMemory
    }

    /// Short operator-facing multi-device line (menu / popover footer).
    ///
    /// Never labels the path "on (iCloud)" unless status is available and the
    /// CloudKit backend was actually constructed.
    public static func operatorStatusLine(
        optIn: Bool,
        hasProvisioningProfile: Bool,
        accountStatus: ICloudAccountStatus,
        cloudKitConstructed: Bool
    ) -> String {
        let kind = pathKind(
            optIn: optIn,
            hasProvisioningProfile: hasProvisioningProfile,
            accountStatus: accountStatus,
            cloudKitConstructed: cloudKitConstructed
        )
        switch kind {
        case .cloudKitOn:
            return "Multi-device: on (iCloud)"
        case .inMemory:
            return "Multi-device: in-memory"
        case .cloudKitOff:
            return offReasonLine(
                hasProvisioningProfile: hasProvisioningProfile,
                accountStatus: accountStatus
            )
        }
    }

    /// Machine-readable status token for bindings that still use short codes
    /// (`on` / `off` / `in-memory` / account-specific tokens).
    public static func statusToken(
        optIn: Bool,
        hasProvisioningProfile: Bool,
        accountStatus: ICloudAccountStatus,
        cloudKitConstructed: Bool
    ) -> String {
        let kind = pathKind(
            optIn: optIn,
            hasProvisioningProfile: hasProvisioningProfile,
            accountStatus: accountStatus,
            cloudKitConstructed: cloudKitConstructed
        )
        switch kind {
        case .cloudKitOn:
            return PathKind.cloudKitOn.rawValue
        case .inMemory:
            return PathKind.inMemory.rawValue
        case .cloudKitOff:
            if !hasProvisioningProfile {
                return PathKind.cloudKitOff.rawValue
            }
            // Distinguish account problems so chrome can stay honest.
            switch accountStatus {
            case .available:
                return PathKind.cloudKitOff.rawValue
            case .noAccount:
                return "no-account"
            case .restricted:
                return "restricted"
            case .couldNotDetermine:
                return "undetermined"
            case .temporarilyUnavailable:
                return "temporary"
            case .unsupported:
                return "unsupported"
            }
        }
    }

    private static func offReasonLine(
        hasProvisioningProfile: Bool,
        accountStatus: ICloudAccountStatus
    ) -> String {
        if !hasProvisioningProfile {
            return "Multi-device: off (unsigned build — no iCloud entitlement)"
        }
        switch accountStatus {
        case .available:
            // Opt-in + profile + available but backend not constructed (should be rare).
            return "Multi-device: off"
        case .noAccount:
            return "Multi-device: sign in to iCloud (System Settings → Apple ID)"
        case .restricted:
            return "Multi-device: iCloud restricted on this Mac"
        case .couldNotDetermine:
            return "Multi-device: iCloud status undetermined"
        case .temporarilyUnavailable:
            return "Multi-device: iCloud temporarily unavailable"
        case .unsupported:
            return "Multi-device: iCloud is Apple-only (not available here)"
        }
    }

    /// Map CloudKit's integer-like raw status for tests without importing CK enums
    /// into pure cases. Values match `CKAccountStatus` rawValues on Apple platforms.
    public static func status(fromCKAccountStatusRawValue raw: Int) -> ICloudAccountStatus {
        switch raw {
        case 1: return .available          // CKAccountStatus.available
        case 0: return .couldNotDetermine  // CKAccountStatus.couldNotDetermine
        case 2: return .restricted         // CKAccountStatus.restricted
        case 3: return .noAccount          // CKAccountStatus.noAccount
        case 4: return .temporarilyUnavailable // CKAccountStatus.temporarilyUnavailable (newer SDKs)
        default: return .couldNotDetermine
        }
    }

    #if canImport(CloudKit)
    /// Map a live `CKAccountStatus` into the pure enum.
    public static func status(from ck: CKAccountStatus) -> ICloudAccountStatus {
        status(fromCKAccountStatusRawValue: ck.rawValue)
    }
    #endif

    /// Hosts without CloudKit always report unsupported (Windows / Linux science).
    public static var nonAppleHostStatus: ICloudAccountStatus { .unsupported }
}

// MARK: - Status provider protocol (testable)

/// Reads system iCloud account presence for ``ShannonSyncConfig/containerID``.
public protocol ICloudAccountStatusReading: Sendable {
    /// Current status (may hit the network once; cheap thereafter).
    func currentStatus() async -> ICloudAccountStatus
}

/// Always-unavailable reader for previews, unit tests, and non-Apple hosts.
public struct StaticICloudAccountStatusReader: ICloudAccountStatusReading {
    public let status: ICloudAccountStatus

    public init(_ status: ICloudAccountStatus) {
        self.status = status
    }

    public func currentStatus() async -> ICloudAccountStatus { status }
}

#if canImport(CloudKit)

/// Live CloudKit account status for the Shannon container.
///
/// **Call only when the process has a real iCloud entitlement.** Constructing
/// `CKContainer(identifier:)` on an unsigned build raises `EXC_BREAKPOINT`.
/// Gate callers with provisioning-profile + opt-in checks first.
public final class CloudKitAccountStatusReader: ICloudAccountStatusReading, @unchecked Sendable {
    private let containerID: String

    public init(containerID: String = ShannonSyncConfig.containerID) {
        self.containerID = containerID
    }

    public func currentStatus() async -> ICloudAccountStatus {
        let container = CKContainer(identifier: containerID)
        do {
            let ck = try await container.accountStatus()
            return ICloudAccountPolicy.status(from: ck)
        } catch {
            // Network / daemon blip — fail closed.
            return .temporarilyUnavailable
        }
    }
}

#endif
