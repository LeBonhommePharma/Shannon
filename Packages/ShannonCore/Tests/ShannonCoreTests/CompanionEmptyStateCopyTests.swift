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

    /// UX-050: notifications empty must fail-closed when phone unreachable —
    /// never bare healthy "No notifications" while WC phone is away.
    func testWatchNotificationEmptyWiresOfflineWhenPhoneAway() {
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
        XCTAssertFalse(watch.isEmpty, "WatchRootView.swift must be readable")

        // NotificationListView region: offline path shares agent-empty family.
        XCTAssertTrue(
            watch.contains("struct NotificationListView"),
            "NotificationListView must exist"
        )
        XCTAssertTrue(
            watch.contains("notifications.isEmpty"),
            "NotificationListView must branch on empty notifications"
        )
        // Fail-closed: reachability must gate empty chrome (not always healthy idle).
        let notifyIdx = watch.range(of: "struct NotificationListView")
        XCTAssertNotNil(notifyIdx)
        let notifyBody = notifyIdx.map { String(watch[$0.lowerBound...]) } ?? ""
        XCTAssertTrue(
            notifyBody.contains("CompanionEmptyStateCopy.content")
                || notifyBody.contains("isPhoneReachable"),
            "NotificationListView empty must consider phone reachability (UX-050)"
        )
        XCTAssertTrue(
            notifyBody.contains("isPhoneReachable"),
            "NotificationListView empty must pass isPhoneReachable"
        )
        XCTAssertTrue(
            notifyBody.contains("empty.isOffline") || notifyBody.contains("isOffline"),
            "NotificationListView must branch offline vs idle empty"
        )
        XCTAssertTrue(
            notifyBody.contains("CompanionEmptyStateCopy.offlineChip")
                || notifyBody.contains("offlineChip"),
            "NotificationListView offline empty must show offline chip family"
        )
        // Bare healthy empty only on the reachable path — not as sole empty chrome.
        // Forbid a lone always-on No notifications without reachability gating nearby.
        XCTAssertTrue(
            notifyBody.contains("\"No notifications\""),
            "reachable path may keep surface idle No notifications"
        )
        // Ensure offline title path is present (not only the healthy string).
        XCTAssertTrue(
            notifyBody.contains("empty.title") || notifyBody.contains("offlineTitle"),
            "NotificationListView offline empty must show offline title"
        )
    }

    /// UX-039: pad non-empty hub must surface offlineChip under lastError
    /// (phone DisconnectedPill parity); SyncIndicator must not stay healthy.
    func testPadNonEmptyHubWiresOfflineChipAndFailClosedSyncIndicator() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let phone = (try? String(
            contentsOf: root.appendingPathComponent(
                "iOS/Sources/ShannonPhone/HomeView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            phone.contains("CompanionEmptyStateCopy.offlineChip"),
            "phone DisconnectedPill must use CompanionEmptyStateCopy.offlineChip"
        )
        XCTAssertTrue(
            phone.contains("lastError != nil") && phone.contains("!snapshot.isEmpty"),
            "phone must gate offline chip on lastError + non-empty snapshot"
        )

        let pad = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/AgentHubView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertFalse(pad.isEmpty, "AgentHubView.swift must be readable from Core tests")
        // Non-empty content + lastError → shared offline chip (not empty-only).
        XCTAssertTrue(
            pad.contains("CompanionEmptyStateCopy.offlineChip"),
            "pad must wire CompanionEmptyStateCopy.offlineChip under content (UX-039)"
        )
        XCTAssertTrue(
            pad.contains("lastError != nil") && pad.contains("!hub.snapshot.isEmpty"),
            "pad must gate offline chip on lastError + non-empty snapshot (phone parity)"
        )
        XCTAssertTrue(
            pad.contains("CompanionEmptyStateCopy.offlineAccessibility"),
            "pad offline chrome must use shared offline a11y"
        )
        // SyncIndicator: prefer offline under lastError, not healthy relative age.
        XCTAssertTrue(
            pad.contains("lastError: hub.store.lastError"),
            "AgentHubView must pass store.lastError into SyncIndicator"
        )
        XCTAssertTrue(
            pad.contains("hasSyncError(lastError)") || pad.contains("hasSyncError"),
            "SyncIndicator must fail-close via hasSyncError / lastError"
        )
        XCTAssertTrue(
            pad.contains("struct SyncIndicator"),
            "SyncIndicator lives in AgentHubView for pad toolbar chrome"
        )
    }

    /// UX-038: widget empty/offline branch uses CompanionEmptyStateCopy offline family.
    func testWidgetWiresOfflineEmptyStateCopy() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let widget = (try? String(
            contentsOf: root.appendingPathComponent(
                "iOS/Sources/ShannonWidget/ShannonWidget.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            widget.contains("SnapshotCache.phone.loadRecord"),
            "widget must load SnapshotCacheRecord for offline flag"
        )
        XCTAssertTrue(
            widget.contains("CompanionEmptyStateCopy"),
            "widget must use CompanionEmptyStateCopy for offline chrome"
        )
        XCTAssertTrue(
            widget.contains("offline.isOffline") || widget.contains("isOffline"),
            "widget must branch on offline flag"
        )
        XCTAssertTrue(
            widget.contains("lastError"),
            "widget entry must carry lastError from cache"
        )
        XCTAssertFalse(
            widget.contains("\"Hub offline\""),
            "widget must not hard-code dual offline title string"
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
