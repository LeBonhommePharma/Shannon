import XCTest
@testable import ShannonCore

/// Pure iCloud account policy — drives shipped `ICloudAccountPolicy` / status enum.
final class ICloudAccountStatusTests: XCTestCase {

    // MARK: canUseCloudKit fail-closed

    func testOnlyAvailableAllowsCloudKit() {
        for status in ICloudAccountStatus.allCases {
            let allowed = ICloudAccountPolicy.canUseCloudKit(status)
            if status == .available {
                XCTAssertTrue(allowed, "\(status) must allow CloudKit")
            } else {
                XCTAssertFalse(allowed, "\(status) must fail closed")
            }
        }
    }

    func testShouldUseCloudKitRequiresAllThreeGates() {
        // Happy path.
        XCTAssertTrue(
            ICloudAccountPolicy.shouldUseCloudKit(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: .available
            )
        )
        // Missing opt-in.
        XCTAssertFalse(
            ICloudAccountPolicy.shouldUseCloudKit(
                optIn: false,
                hasProvisioningProfile: true,
                accountStatus: .available
            )
        )
        // Unsigned / no profile — never construct CKContainer.
        XCTAssertFalse(
            ICloudAccountPolicy.shouldUseCloudKit(
                optIn: true,
                hasProvisioningProfile: false,
                accountStatus: .available
            )
        )
        // Signed out.
        XCTAssertFalse(
            ICloudAccountPolicy.shouldUseCloudKit(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: .noAccount
            )
        )
        // Restricted / undetermined / temporary / unsupported.
        for bad in [
            ICloudAccountStatus.restricted,
            .couldNotDetermine,
            .temporarilyUnavailable,
            .unsupported,
        ] {
            XCTAssertFalse(
                ICloudAccountPolicy.shouldUseCloudKit(
                    optIn: true,
                    hasProvisioningProfile: true,
                    accountStatus: bad
                ),
                "must fail closed for \(bad)"
            )
        }
    }

    // MARK: pathKind + operator lines

    func testPathKindOnOnlyWhenConstructedAndAvailable() {
        XCTAssertEqual(
            ICloudAccountPolicy.pathKind(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: .available,
                cloudKitConstructed: true
            ),
            .cloudKitOn
        )
        // Constructed flag must not label "on" when account dropped.
        XCTAssertEqual(
            ICloudAccountPolicy.pathKind(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: .noAccount,
                cloudKitConstructed: true
            ),
            .cloudKitOff
        )
        XCTAssertEqual(
            ICloudAccountPolicy.pathKind(
                optIn: false,
                hasProvisioningProfile: false,
                accountStatus: .couldNotDetermine,
                cloudKitConstructed: false
            ),
            .inMemory
        )
    }

    func testOperatorLineNeverClaimsOnICloudWithoutAvailable() {
        let statuses: [ICloudAccountStatus] = [
            .noAccount, .restricted, .couldNotDetermine,
            .temporarilyUnavailable, .unsupported,
        ]
        for status in statuses {
            let line = ICloudAccountPolicy.operatorStatusLine(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: status,
                cloudKitConstructed: true // even if stale construction flag
            )
            XCTAssertFalse(
                line.contains("on (iCloud)"),
                "must not claim on (iCloud) for \(status): \(line)"
            )
            XCTAssertTrue(line.hasPrefix("Multi-device:"), line)
        }
        let on = ICloudAccountPolicy.operatorStatusLine(
            optIn: true,
            hasProvisioningProfile: true,
            accountStatus: .available,
            cloudKitConstructed: true
        )
        XCTAssertEqual(on, "Multi-device: on (iCloud)")
    }

    func testNoAccountLinePointsAtSystemSettings() {
        let line = ICloudAccountPolicy.operatorStatusLine(
            optIn: true,
            hasProvisioningProfile: true,
            accountStatus: .noAccount,
            cloudKitConstructed: false
        )
        XCTAssertTrue(line.lowercased().contains("sign in"), line)
        XCTAssertTrue(line.contains("System Settings") || line.contains("Apple ID"), line)
    }

    func testUnsupportedIsHonestAppleOnly() {
        let line = ICloudAccountPolicy.operatorStatusLine(
            optIn: true,
            hasProvisioningProfile: false,
            accountStatus: .unsupported,
            cloudKitConstructed: false
        )
        // Without profile we prefer unsigned message; with profile + unsupported:
        let line2 = ICloudAccountPolicy.operatorStatusLine(
            optIn: true,
            hasProvisioningProfile: true,
            accountStatus: .unsupported,
            cloudKitConstructed: false
        )
        XCTAssertTrue(
            line2.lowercased().contains("apple-only") || line2.lowercased().contains("not available"),
            line2
        )
        _ = line
    }

