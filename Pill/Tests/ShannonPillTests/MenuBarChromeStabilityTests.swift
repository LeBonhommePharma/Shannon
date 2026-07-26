import XCTest
import CoreGraphics
@testable import ShannonPill
@testable import PillCore

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
        XCTAssertEqual(
            MenuBarPopoverView.fixedContentSize,
            CGSize(width: w1, height: h1)
        )
    }

    /// Live metric ticks used to push wild intrinsic sizes into NSPopover.
    /// Shipped clamp must always return fixed chrome regardless of proposal.
    func testClampedContentSizeIgnoresThrashProposals() {
        let fixed = MenuBarPopoverView.fixedContentSize
        let proposals: [CGSize] = [
            .zero,
            CGSize(width: 1, height: 1),
            CGSize(width: 900, height: 2_000),
            CGSize(width: fixed.width, height: fixed.height + 120),
            CGSize(width: fixed.width - 80, height: fixed.height - 200),
            CGSize(width: fixed.width + 0.5, height: fixed.height - 0.25),
        ]
        for proposed in proposals {
            let clamped = MenuBarPopoverView.clampedContentSize(proposed: proposed)
            XCTAssertEqual(
                clamped, fixed,
                "proposed \(proposed) must not reflow chrome (would move Quit)"
            )
        }
        // Consecutive ticks with changing proposals still pin to one size.
        var last = MenuBarPopoverView.clampedContentSize(proposed: .zero)
        for i in 0..<12 {
            let thrash = CGSize(width: 100 + CGFloat(i * 37), height: 50 + CGFloat(i * 19))
            let next = MenuBarPopoverView.clampedContentSize(proposed: thrash)
            XCTAssertEqual(next, last)
            XCTAssertEqual(next, fixed)
            last = next
        }
    }

    /// Quit hit target must stay a usable minimum under horizontal squeeze
    /// (long multi-device footer line must not clip the control away).
    func testQuitHitTargetHasUsableMinimumSize() {
        XCTAssertGreaterThanOrEqual(MenuBarPopoverView.quitMinWidth, 56)
        XCTAssertGreaterThanOrEqual(MenuBarPopoverView.quitMinHeight, 24)
        XCTAssertEqual(
            MenuBarPopoverView.quitMinHeight,
            MenuBarPopoverView.footerActionRowHeight
        )
        // Quit must fit inside fixed chrome with room for icons + padding.
        // chromeWidth 320 − horizontal padding 28 − two 28pt icons − gaps ≈ 220+
        // available; quitMinWidth must leave that path viable.
        let horizontalPadding: CGFloat = 28
        let iconButtons: CGFloat = 28 * 2 + 6 * 2
        let remaining = MenuBarPopoverView.chromeWidth - horizontalPadding - iconButtons
        XCTAssertGreaterThan(
            remaining, MenuBarPopoverView.quitMinWidth,
            "chrome too narrow: Quit would be forced to compress/clip"
        )
    }

    /// Press style must not shrink the hit target (no scale-away mid-click).
    func testQuietButtonPressDoesNotShrinkHitTarget() {
        XCTAssertEqual(
            ShannonQuietButtonStyle.pressedScale, 1.0,
            "pressedScale must stay identity so Quit geometry is fixed on press"
        )
        XCTAssertGreaterThan(ShannonQuietButtonStyle.pressedOpacity, 0)
        XCTAssertLessThan(ShannonQuietButtonStyle.pressedOpacity, 1.0)
        // Dim-only feedback is the product rule: opacity changes, scale does not.
        XCTAssertNotEqual(
            ShannonQuietButtonStyle.pressedOpacity, 1.0,
            "press must still give opacity feedback"
        )
    }

    /// Timer thrash guard: identical content must not re-paint fixed chrome
    /// (the path that used to reflow the pinned Quit footer).
    func testFixedChromeThrashGuardBlocksIdenticalTicks() {
        XCTAssertFalse(
            UICadence.shouldAllowTimerChromePaint(contentChanged: false),
            "identical ticks must not thrash fixed chrome / Quit footer"
        )
        XCTAssertTrue(
            UICadence.shouldAllowTimerChromePaint(contentChanged: true),
            "real content change must still paint"
        )
        // Glyph path used by MenuBarController for status-item ticks.
        let sig = UICadence.menuBarGlyphSignature(
            pendingCount: 0, collapseBits: nil, busyCount: 0,
            primaryBusyName: "", liveCount: 1, bridgeConnected: true,
            constrainedKey: "cpu:0", coresKey: "c:8"
        )
        XCTAssertFalse(
            UICadence.shouldPaintMenuBarGlyph(previousSignature: sig, nextSignature: sig)
        )
        let next = UICadence.menuBarGlyphSignature(
            pendingCount: 1, collapseBits: nil, busyCount: 0,
            primaryBusyName: "", liveCount: 1, bridgeConnected: true,
            constrainedKey: "cpu:0", coresKey: "c:8"
        )
        XCTAssertTrue(
            UICadence.shouldPaintMenuBarGlyph(previousSignature: sig, nextSignature: next)
        )
    }
}
