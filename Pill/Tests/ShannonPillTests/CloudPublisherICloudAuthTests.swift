import XCTest
import PillCore
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

    /// Drives the real `!wantCloud && usesCloudKit` branch: start with a
    /// CloudKit-*named* fake backend so `usesCloudKit == true`, then sign out.
    func testApplyAccountStatusSignOutDropsCloudKitBackend() {
        let fake = FakeCloudKitSyncBackend()
        XCTAssertTrue(
            CloudPublisher.backendIsCloudKit(fake),
            "test double name must contain CloudKit so backendIsCloudKit is true"
        )
        let pub = CloudPublisher(
            nowPlaying: nil,
            battery: nil,
            bridge: nil,
            backend: fake,
            accountStatus: .available
        )
        XCTAssertTrue(pub.usesCloudKit, "injected FakeCloudKitSyncBackend must set usesCloudKit")
        XCTAssertEqual(pub.accountStatus, .available)

        var lines: [String] = []
        pub.onMultiDeviceStatusLineChange = { lines.append($0) }

        // Sign-out: fail-closed swap to in-memory + honest operator line.
        pub.applyAccountStatus(.noAccount)

        XCTAssertEqual(pub.accountStatus, .noAccount)
        XCTAssertFalse(pub.usesCloudKit, "sign-out must drop CloudKit backend")
        XCTAssertFalse(
            CloudPublisher.backendIsCloudKit(pub._test_backendAccessor),
            "backend must be swapped off FakeCloudKitSyncBackend"
        )
        XCTAssertFalse(pub.multiDeviceStatusLine.contains("on (iCloud)"))
        XCTAssertFalse(lines.isEmpty, "account apply must notify observers (forceNotify)")
        XCTAssertFalse(lines.contains(where: { $0.contains("on (iCloud)") }))
    }

    func testOperatorStatusLineMatchesPolicyForNoAccount() {
        let line = ICloudAccountPolicy.operatorStatusLine(
            optIn: true,
            hasProvisioningProfile: true,
            accountStatus: .noAccount,
            cloudKitConstructed: false
        )
        XCTAssertFalse(line.contains("on (iCloud)"))
        XCTAssertTrue(line.lowercased().contains("sign in"), line)
    }

    /// Menu controller re-reads provider into the observed model on refresh
    /// (same path as popover reopen).
    func testMenuBarRefreshMultiDeviceStatusUpdatesObservedModel() {
        var current = "Multi-device: on (iCloud)"
        let model = MultiDeviceStatusModel(line: current)
        let menu = MenuBarController(
            bridge: ShannonBridge(),
            battery: BatteryMonitor(provider: IOKitBatteryProvider()),
            ingest: AgentIngestService(),
            activity: AgentActivityMonitor(),
            resources: SystemResourceMonitor(interval: 60, smoothAlpha: 1),
            keepAwake: KeepAwakeMonitor(),
            focusMode: FocusModeMonitor(),
            multiDeviceStatus: current,
            multiDeviceStatusProvider: { current },
            multiDeviceStatusModel: model
        )
        XCTAssertEqual(model.line, "Multi-device: on (iCloud)")
        current = "Multi-device: sign in to iCloud (System Settings → Apple ID)"
        menu.refreshMultiDeviceStatus()
        XCTAssertEqual(model.line, current)
        XCTAssertFalse(model.line.contains("on (iCloud)"))
    }
}

// MARK: - Fake CloudKit-named backend (no real CKContainer)

/// Name contains `CloudKit` so ``CloudPublisher.backendIsCloudKit`` is true
/// without constructing a real container (unsigned builds would trap).
private final class FakeCloudKitSyncBackend: ShannonSyncBackend, @unchecked Sendable {
    private let inner = InMemorySyncBackend()

    func save(recordType: String, recordName: String, fields: CloudFields) async throws {
        try await inner.save(recordType: recordType, recordName: recordName, fields: fields)
    }

    func delete(recordType: String, recordName: String) async throws {
        try await inner.delete(recordType: recordType, recordName: recordName)
    }

    func fetchAll(
        recordType: String
    ) async throws -> [(recordName: String, fields: CloudFields)] {
        try await inner.fetchAll(recordType: recordType)
    }
}

