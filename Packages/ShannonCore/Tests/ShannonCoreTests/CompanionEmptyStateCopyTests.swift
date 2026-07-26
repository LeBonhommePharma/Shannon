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

    /// UX-020: watch WC phone reachability maps to idle vs hub-offline.
    func testWatchPhoneReachabilityMapsEmptyCopy() {
        let idle = CompanionEmptyStateCopy.content(isPhoneReachable: true)
        XCTAssertFalse(idle.isOffline)
        XCTAssertEqual(idle.title, CompanionEmptyStateCopy.idleTitle)

        let offline = CompanionEmptyStateCopy.content(isPhoneReachable: false)
        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(offline.title, CompanionEmptyStateCopy.offlineTitle)
        XCTAssertNotEqual(offline.title, CompanionEmptyStateCopy.idleTitle)
    }

    /// UX-020: watch empty agent list must resolve via phone reachability.
    func testWatchEmptyListWiresPhoneReachability() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let watch = (try? String(
            contentsOf: root.appendingPathComponent(
                "watchOS/Sources/ShannonWatch/WatchRootView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            watch.contains("CompanionEmptyStateCopy.content"),
            "watch empty list must use CompanionEmptyStateCopy.content"
        )
        XCTAssertTrue(
            watch.contains("isPhoneReachable"),
            "watch empty list must pass phone reachability"
        )
        XCTAssertFalse(
            watch.contains("Text(CompanionEmptyStateCopy.idleTitle)"),
            "watch must not always show idle empty when phone may be away"
        )
    }

    /// UX-015: Mac notch empty board + menu-bar roster share Core idle title.
    func testMacEmptyRosterWiresIdleTitle() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let pill = (try? String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/ShannonPill/PillView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            pill.contains("CompanionEmptyStateCopy.idleTitle"),
            "Mac emptyBoard must use CompanionEmptyStateCopy.idleTitle"
        )
        XCTAssertFalse(
            pill.contains("Text(\"No agents running\")"),
            "Mac emptyBoard must not hard-code dual idle title"
        )

        let roster = (try? String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/ShannonPill/MenuBarAgentRoster.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            roster.contains("CompanionEmptyStateCopy.idleTitle"),
            "menu-bar empty roster must use CompanionEmptyStateCopy.idleTitle"
        )
        XCTAssertFalse(
            roster.contains("\"No agents."),
            "menu-bar must not hard-code dual short 'No agents.' empty string"
        )
    }
}
