import XCTest
@testable import PillCore

/// CloudKit must never construct on unsigned launches (macOS 27 EXC_BREAKPOINT).
final class MultiDeviceBackendPolicyTests: XCTestCase {

    func testUnsignedNeverUsesCloudKit() {
        XCTAssertFalse(
            MultiDeviceBackendPolicy.shouldUseCloudKit(
                optIn: true,
                hasProvisioningProfile: false
            ),
            "opt-in without profile must not construct CKContainer"
        )
        XCTAssertFalse(
            MultiDeviceBackendPolicy.shouldUseCloudKit(
                optIn: false,
                hasProvisioningProfile: true
            )
        )
        XCTAssertFalse(
            MultiDeviceBackendPolicy.shouldUseCloudKit(
                optIn: false,
                hasProvisioningProfile: false
            )
        )
    }

    func testOptInWithProfileMayUseCloudKit() {
        XCTAssertTrue(
            MultiDeviceBackendPolicy.shouldUseCloudKit(
                optIn: true,
                hasProvisioningProfile: true
            )
        )
    }

    func testStatusLabels() {
        XCTAssertEqual(
            MultiDeviceBackendPolicy.status(
                optIn: false, hasProvisioningProfile: false, cloudKitConstructed: false
            ),
            .inMemory
        )
        XCTAssertEqual(
            MultiDeviceBackendPolicy.status(
                optIn: true, hasProvisioningProfile: false, cloudKitConstructed: false
            ),
            .off
        )
        XCTAssertEqual(
            MultiDeviceBackendPolicy.status(
                optIn: true, hasProvisioningProfile: true, cloudKitConstructed: true
            ),
            .on
        )
        XCTAssertEqual(MultiDeviceBackendPolicy.Status.inMemory.rawValue, "in-memory")
    }

    func testOptInFromEnvironment() {
        XCTAssertTrue(MultiDeviceBackendPolicy.optInFromEnvironment(["SHANNON_ICLOUD": "1"]))
        XCTAssertFalse(MultiDeviceBackendPolicy.optInFromEnvironment(["SHANNON_ICLOUD": "0"]))
        XCTAssertFalse(MultiDeviceBackendPolicy.optInFromEnvironment([:]))
    }
}
