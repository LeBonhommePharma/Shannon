import XCTest

/// Static presence checks: companions must ship host-capacity UI (not Mac-only).
/// Full mobile Xcode builds may be environment-limited; this gates source.
final class HostCapacityCompanionPresenceTests: XCTestCase {

    private var repoRoot: URL {
        // …/Packages/ShannonCore/Tests/ShannonCoreTests/This.swift
        // → Tests → ShannonCore → Packages → Shannon (repo root)
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ShannonCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ShannonCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
    }

    func testHostCapacitySourceInShannonCore() {
        let path = repoRoot
            .appendingPathComponent("Packages/ShannonCore/Sources/ShannonCore/HostCapacity.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), path.path)
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("constrainedRanked"))
        XCTAssertTrue(text.contains("LoadBalancePolicy"))
        XCTAssertTrue(text.contains("disk"))
        XCTAssertTrue(text.contains("thermal"))
    }

    func testHostCapacityViewsExist() {
        let path = repoRoot
            .appendingPathComponent("Packages/ShannonCore/Sources/ShannonCore/HostCapacityViews.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("struct HostCapacityCard"))
        XCTAssertTrue(text.contains("struct HostCapacityChip"))
    }

    func testIOSHomeViewWiresHostCapacity() {
        let path = repoRoot.appendingPathComponent("iOS/Sources/ShannonPhone/HomeView.swift")
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("HostCapacityCard"), "iOS must show host capacity")
        XCTAssertTrue(text.contains("LocalHostCapacity"))
        // UX-046: capacity cards must not paint under EmptyStateView on full empty.
        XCTAssertTrue(
            text.contains("!snapshot.isEmpty") && text.contains("HostCapacityCard"),
            "iOS must gate HostCapacityCard on !snapshot.isEmpty (UX-046)"
        )
        XCTAssertTrue(
            text.contains("UX-046") || text.contains("fail-closed"),
            "HomeView must document empty capacity hide (UX-046)"
        )
    }

    func testIPadDashboardWiresHostCapacity() {
        let path = repoRoot
            .appendingPathComponent("iPad/Sources/ShannonPad/Views/DashboardGridView.swift")
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("HostCapacityCard"), "iPad must show host capacity")
    }

    func testWatchFaceWiresHostCapacityChip() {
        let path = repoRoot
            .appendingPathComponent("watchOS/Sources/ShannonWatch/ShannonFaceView.swift")
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("HostCapacityChip"), "watchOS must show capacity chip")
    }

    func testMacPopoverOrdersMostConstrainedFirst() {
        // Resource block lives in MenuBarResourcesSection (extracted from popover).
        let path = repoRoot
            .appendingPathComponent("Pill/Sources/ShannonPill/MenuBarResourcesSection.swift")
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.isEmpty, "missing \(path.path)")
        XCTAssertTrue(text.contains("resourceRowsOrdered"), text.prefix(200).description)
        XCTAssertTrue(text.contains("mostConstrained") || text.contains("most constrained"))
        XCTAssertTrue(text.contains(".disk") || text.contains("diskDetail"))
        XCTAssertTrue(text.contains("thermalDetail") || text.contains(".thermal"))
        // Popover still hosts the section.
        let popover = repoRoot
            .appendingPathComponent("Pill/Sources/ShannonPill/MenuBarPopoverView.swift")
        let popText = (try? String(contentsOf: popover, encoding: .utf8)) ?? ""
        XCTAssertTrue(popText.contains("MenuBarResourcesSection"))
    }
}
