import XCTest
import ShannonCore
@testable import PillCore

/// CloudKit must never construct on unsigned launches (macOS 27 EXC_BREAKPOINT)
/// or when the system iCloud account is not available (fail-closed auth).
final class MultiDeviceBackendPolicyTests: XCTestCase {

    func testUnsignedNeverUsesCloudKit() {
        XCTAssertFalse(
            MultiDeviceBackendPolicy.shouldUseCloudKit(
                optIn: true,
                hasProvisioningProfile: false,
                accountStatus: .available
            ),
            "opt-in without profile must not construct CKContainer"
        )
        XCTAssertFalse(
            MultiDeviceBackendPolicy.shouldUseCloudKit(
                optIn: false,
                hasProvisioningProfile: true,
                accountStatus: .available
            )
        )
        XCTAssertFalse(
            MultiDeviceBackendPolicy.shouldUseCloudKit(
                optIn: false,
                hasProvisioningProfile: false,
                accountStatus: .available
            )
        )
    }

    func testOptInWithProfileAndAvailableMayUseCloudKit() {
        XCTAssertTrue(
            MultiDeviceBackendPolicy.shouldUseCloudKit(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: .available
            )
        )
    }

    func testSignedOutFailsClosedEvenWithProfileAndOptIn() {
        XCTAssertFalse(
            MultiDeviceBackendPolicy.shouldUseCloudKit(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: .noAccount
            )
        )
        for bad: ICloudAccountStatus in [
            .restricted, .couldNotDetermine, .temporarilyUnavailable, .unsupported,
        ] {
            XCTAssertFalse(
                MultiDeviceBackendPolicy.shouldUseCloudKit(
                    optIn: true,
                    hasProvisioningProfile: true,
                    accountStatus: bad
                ),
                "must fail closed for \(bad)"
            )
        }
    }

    func testStatusLabelsIncludeAccountTokens() {
        XCTAssertEqual(
            MultiDeviceBackendPolicy.status(
                optIn: false,
                hasProvisioningProfile: false,
                cloudKitConstructed: false,
                accountStatus: .couldNotDetermine
            ),
            .inMemory
        )
        XCTAssertEqual(
            MultiDeviceBackendPolicy.status(
                optIn: true,
                hasProvisioningProfile: false,
                cloudKitConstructed: false,
                accountStatus: .available
            ),
            .off
        )
        XCTAssertEqual(
            MultiDeviceBackendPolicy.status(
                optIn: true,
                hasProvisioningProfile: true,
                cloudKitConstructed: true,
                accountStatus: .available
            ),
            .on
        )
        XCTAssertEqual(
            MultiDeviceBackendPolicy.status(
                optIn: true,
                hasProvisioningProfile: true,
                cloudKitConstructed: false,
                accountStatus: .noAccount
            ),
            .noAccount
        )
        XCTAssertEqual(
            MultiDeviceBackendPolicy.status(
                optIn: true,
                hasProvisioningProfile: true,
                cloudKitConstructed: true,
                accountStatus: .noAccount
            ),
            .noAccount,
            "must not stay 'on' after sign-out"
        )
        XCTAssertEqual(MultiDeviceBackendPolicy.Status.inMemory.rawValue, "in-memory")
        XCTAssertEqual(MultiDeviceBackendPolicy.Status.noAccount.rawValue, "no-account")
    }

    func testOperatorLineNeverClaimsOnWhileSignedOut() {
        let line = MultiDeviceBackendPolicy.operatorStatusLine(
            optIn: true,
            hasProvisioningProfile: true,
            cloudKitConstructed: true,
            accountStatus: .noAccount
        )
        XCTAssertFalse(line.contains("on (iCloud)"), line)
        XCTAssertTrue(line.lowercased().contains("sign in"), line)
    }

    func testOperatorLineOnOnlyWhenAvailableAndConstructed() {
        let line = MultiDeviceBackendPolicy.operatorStatusLine(
            optIn: true,
            hasProvisioningProfile: true,
            cloudKitConstructed: true,
            accountStatus: .available
        )
        XCTAssertEqual(line, "Multi-device: on (iCloud)")
    }

    func testOptInFromEnvironment() {
        XCTAssertTrue(MultiDeviceBackendPolicy.optInFromEnvironment(["SHANNON_ICLOUD": "1"]))
        XCTAssertFalse(MultiDeviceBackendPolicy.optInFromEnvironment(["SHANNON_ICLOUD": "0"]))
        XCTAssertFalse(MultiDeviceBackendPolicy.optInFromEnvironment([:]))
    }
}
