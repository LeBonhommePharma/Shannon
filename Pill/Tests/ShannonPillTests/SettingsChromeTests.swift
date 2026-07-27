import XCTest
@testable import ShannonPill

/// Settings chrome is fixed-size (same anti-thrash discipline as the popover).
final class SettingsChromeTests: XCTestCase {
    func testSettingsChromeIsFixedAndUsable() {
        XCTAssertEqual(SettingsView.chromeWidth, 360)
        // Glance + voice + pet package sections; tall enough that the pinned
        // Done footer is never cropped by title-bar safe area.
        XCTAssertEqual(SettingsView.chromeHeight, 580)
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
}
