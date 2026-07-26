import AppKit
import PillCore
import ShannonTheme

/// Resolves where the pill should sit on a given screen.
///
/// On notched Macs (MacBook Pro 14"/16") the camera cutout occupies the middle
/// of the menu bar. Usable menu-bar strips either side are reported as
/// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. The derived `notchRect`
/// is the exact black hole the collapsed island must fill — measured live, not
/// hard-coded (width/height change with resolution scaling).
///
/// Example (14" MBP, common "More Space" scale, probed live):
///   safeArea.top = 38, notch width = 220, centred on the display.
///
/// On non-notched displays (external monitors) there is no cutout, so we
/// synthesise a pill-sized band centred on the menu bar — the UI is identical,
/// it just floats instead of hugging hardware.
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
    /// Pixel-snapped so the island chrome lands on whole points.
    public let notchRect: CGRect
    public let screenFrame: CGRect
    /// Screen this geometry was computed for (retained for reposition).
    public let screen: NSScreen

    /// Fallback height for displays without a physical notch.
    public static let syntheticNotchHeight: CGFloat = 32
    /// Synthetic notch width for displays with no physical notch, so the
    /// collapsed pill centres within it. Always tracks `PillMetrics.collapsedWidth`.
    public static var syntheticNotchWidth: CGFloat { PillMetrics.collapsedWidth }

    /// Physical notch band height (safe-area top), or synthetic height when
    /// there is no hardware cutout. Use this for collapsed pill height.
    public var bandHeight: CGFloat { notchRect.height }

    /// Convenience: same as `hasNotch` — true only for a real camera cutout.
    public var isPhysical: Bool { hasNotch }

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
            // Real MBP cutouts are ~150–230 pt depending on scale; reject noise.
            if notchWidth > 40, notchWidth < screen.frame.width * 0.45 {
                hasNotch = true
                // Snap to whole points so the black island doesn't leave a
                // sub-pixel seam beside the camera housing.
                let x = (screen.frame.minX + left.width).rounded(.toNearestOrAwayFromZero)
                let w = notchWidth.rounded(.toNearestOrAwayFromZero)
                let h = topInset.rounded(.toNearestOrAwayFromZero)
                let y = (screen.frame.maxY - h).rounded(.toNearestOrAwayFromZero)
                notchRect = CGRect(x: x, y: y, width: w, height: h)
                return
            }
        }

        // Some notched Macs briefly report nil aux areas while still advertising
        // a non-zero top safe area (sleep/wake, clamshell). Prefer a centred
        // physical-sized band over a synthetic default so we don't shrink the
        // island under the camera.
        if topInset >= 28 {
            hasNotch = true
            let h = topInset.rounded(.toNearestOrAwayFromZero)
            // MBP 14"/16" cutouts cluster near ~200–220 pt at typical scales.
            let w = max(PillMetrics.collapsedWidth, 200 as CGFloat)
                .rounded(.toNearestOrAwayFromZero)
            notchRect = CGRect(
                x: (screen.frame.midX - w / 2).rounded(.toNearestOrAwayFromZero),
                y: (screen.frame.maxY - h).rounded(.toNearestOrAwayFromZero),
                width: w,
                height: h
            )
            return
        }

        hasNotch = false
        let w = Self.syntheticNotchWidth
        let h = Self.syntheticNotchHeight
        notchRect = CGRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.maxY - h,
            width: w,
            height: h
        )
    }

    /// Best screen for the pill on the current machine layout.
    public static func preferredScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        if let pick = Self.pickPreferredScreen(
            mouse: mouse,
            screens: screens.map { ($0, $0.frame, $0.safeAreaInsets.top) },
            main: NSScreen.main.map { ($0, $0.frame, $0.safeAreaInsets.top) }
        ) {
            return pick.0
        }
        return NSScreen.screens.first ?? NSScreen.main!
    }

    /// Pure multi-monitor ranking (unit-tested without AppKit display hardware).
    ///
    /// 1. Screen under the mouse  
    /// 2. Main (menu-bar owning) display  
    /// 3. First notched screen (`safeAreaInsets.top > 0`)  
    /// 4. First listed screen  
    public static func pickPreferredScreenIndex(
        mouse: CGPoint,
        screenFrames: [CGRect],
        safeAreaTops: [CGFloat],
        mainIndex: Int?
    ) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        // 1. Under mouse
        for (i, frame) in screenFrames.enumerated() where frame.contains(mouse) {
            return i
        }
        // 2. Main
        if let mainIndex, mainIndex >= 0, mainIndex < screenFrames.count {
            return mainIndex
        }
        // 3. First notched
        if let i = safeAreaTops.firstIndex(where: { $0 > 0 }) {
            return i
        }
        // 4. First
        return 0
    }

    private static func pickPreferredScreen(
        mouse: CGPoint,
        screens: [(NSScreen, CGRect, CGFloat)],
        main: (NSScreen, CGRect, CGFloat)?
    ) -> (NSScreen, CGRect, CGFloat)? {
        guard !screens.isEmpty else { return nil }
        let mainIndex = main.flatMap { m in screens.firstIndex(where: { $0.0 === m.0 }) }
        guard let idx = pickPreferredScreenIndex(
            mouse: mouse,
            screenFrames: screens.map(\.1),
            safeAreaTops: screens.map(\.2),
            mainIndex: mainIndex
        ) else { return nil }
        return screens[idx]
    }

    /// Window frame for the pill at a given content size, centred on the notch
    /// and clamped so it never runs off either edge of the display.
    ///
    /// - Parameter hangBelowMenuBar: when true (expanded board on a physical
    ///   notch), the panel top sits on the bottom of the menu-bar band so the
    ///   header is not clipped by the camera cutout.
    public func windowFrame(contentSize: CGSize, hangBelowMenuBar: Bool = false) -> CGRect {
        ShannonLayout.Pill.windowFrame(
            contentSize: contentSize,
            notchRect: notchRect,
            screenFrame: screenFrame,
            hasNotch: hasNotch,
            hangBelowMenuBar: hangBelowMenuBar
        )
    }

    /// Ideal collapsed content size that paints the hardware cutout (or synthetic band).
    public func collapsedContentSize(recessive: Bool) -> CGSize {
        let h = PillMetrics.collapsedHeight(
            notchBand: bandHeight,
            physicalNotch: hasNotch
        )
        let w = PillMetrics.collapsedWidth(
            notchWidth: hasNotch ? notchRect.width : nil,
            recessive: recessive,
            physicalNotch: hasNotch
        )
        return CGSize(width: w, height: h)
    }
}
