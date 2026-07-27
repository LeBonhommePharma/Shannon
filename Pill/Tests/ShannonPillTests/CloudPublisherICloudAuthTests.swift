import XCTest
import ShannonCore
@testable import ShannonPill

/// Fail-closed iCloud account status → backend selection + operator labels.
@MainActor
final class CloudPublisherICloudAuthTests: XCTestCase {

    func testDefaultBackendIsInMemoryWhenAccountNotAvailable() {
        for status: ICloudAccountStatus in [
            .noAccount, .restricted, .couldNotDetermine,
            .temporarilyUnavailable, .unsupported,
        ] {
            let backend = CloudPublisher.defaultBackend(accountStatus: status)
            XCTAssertFalse(
                CloudPublisher.backendIsCloudKit(backend),
                "must not construct CloudKit for \(status)"
            )
        }
    }

    func testStatusLabelNeverOnWhenNoAccountEvenIfBackendNameLooksLikeCloudKit() {
        // InMemory backend + noAccount must not report "on".
        let backend = InMemorySyncBackend()
        let token = CloudPublisher.statusLabel(for: backend, accountStatus: .noAccount)
        XCTAssertNotEqual(token, "on")
        XCTAssertFalse(token.contains("on"))
    }

    func testApplyAccountStatusSignOutDropsCloudKitFlag() {
        let pub = CloudPublisher(
            nowPlaying: nil,
            battery: nil,
            bridge: nil,
            backend: InMemorySyncBackend(),
            accountStatus: .available
        )
        // Start as available but in-memory (unsigned). Simulate status labels.
        pub.applyAccountStatus(.available)
        XCTAssertFalse(pub.usesCloudKit, "unsigned test process has no CloudKit backend")
        pub.applyAccountStatus(.noAccount)
        XCTAssertEqual(pub.accountStatus, .noAccount)
        XCTAssertFalse(pub.usesCloudKit)
        XCTAssertFalse(pub.multiDeviceStatusLine.contains("on (iCloud)"))
        XCTAssertTrue(
            pub.multiDeviceStatus == "no-account"
                || pub.multiDeviceStatus == "off"
                || pub.multiDeviceStatus == "in-memory",
            pub.multiDeviceStatus
        )
    }

    func testOperatorStatusLineMatchesPolicyForNoAccount() {
        // ShannonPillTests only links ShannonPill; pure policy is ShannonCore.
        let line = ICloudAccountPolicy.operatorStatusLine(
            optIn: true,
            hasProvisioningProfile: true,
            accountStatus: .noAccount,
            cloudKitConstructed: false
        )
        XCTAssertFalse(line.contains("on (iCloud)"))
        XCTAssertTrue(line.lowercased().contains("sign in"), line)
    }
}
