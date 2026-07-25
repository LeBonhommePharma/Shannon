import XCTest
@testable import PillCore

/// The notch panel is top-anchored on `screen.frame.maxY`, so a window taller
/// than its display is drawn past the top edge and lost. Two paths set the
/// height — content measurement and screen-parameter changes — and they had
/// drifted: only the content path applied the `maxHeightFraction` ceiling, so a
/// panel grown tall on a large display carried that height verbatim onto a
/// smaller one. Both go through the same clamp now; these tests exist to keep
/// them from drifting again.
final class PillPanelHeightTests: XCTestCase {

    // Real values from PillMetrics: floor 220, maxHeightFraction 0.6.
    private let floor: CGFloat = 220
    private let fraction: CGFloat = 0.6

    // MARK: clamped

    func testClampedAppliesFloor() {
        XCTAssertEqual(
            PillPanelHeight.clamped(100, floor: floor, screenHeight: 1200, maxFraction: fraction),
            220
        )
    }

    func testClampedAppliesCeiling() {
        XCTAssertEqual(
            PillPanelHeight.clamped(900, floor: floor, screenHeight: 1000, maxFraction: fraction),
            600
        )
    }

    func testClampedPassesThroughInBandHeight() {
        XCTAssertEqual(
            PillPanelHeight.clamped(430, floor: floor, screenHeight: 1200, maxFraction: fraction),
            430
        )
    }

    /// On a display shorter than `floor / maxFraction` the two bounds cross.
    /// Overflowing the screen is the failure this clamp exists to prevent, so
    /// the ceiling must win.
    func testCeilingWinsWhenBoundsCross() {
        XCTAssertEqual(
            PillPanelHeight.clamped(400, floor: floor, screenHeight: 300, maxFraction: fraction),
            180
        )
    }

    // MARK: onScreenChange — the path that had no ceiling

    /// The defect: a panel grown to 900 pt on a 1600 pt display, moved to a
    /// 1000 pt display, must come back to 600 pt (0.6 × 1000) rather than stay
    /// at 900.
    func testScreenChangeClampsGrownHeightToTheNewScreen() {
        XCTAssertEqual(
            PillPanelHeight.onScreenChange(
                currentHeight: 900, floor: floor, screenHeight: 1000, maxFraction: fraction
            ),
            600
        )
    }

    /// Still keeps the height the content grew to when it fits — recomputing
    /// from the floor on every resolution switch would shrink the board back
    /// exactly when it needs its room.
    func testScreenChangeKeepsGrownHeightThatStillFits() {
        XCTAssertEqual(
            PillPanelHeight.onScreenChange(
                currentHeight: 430, floor: floor, screenHeight: 1600, maxFraction: fraction
            ),
            430
        )
    }

    func testScreenChangeStillAppliesFloor() {
        XCTAssertEqual(
            PillPanelHeight.onScreenChange(
                currentHeight: 40, floor: floor, screenHeight: 1600, maxFraction: fraction
            ),
            220
        )
    }

    // MARK: The two paths must not diverge

    /// One clamp, two entry points. Any height that reaches the panel via a
    /// screen change must be a height the content path would also have allowed.
    func testBothPathsAgreeAcrossScreenSizesAndHeights() {
        for screenHeight in [300, 800, 1000, 1200, 1600, 2160].map(CGFloat.init) {
            for height in [0, 100, 220, 430, 900, 4000].map(CGFloat.init) {
                let viaScreenChange = PillPanelHeight.onScreenChange(
                    currentHeight: height, floor: floor,
                    screenHeight: screenHeight, maxFraction: fraction
                )
                let viaContent = PillPanelHeight.onContentHeight(
                    height, floor: floor, screenHeight: screenHeight, maxFraction: fraction
                )
                XCTAssertEqual(
                    viaScreenChange, viaContent,
                    "screen \(screenHeight) height \(height): reposition gave \(viaScreenChange), "
                        + "resizeToContent gave \(viaContent)"
                )
                XCTAssertLessThanOrEqual(
                    viaScreenChange, screenHeight * fraction,
                    "screen \(screenHeight) height \(height): panel exceeds its ceiling"
                )
            }
        }
    }
}
