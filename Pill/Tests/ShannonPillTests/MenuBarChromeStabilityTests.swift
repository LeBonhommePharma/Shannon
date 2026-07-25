import XCTest
@testable import ShannonPill

/// Popover chrome must stay a fixed size while open so the Quit control cannot
/// "escape" the cursor when live HUD values refresh.
final class MenuBarChromeStabilityTests: XCTestCase {

    func testPopoverChromeSizeIsFixedAndUsable() {
        // Width: enough for gauges + labeled Quit; height: room for scroll body
        // + pinned footer. Values are intentional product constants.
        XCTAssertEqual(MenuBarPopoverView.chromeWidth, 320)
        XCTAssertEqual(MenuBarPopoverView.chromeHeight, 448)
        XCTAssertGreaterThan(MenuBarPopoverView.chromeWidth, 280)
        XCTAssertGreaterThan(MenuBarPopoverView.chromeHeight, 360)
        // Aspect roughly "menu, not sheet".
        let aspect = MenuBarPopoverView.chromeHeight / MenuBarPopoverView.chromeWidth
        XCTAssertGreaterThan(aspect, 1.0)
        XCTAssertLessThan(aspect, 2.0)
    }

    func testChromeSizeStableAcrossRepeatedReads() {
        // Guard against accidental computed/dynamic chrome that would reflow.
        let w1 = MenuBarPopoverView.chromeWidth
        let h1 = MenuBarPopoverView.chromeHeight
        let w2 = MenuBarPopoverView.chromeWidth
        let h2 = MenuBarPopoverView.chromeHeight
        XCTAssertEqual(w1, w2)
        XCTAssertEqual(h1, h2)
    }
}
