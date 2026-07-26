import XCTest
@testable import ShannonCore

/// UX-010 — multi-OS status legend (amber ask · red collapse).
final class StatusLegendCopyTests: XCTestCase {

    func testLineTeachesAmberAndRed() {
        let s = StatusLegendCopy.line.lowercased()
        XCTAssertTrue(s.contains("amber"), StatusLegendCopy.line)
        XCTAssertTrue(s.contains("red"), StatusLegendCopy.line)
        XCTAssertTrue(
            s.contains("approval") || s.contains("ask"),
            StatusLegendCopy.line
        )
        XCTAssertTrue(s.contains("collapse"), StatusLegendCopy.line)
    }

    func testExactMacParityWording() {
        // Single source of truth — must stay equal to historical Mac chrome.
        XCTAssertEqual(
            StatusLegendCopy.line,
            "Amber = approval needed · Red = entropy collapse"
        )
    }

    func testAccessibilityMatchesLine() {
        XCTAssertEqual(
            StatusLegendCopy.accessibilityLabel,
            StatusLegendCopy.line
        )
        XCTAssertFalse(StatusLegendCopy.accessibilityLabel.isEmpty)
    }

    func testPhoneEmptyStateWiresSharedLegend() {
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
            phone.contains("StatusLegendCopy"),
            "phone EmptyStateView must surface shared status legend"
        )
        XCTAssertFalse(
            phone.contains("\"Amber = approval needed"),
            "phone must not hard-code dual-OS status legend"
        )
    }

    /// UX-022: pad EmptyHubState must teach the same amber/red legend as phone/Mac.
    func testPadEmptyHubWiresSharedLegend() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let pad = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/DashboardGridView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            pad.contains("StatusLegendCopy"),
            "pad EmptyHubState must surface shared status legend"
        )
        XCTAssertTrue(
            pad.contains("StatusLegendCopy.line"),
            "pad EmptyHubState must reference StatusLegendCopy.line"
        )
        XCTAssertFalse(
            pad.contains("\"Amber = approval needed"),
            "pad must not hard-code dual-OS status legend"
        )
    }
}
