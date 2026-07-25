import XCTest
@testable import ShannonPill

/// Settings chrome is fixed-size (same anti-thrash discipline as the popover).
final class SettingsChromeTests: XCTestCase {
    func testSettingsChromeIsFixedAndUsable() {
        XCTAssertEqual(SettingsView.chromeWidth, 360)
        XCTAssertEqual(SettingsView.chromeHeight, 420)
        XCTAssertGreaterThan(SettingsView.chromeWidth, 300)
        XCTAssertGreaterThan(SettingsView.chromeHeight, 360)
    }
}
