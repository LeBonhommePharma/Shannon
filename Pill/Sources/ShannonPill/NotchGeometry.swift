import AppKit
import PillCore

/// Resolves where the pill should sit on a given screen.
///
/// On notched Macs the notch occupies the middle of the menu bar; the usable
/// menu-bar strips either side are reported as `auxiliaryTopLeftArea` /
/// `auxiliaryTopRightArea`. On non-notched displays (and external monitors)
/// there is no notch, so we synthesise a pill of the same height centred on
/// the menu bar — the UI is identical, it just floats instead of hugging.
public struct NotchGeometry {
    public let hasNotch: Bool
    /// Rect of the notch itself (or the synthetic equivalent), in screen coords.
    public let notchRect: CGRect
    public let screenFrame: CGRect

    /// Fallback height for displays without a physical notch.
    public static let syntheticNotchHeight: CGFloat = 32

    public init(screen: NSScreen) {
        screenFrame = screen.frame

        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            let notchWidth = screen.frame.width - left.width - right.width
            notchRect = CGRect(
                x: screen.frame.minX + left.width,
                y: screen.frame.maxY - topInset,
                width: notchWidth,
                height: topInset
            )
        } else {
            hasNotch = false
            let w: CGFloat = 180
            notchRect = CGRect(
                x: screen.frame.midX - w / 2,
                y: screen.frame.maxY - Self.syntheticNotchHeight,
                width: w,
                height: Self.syntheticNotchHeight
            )
        }
    }

    /// Window frame for the pill at a given content size, centred on the notch
    /// and clamped so it never runs off either edge of the display.
    public func windowFrame(contentSize: CGSize) -> CGRect {
        let x = notchRect.midX - contentSize.width / 2
        let clampedX = min(max(x, screenFrame.minX + 4),
                           screenFrame.maxX - contentSize.width - 4)
        // Anchor the top edge to the top of the screen so the pill grows downward.
        let y = screenFrame.maxY - contentSize.height
        return CGRect(x: clampedX, y: y, width: contentSize.width, height: contentSize.height)
    }
}
