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
        let path = repoRoot
            .appendingPathComponent("Pill/Sources/ShannonPill/MenuBarPopoverView.swift")
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("resourceRowsOrdered"))
        XCTAssertTrue(text.contains("most constrained"))
        XCTAssertTrue(text.contains(".disk") || text.contains("diskDetail"))
        XCTAssertTrue(text.contains("thermalDetail") || text.contains(".thermal"))
    }
}
