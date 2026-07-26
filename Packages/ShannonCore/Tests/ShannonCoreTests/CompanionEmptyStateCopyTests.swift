import XCTest
@testable import ShannonCore

/// UX-002 — fail-closed empty states when CloudKit / hub offline.
final class CompanionEmptyStateCopyTests: XCTestCase {

    func testIdleWhenNoError() {
        let c = CompanionEmptyStateCopy.content(lastError: nil)
        XCTAssertFalse(c.isOffline)
        XCTAssertEqual(c.title, CompanionEmptyStateCopy.idleTitle)
        XCTAssertEqual(c.detail, CompanionEmptyStateCopy.idleDetail)
        XCTAssertEqual(c.systemImage, "moon.zzz")
        XCTAssertEqual(c.title, "No agents running")
    }

    func testOfflineWhenErrorPresent() {
        let c = CompanionEmptyStateCopy.content(lastError: "CKError network unavailable")
        XCTAssertTrue(c.isOffline)
        XCTAssertEqual(c.title, CompanionEmptyStateCopy.offlineTitle)
        XCTAssertEqual(c.detail, CompanionEmptyStateCopy.offlineDetail)
        XCTAssertEqual(c.systemImage, "icloud.slash")
        XCTAssertEqual(c.title, "Hub offline")
        // Must not read as quiet healthy idle.
        XCTAssertNotEqual(c.title, CompanionEmptyStateCopy.idleTitle)
        XCTAssertFalse(c.title.localizedCaseInsensitiveContains("nothing running"))
        XCTAssertFalse(c.title.localizedCaseInsensitiveContains("healthy"))
    }

    func testWhitespaceErrorStillOffline() {
        XCTAssertFalse(CompanionEmptyStateCopy.hasSyncError("   "))
        XCTAssertFalse(CompanionEmptyStateCopy.hasSyncError(""))
        XCTAssertTrue(CompanionEmptyStateCopy.hasSyncError("x"))
        let blank = CompanionEmptyStateCopy.content(lastError: "  \n")
        XCTAssertFalse(blank.isOffline, "whitespace-only must not alarm")
    }

    func testTechnicalDetailSeparateFromTitle() {
        XCTAssertNil(CompanionEmptyStateCopy.technicalDetail(lastError: nil))
        XCTAssertEqual(
            CompanionEmptyStateCopy.technicalDetail(lastError: "  boom  "),
            "boom"
        )
        let c = CompanionEmptyStateCopy.content(lastError: "boom")
        // Title stays canonical — raw error is optional secondary only.
        XCTAssertEqual(c.title, "Hub offline")
        XCTAssertNotEqual(c.title, "boom")
    }

    func testChipMatchesOfflineTitleFamily() {
        XCTAssertEqual(CompanionEmptyStateCopy.offlineChip, "Hub offline")
        XCTAssertEqual(
            CompanionEmptyStateCopy.offlineChip,
            CompanionEmptyStateCopy.offlineTitle
        )
        XCTAssertFalse(CompanionEmptyStateCopy.offlineAccessibility.isEmpty)
    }

    func testPhoneAndPadWireSharedCopy() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let phone = (try? String(
            contentsOf: root.appendingPathComponent("iOS/Sources/ShannonPhone/HomeView.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            phone.contains("CompanionEmptyStateCopy"),
            "phone empty state must use shared copy"
        )
        XCTAssertFalse(
            phone.contains("\"Can't reach iCloud\""),
            "phone must not hard-code dual-OS offline title"
        )
        XCTAssertFalse(
            phone.contains("\"Nothing running\""),
            "phone must not hard-code dual-OS idle title"
        )

        let pad = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/DashboardGridView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            pad.contains("CompanionEmptyStateCopy"),
            "pad EmptyHubState must use shared copy"
        )
        XCTAssertFalse(
            pad.contains("\"Not syncing with the Mac\""),
            "pad must not hard-code dual-OS offline title"
        )
    }
}
