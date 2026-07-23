import AppKit
import PillCore

/// Resolves where the pill should sit on a given screen.
///
/// On notched Macs the notch occupies the middle of the menu bar; the usable
/// menu-bar strips either side are reported as `auxiliaryTopLeftArea` /
/// `auxiliaryTopRightArea`. On non-notched displays (and external monitors)
/// there is no notch, so we synthesise a pill of the same height centred on
/// the menu bar — the UI is identical, it just floats instead of hugging.
///
/// macOS 27 (Tahoe) notes:
/// - Menu bar is more translucent ("Liquid Glass"); we still anchor to the
///   physical top of `screen.frame`, not `visibleFrame` (which excludes the
///   menu bar and would push the pill *below* the bar).
/// - `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` can briefly be nil during
///   display reconfiguration; we fall back to a centred synthetic notch.
/// - Prefer the screen under the mouse, then `NSScreen.main`, then first
///   notched screen — multi-monitor setups previously pinned to the wrong
///   display and looked like "the app does nothing".
public struct NotchGeometry {
    public let hasNotch: Bool
    /// Rect of the notch itself (or the synthetic equivalent), in screen coords.
    public let notchRect: CGRect
    public let screenFrame: CGRect
    /// Screen this geometry was computed for (retained for reposition).
    public let screen: NSScreen

    /// Fallback height for displays without a physical notch.
    public static let syntheticNotchHeight: CGFloat = 32
    /// Minimum synthetic notch width so a collapsed pill (240pt) still centres.
    public static let syntheticNotchWidth: CGFloat = 240

    public init(screen: NSScreen) {
        self.screen = screen
        screenFrame = screen.frame

        let topInset = screen.safeAreaInsets.top
        // macOS 12+: auxiliary areas frame the hardware notch. On some 27.x
        // betas they can be zero-width during sleep/wake; treat that as no notch.
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           left.width > 1, right.width > 1 {
            let notchWidth = screen.frame.width - left.width - right.width
            if notchWidth > 40 {
                hasNotch = true
                notchRect = CGRect(
                    x: screen.frame.minX + left.width,
                    y: screen.frame.maxY - topInset,
                    width: notchWidth,
                    height: topInset
                )
                return
            }
        }

        hasNotch = false
        let w = Self.syntheticNotchWidth
        // Prefer the menu-bar band: use safeAreaInsets.top when present (Stage
        // Manager / external displays with camera housing), else synthetic.
        let h = topInset > 0 ? topInset : Self.syntheticNotchHeight
        notchRect = CGRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.maxY - h,
            width: w,
            height: h
        )
    }

    /// Best screen for the pill on the current machine layout.
    public static func preferredScreen() -> NSScreen {
        // 1. Screen under the mouse (multi-monitor UX).
        let mouse = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underMouse
        }
        // 2. Main screen (menu-bar owning display).
        if let main = NSScreen.main { return main }
        // 3. First notched screen.
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        // 4. Anything.
        return NSScreen.screens.first ?? NSScreen.main!
    }

    /// Window frame for the pill at a given content size, centred on the notch
    /// and clamped so it never runs off either edge of the display.
    public func windowFrame(contentSize: CGSize) -> CGRect {
        let width = max(contentSize.width, 1)
        let height = max(contentSize.height, 1)
        let x = notchRect.midX - width / 2
        let clampedX = min(max(x, screenFrame.minX + 4),
                           screenFrame.maxX - width - 4)
        // Anchor the top edge to the top of the screen so the pill grows downward.
        // CRITICAL: use screen.frame.maxY, NOT visibleFrame — visibleFrame is
        // below the menu bar and would hide an LSUIElement under the desktop.
        let y = screenFrame.maxY - height
        return CGRect(x: clampedX, y: y, width: width, height: height)
    }
}
