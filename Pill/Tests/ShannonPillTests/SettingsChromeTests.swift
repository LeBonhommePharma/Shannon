import XCTest
@testable import ShannonPill

/// Settings chrome is fixed-size (same anti-thrash discipline as the popover).
final class SettingsChromeTests: XCTestCase {
    func testSettingsChromeIsFixedAndUsable() {
        XCTAssertEqual(SettingsView.chromeWidth, 360)
        // UX-058: room for floating glance toggle.
        XCTAssertEqual(SettingsView.chromeHeight, 460)
        XCTAssertGreaterThan(SettingsView.chromeWidth, 300)
        XCTAssertGreaterThan(SettingsView.chromeHeight, 360)
    }
}
