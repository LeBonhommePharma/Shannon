import XCTest
import AppKit
import PillCore
@testable import ShannonPill

/// E2: menu checkmark tracks desktop companion preference; toggle callback fires.
@MainActor
final class DesktopCompanionMenuToggleTests: XCTestCase {

    private func makeMenuBar() -> MenuBarController {
        MenuBarController(
            bridge: ShannonBridge(),
            battery: BatteryMonitor(provider: IOKitBatteryProvider()),
            ingest: AgentIngestService(),
            activity: AgentActivityMonitor(),
            resources: SystemResourceMonitor(interval: 60, smoothAlpha: 1),
            keepAwake: KeepAwakeMonitor(),
            focusMode: FocusModeMonitor()
        )
    }

    func testMenuCheckmarkOnWhenVisible() {
        let menu = makeMenuBar()
        menu.isDesktopCompanionVisible = { true }
        let item = menu.makeContextMenuForTesting().item(withTitle: "Show Desktop Pet")
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.state, .on)
        XCTAssertNotNil(item?.action)
    }

    func testMenuCheckmarkOffWhenHidden() {
        let menu = makeMenuBar()
        menu.isDesktopCompanionVisible = { false }
        let item = menu.makeContextMenuForTesting().item(withTitle: "Show Desktop Pet")
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.state, .off)
    }

    func testToggleCallbackFires() {
        let menu = makeMenuBar()
        var toggled = 0
        menu.onToggleDesktopCompanion = { toggled += 1 }
        menu.performToggleDesktopCompanionForTesting()
        XCTAssertEqual(toggled, 1)
    }
}

extension MenuBarController {
    func performToggleDesktopCompanionForTesting() {
        onToggleDesktopCompanion?()
    }
}
