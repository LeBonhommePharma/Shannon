import XCTest
@testable import ShannonPill

/// Settings chrome is fixed-size (same anti-thrash discipline as the popover).
final class SettingsChromeTests: XCTestCase {
    func testSettingsChromeIsFixedAndUsable() {
        XCTAssertEqual(SettingsView.chromeWidth, 360)
        // UX-058 + ENH-030: room for glance + voice callout toggles.
        XCTAssertEqual(SettingsView.chromeHeight, 520)
        XCTAssertGreaterThan(SettingsView.chromeWidth, 300)
        XCTAssertGreaterThan(SettingsView.chromeHeight, 360)
    }
}
