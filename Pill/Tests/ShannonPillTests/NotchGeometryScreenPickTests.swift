import XCTest
@testable import ShannonPill
import CoreGraphics
import ShannonTheme

/// Multi-monitor ranking must prefer the screen under the mouse (macOS 27 UX).
final class NotchGeometryScreenPickTests: XCTestCase {

    func testMouseScreenWins() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        ]
        let idx = NotchGeometry.pickPreferredScreenIndex(
            mouse: CGPoint(x: 1600, y: 100),
            screenFrames: frames,
            safeAreaTops: [32, 0],
            mainIndex: 0
        )
        XCTAssertEqual(idx, 1, "mouse on external monitor must win over main")
    }

    func testMainWhenMouseNotOnAnyScreen() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        ]
        let idx = NotchGeometry.pickPreferredScreenIndex(
            mouse: CGPoint(x: -100, y: -100),
            screenFrames: frames,
            safeAreaTops: [32, 0],
            mainIndex: 0
        )
        XCTAssertEqual(idx, 0)
    }

    func testNotchedFallbackWhenNoMain() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1440, height: 900),
        ]
        let idx = NotchGeometry.pickPreferredScreenIndex(
            mouse: CGPoint(x: -1, y: -1),
            screenFrames: frames,
            safeAreaTops: [0, 38],
            mainIndex: nil
        )
        XCTAssertEqual(idx, 1, "first notched display when main unknown")
    }

    func testAnchorsToFrameTopNotVisibleFrame() {
        // Notch rect must sit on screen.frame.maxY (physical top), not below
        // the menu bar band the way visibleFrame would place it.
        // Pure layout helper used by windowFrame.
        let notch = CGRect(x: 600, y: 900 - 32, width: 220, height: 32)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = ShannonLayout.Pill.windowFrame(
            contentSize: CGSize(width: 200, height: 28),
            notchRect: notch,
            screenFrame: screen,
            hasNotch: true,
            hangBelowMenuBar: false
        )
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 1.0)
        XCTAssertGreaterThan(frame.maxY, screen.maxY - 40)
    }
}
