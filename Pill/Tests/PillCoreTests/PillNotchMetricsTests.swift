import XCTest
import ShannonTheme
@testable import PillCore

/// Notch-first layout invariants (design-system tokens).
///
/// Pins geometry that makes the HUD fill the **physical** MacBook cutout
/// (MBP 14" typically ~220×38 pt band + hang): full measured width, lip not
/// capsule, top-anchored window frame.
final class PillNotchMetricsTests: XCTestCase {

    func testCollapsedHeightDefault() {
        XCTAssertEqual(ShannonLayout.Pill.collapsedHeight, 32, accuracy: 0.01)
    }

    /// MBP 14" live probe: safeArea.top = 38 → band + overhang on hardware.
    func testPhysicalNotchHeightFillsMBPBandPlusHang() {
        let h = ShannonLayout.Pill.collapsedHeight(notchBand: 38, physicalNotch: true)
        XCTAssertEqual(
            h,
            38 + ShannonLayout.Pill.physicalIslandOverhang,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ShannonLayout.Pill.collapsedHeight(notchBand: 37, physicalNotch: true),
            37 + ShannonLayout.Pill.physicalIslandOverhang,
            accuracy: 0.01
        )
    }

    func testSyntheticNotchHeightLeavesHairline() {
        XCTAssertEqual(
            ShannonLayout.Pill.collapsedHeight(notchBand: 37, physicalNotch: false),
            36,
            accuracy: 0.01
        )
    }

    func testCollapsedHeightFallbacks() {
        XCTAssertEqual(
            ShannonLayout.Pill.collapsedHeight(notchBand: nil),
            ShannonLayout.Pill.collapsedHeight,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ShannonLayout.Pill.collapsedHeight(notchBand: 0),
            ShannonLayout.Pill.collapsedHeight,
            accuracy: 0.01
        )
        // Tiny band + hang still clamps up to min (10+10=20 → min 28).
        XCTAssertEqual(
            ShannonLayout.Pill.collapsedHeight(notchBand: 10, physicalNotch: true),
            ShannonLayout.Pill.collapsedHeightMin,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ShannonLayout.Pill.collapsedHeight(notchBand: 50, physicalNotch: true),
            ShannonLayout.Pill.physicalIslandHeightMax,
            accuracy: 0.01
        )
    }

    func testCollapsedCornerIsCapsule() {
        let h: CGFloat = 32
        XCTAssertEqual(ShannonLayout.Pill.collapsedCorner(height: h), h / 2, accuracy: 0.01)
    }

    func testCollapsedRadiusMatchesHalfDefaultHeight() {
        XCTAssertEqual(
            ShannonLayout.Pill.collapsedRadius,
            ShannonLayout.Pill.collapsedHeight / 2,
            accuracy: 0.01
        )
    }

    /// Physical island: bottom lip &lt; h/2 — not a full capsule.
    func testNotchBottomRadiusIsLipNotCapsule() {
        let h = ShannonLayout.Pill.collapsedHeight(notchBand: 38, physicalNotch: true)
        let lip = ShannonLayout.Pill.notchBottomRadius(height: h)
        XCTAssertGreaterThanOrEqual(lip, 11)
        XCTAssertLessThanOrEqual(lip, 16)
        XCTAssertLessThan(lip, h / 2, "full capsule would leave top wedges in the cutout")
    }

    /// MBP 14" measured cutout ~220 pt — fill full width; recessive must not shrink.
    func testPhysicalNotchWidthFillsMBPCutout() {
        let mbpW: CGFloat = 220
        let full = ShannonLayout.Pill.collapsedWidth(
            notchWidth: mbpW, recessive: false, physicalNotch: true
        )
        XCTAssertEqual(full, 220, accuracy: 0.01)
        let idle = ShannonLayout.Pill.collapsedWidth(
            notchWidth: mbpW, recessive: true, physicalNotch: true
        )
        XCTAssertEqual(idle, 220, accuracy: 0.01, "idle must still paint the black hole")
    }

    func testPhysicalNotchWidthNoInset() {
        XCTAssertEqual(ShannonLayout.Pill.notchWidthInset, 0, accuracy: 0.01)
        let w = ShannonLayout.Pill.collapsedWidth(
            notchWidth: 180, recessive: false, physicalNotch: true
        )
        XCTAssertEqual(w, 180, accuracy: 0.01)
    }

    func testSyntheticWidthMayRecess() {
        let full = ShannonLayout.Pill.collapsedWidth(
            notchWidth: 200, recessive: false, physicalNotch: false
        )
        XCTAssertEqual(full, 200, accuracy: 0.01)
        let idle = ShannonLayout.Pill.collapsedWidth(
            notchWidth: 200, recessive: true, physicalNotch: false
        )
        XCTAssertLessThan(idle, full)
        XCTAssertGreaterThanOrEqual(idle, ShannonLayout.Pill.minCollapsedWidth * 0.5)
    }

    func testCollapsedWidthFallbackWithoutNotch() {
        XCTAssertEqual(
            ShannonLayout.Pill.collapsedWidth(notchWidth: nil, recessive: false),
            ShannonLayout.Pill.defaultCollapsedWidth,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ShannonLayout.Pill.collapsedWidth(notchWidth: nil, recessive: true),
            ShannonLayout.Pill.defaultIdleWidth,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ShannonLayout.Pill.collapsedWidth(notchWidth: 20, recessive: false),
            ShannonLayout.Pill.defaultCollapsedWidth,
            accuracy: 0.01
        )
    }

    /// Top-anchored window frame: top edge on screen maxY / notch maxY.
    func testWindowFrameTopAnchorsToNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let notch = CGRect(x: 790, y: 1169 - 38, width: 220, height: 38)
        let content = CGSize(width: 220, height: 48)
        let frame = ShannonLayout.Pill.windowFrame(
            contentSize: content,
            notchRect: notch,
            screenFrame: screen,
            hasNotch: true
        )
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.01)
        XCTAssertEqual(frame.midX, notch.midX, accuracy: 0.01)
        XCTAssertEqual(frame.width, 220, accuracy: 0.01)
        XCTAssertEqual(frame.height, 48, accuracy: 0.01)
        // Grows downward: minY below notch band
        XCTAssertLessThan(frame.minY, notch.minY + 1)
    }

    func testPanelHeightClamp() {
        let c = PillPanelHeight.clamped(500, floor: 220, screenHeight: 1169, maxFraction: 0.6)
        XCTAssertLessThanOrEqual(c, 1169 * 0.6 + 0.01)
        XCTAssertGreaterThanOrEqual(c, 220)
        let short = PillPanelHeight.clamped(500, floor: 220, screenHeight: 300, maxFraction: 0.6)
        XCTAssertEqual(short, 180, accuracy: 0.01) // ceiling wins
    }
}
