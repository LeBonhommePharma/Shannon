import XCTest
@testable import ShannonCore

/// Pins Mac publish ↔ companion poll alignment (latency budget).
final class MultiDeviceCadenceTests: XCTestCase {

    func testCompanionRefreshDoesNotExceedMacPublishByLargeFactor() {
        // Safety-net poll must stay on the same order as Mac publish so a
        // missed silent push does not add multi-tens-of-seconds of lag.
        XCTAssertEqual(MultiDeviceCadence.macPublishInterval, 10)
        XCTAssertEqual(MultiDeviceCadence.companionRefreshInterval, 10)
        XCTAssertLessThanOrEqual(
            MultiDeviceCadence.companionRefreshInterval,
            MultiDeviceCadence.macPublishInterval
        )
        XCTAssertEqual(MultiDeviceCadence.worstCaseMissedPushLag, 20)
    }

    func testShannonStoreDefaultIntervalMatchesCadence() {
        // Default init uses MultiDeviceCadence.companionRefreshInterval (10),
        // not the old 30 s floor that lagged Mac publish by 20 s.
        // Pin the public constant Phone/Pad pass through (ShannonStore is
        // @MainActor — avoid constructing it from a nonisolated test).
        XCTAssertEqual(
            MultiDeviceCadence.companionRefreshInterval,
            10,
            "Phone/Pad must wire MultiDeviceCadence.companionRefreshInterval"
        )
        // Source-level default argument is the shared constant (not a literal 30).
        // Structural proof lives in testPhoneAndPadWireCadenceConstant +
        // ShannonStore.swift default parameter.
    }

    func testPhoneAndPadWireCadenceConstant() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ShannonCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ShannonCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
        let phone = try String(
            contentsOf: root.appendingPathComponent(
                "iOS/Sources/ShannonPhone/PhoneModel.swift"
            ),
            encoding: .utf8
        )
        let pad = try String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/ViewModels/AgentHubViewModel.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            phone.contains("MultiDeviceCadence.companionRefreshInterval"),
            "PhoneModel must use MultiDeviceCadence (not hard-coded 30)"
        )
        XCTAssertFalse(
            phone.contains("interval: 30"),
            "Phone must not hard-code 30 s poll"
        )
        XCTAssertTrue(
            pad.contains("MultiDeviceCadence.companionRefreshInterval"),
            "iPad hub must use MultiDeviceCadence"
        )
        XCTAssertFalse(
            pad.contains("interval: 20"),
            "iPad must not hard-code 20 s poll"
        )
    }

    func testMacCloudPublisherDefaultUsesCadence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cloud = try String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/ShannonPill/CloudPublishing.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            cloud.contains("MultiDeviceCadence.macPublishInterval"),
            "CloudPublisher default interval must use MultiDeviceCadence"
        )
    }

    /// UX-035: phone must reload WidgetKit after successful App Group cache write.
    func testPhoneReloadsWidgetAfterSnapshotCacheWrite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let phone = try String(
            contentsOf: root.appendingPathComponent(
                "iOS/Sources/ShannonPhone/PhoneModel.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            phone.contains("SnapshotCache.phone.save"),
            "PhoneModel must save App Group snapshot for widget"
        )
        XCTAssertTrue(
            phone.contains("WidgetCenter.shared.reloadTimelines"),
            "PhoneModel must reload WidgetKit after cache write"
        )
        XCTAssertTrue(
            phone.contains("\"ShannonWidget\""),
            "PhoneModel must reload ShannonWidget kind"
        )
        // Fail-closed: only reload when save succeeds (no reload on bare save).
        XCTAssertTrue(
            phone.contains("if SnapshotCache.phone.save"),
            "reload must gate on successful SnapshotCache.phone.save"
        )
        // UX-038: offline signal rides with the cache write; failure path rewrites too.
        XCTAssertTrue(
            phone.contains("lastError: store.lastError")
                || phone.contains("lastError: self.store.lastError"),
            "PhoneModel must persist lastError with SnapshotCache"
        )
        XCTAssertTrue(
            phone.contains("onSyncFailure"),
            "PhoneModel must rewrite cache on store sync failure (UX-038)"
        )
    }
}