    func testStatusTokensForAccountProblems() {
        XCTAssertEqual(
            ICloudAccountPolicy.statusToken(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: .noAccount,
                cloudKitConstructed: false
            ),
            "no-account"
        )
        XCTAssertEqual(
            ICloudAccountPolicy.statusToken(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: .restricted,
                cloudKitConstructed: false
            ),
            "restricted"
        )
        XCTAssertEqual(
            ICloudAccountPolicy.statusToken(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: .available,
                cloudKitConstructed: true
            ),
            "on"
        )
        XCTAssertEqual(
            ICloudAccountPolicy.statusToken(
                optIn: false,
                hasProvisioningProfile: false,
                accountStatus: .couldNotDetermine,
                cloudKitConstructed: false
            ),
            "in-memory"
        )
    }

    // MARK: CK raw mapping + non-Apple

    func testCKAccountStatusRawValueMapping() {
        // Matches CKAccountStatus raw values on Apple SDKs.
        XCTAssertEqual(ICloudAccountPolicy.status(fromCKAccountStatusRawValue: 1), .available)
        XCTAssertEqual(ICloudAccountPolicy.status(fromCKAccountStatusRawValue: 0), .couldNotDetermine)
        XCTAssertEqual(ICloudAccountPolicy.status(fromCKAccountStatusRawValue: 2), .restricted)
        XCTAssertEqual(ICloudAccountPolicy.status(fromCKAccountStatusRawValue: 3), .noAccount)
        XCTAssertEqual(ICloudAccountPolicy.status(fromCKAccountStatusRawValue: 4), .temporarilyUnavailable)
        XCTAssertEqual(ICloudAccountPolicy.status(fromCKAccountStatusRawValue: 99), .couldNotDetermine)
    }

    func testNonAppleHostStatusIsUnsupported() {
        XCTAssertEqual(ICloudAccountPolicy.nonAppleHostStatus, .unsupported)
        XCTAssertFalse(ICloudAccountPolicy.canUseCloudKit(.unsupported))
    }

    func testContainerIDMatchesShannonSyncConfig() {
        XCTAssertEqual(ICloudAccountPolicy.containerID, ShannonSyncConfig.containerID)
        XCTAssertEqual(ICloudAccountPolicy.containerID, "iCloud.com.lebonhommepharma.shannon")
    }

    func testStaticReaderReturnsInjectedStatus() async {
        let reader = StaticICloudAccountStatusReader(.noAccount)
        let status = await reader.currentStatus()
        XCTAssertEqual(status, .noAccount)
    }

    @MainActor
    func testMonitorApplyAndCanUseCloudKit() async {
        let monitor = ICloudAccountMonitor(
            initial: .couldNotDetermine,
            reader: StaticICloudAccountStatusReader(.available),
            observeSystemChanges: false
        )
        XCTAssertFalse(monitor.canUseCloudKit)
        await monitor.refresh()
        XCTAssertEqual(monitor.status, .available)
        XCTAssertTrue(monitor.canUseCloudKit)

        var seen: [ICloudAccountStatus] = []
        monitor.onChange = { seen.append($0) }
        monitor.apply(.noAccount)
        XCTAssertEqual(monitor.status, .noAccount)
        XCTAssertFalse(monitor.canUseCloudKit)
        XCTAssertEqual(seen, [.noAccount])
    }

    /// Windows/Linux path: unsupported never enables CloudKit.
    func testNonAppleDegradeCannotEnableCloudKitSession() {
        let status = ICloudAccountPolicy.nonAppleHostStatus
        XCTAssertEqual(status, .unsupported)
        XCTAssertFalse(
            ICloudAccountPolicy.shouldUseCloudKit(
                optIn: true,
                hasProvisioningProfile: true,
                accountStatus: status
            )
        )
        let token = ICloudAccountPolicy.statusToken(
            optIn: true,
            hasProvisioningProfile: true,
            accountStatus: status,
            cloudKitConstructed: false
        )
        XCTAssertEqual(token, "unsupported")
        let line = ICloudAccountPolicy.operatorStatusLine(
            optIn: true,
            hasProvisioningProfile: true,
            accountStatus: status,
            cloudKitConstructed: true
        )
        XCTAssertFalse(line.contains("on (iCloud)"))
    }
}
