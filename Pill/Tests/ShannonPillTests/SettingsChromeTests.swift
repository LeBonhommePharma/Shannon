import XCTest
@testable import ShannonPill

/// Settings chrome is fixed-size (same anti-thrash discipline as the popover).
final class SettingsChromeTests: XCTestCase {
    func testSettingsChromeIsFixedAndUsable() {
        XCTAssertEqual(SettingsView.chromeWidth, 380)
        // Glance + voice + **pet grid**; tall enough that the pinned
        // Done footer is never cropped by title-bar safe area.
        XCTAssertEqual(SettingsView.chromeHeight, 640)
        XCTAssertGreaterThan(SettingsView.chromeWidth, 300)
        XCTAssertGreaterThan(SettingsView.chromeHeight, 500)
    }

    /// Done lives in a reserved bottom band — min height must stay tappable.
    func testDoneFooterHasUsableMinimumHeight() {
        XCTAssertGreaterThanOrEqual(SettingsView.footerMinHeight, 44)
        // Footer band must fit inside chrome with room for header + scroll.
        let headerBand: CGFloat = 52
        let remaining = SettingsView.chromeHeight - headerBand - SettingsView.footerMinHeight
        XCTAssertGreaterThan(
            remaining, 200,
            "scroll body would be crushed; Done would sit on cropped chrome"
        )
    }

    /// Settings sources pin Done via safe-area footer (not hard-stacked crop).
    func testSettingsSourcePinsDoneInSafeAreaFooter() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ShannonPill/SettingsView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("safeAreaInset(edge: .bottom"), src)
        XCTAssertTrue(src.contains("DesktopPetSelector"), "easy pet selector model wired")
        XCTAssertTrue(src.contains("LazyVGrid"), "browseable pet grid, not bare menu only")
        XCTAssertTrue(src.contains("footerMinHeight"), src)
    }
}
