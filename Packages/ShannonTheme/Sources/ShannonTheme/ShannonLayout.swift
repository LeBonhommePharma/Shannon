import CoreGraphics

// MARK: - Platform layout specs
//
// The canonical geometry for each surface. These are the numbers the design
// system guarantees; a platform target should reference them rather than
// re-deriving sizes locally.

public enum ShannonLayout {

    /// macOS notch pill.
    ///
    /// **Collapsed on a physical notch (e.g. MacBook Pro 14")** — fills the
    /// measured menu-bar cutout (live `auxiliaryTop*` gap, e.g. ~220×38 pt) and
    /// hangs a small Dynamic-Island lip below the menu bar so the black island
    /// reads against the wallpaper (camera-only black is invisible as chrome).
    /// Shape is flush to the top of the display with a bottom lip radius only.
    ///
    /// **Collapsed without a notch** — 160×32pt capsule, or a narrower idle
    /// strip when recessive.
    ///
    /// **Expanded** — 400pt wide, height is content + padding, radius 20.
    public enum Pill {
        public static let collapsedWidth: CGFloat = 160
        public static let collapsedHeight: CGFloat = 32
        public static let collapsedRadius: CGFloat = ShannonRadius.lg   // 16
        /// Minimum / maximum collapsed strip height when hugging a notch band.
        public static let collapsedHeightMin: CGFloat = 28
        /// Menu-bar band only (no hang).
        public static let collapsedHeightMax: CGFloat = 42
        /// Extra height below the menu-bar band so the island hangs into the
        /// desktop (Dynamic Island style). Without this, pure band-height black
        /// sits only in the translucent menu strip and looks like “just the camera”.
        public static let physicalIslandOverhang: CGFloat = 10
        /// Ceiling for band + overhang (38+10 = 48 on common MBP scales).
        public static let physicalIslandHeightMax: CGFloat = 56

        /// Expanded board width — matches shipping `PillMetrics.expandedWidth`.
        public static let expandedWidth: CGFloat = 400
        public static let expandedRadius: CGFloat = ShannonRadius.xl    // 20

        /// Padding added above and below the expanded content (16 + 16 = 32).
        public static let expandedVerticalPadding: CGFloat = ShannonSpacing.md
        public static let expandedHorizontalPadding: CGFloat = ShannonSpacing.md

        /// Expanded height for a given intrinsic content height.
        public static func expandedHeight(contentHeight: CGFloat) -> CGFloat {
            contentHeight + expandedVerticalPadding * 2
        }

        /// Height that hugs a physical notch / menu-bar band.
        ///
        /// - Parameter notchBand: `NSScreen.safeAreaInsets.top` (or equivalent).
        /// - Parameter physicalNotch: when true (hardware cutout), fill the band
        ///   and add `physicalIslandOverhang` so the island is visible vs wallpaper.
        /// - Returns: full band (+ hang on hardware) clamped, or `collapsedHeight`
        ///   when the band is unknown.
        public static func collapsedHeight(
            notchBand: CGFloat?,
            physicalNotch: Bool = true
        ) -> CGFloat {
            guard let band = notchBand, band > 0 else { return collapsedHeight }
            if physicalNotch {
                let target = band + physicalIslandOverhang
                return min(max(target, collapsedHeightMin), physicalIslandHeightMax)
            }
            // Synthetic (external display): 1 pt hairline under the band.
            let target = band - 1
            return min(max(target, collapsedHeightMin), collapsedHeightMax)
        }

        /// Full-capsule radius for a collapsed strip of the given height
        /// (non-notched / synthetic displays only).
        public static func collapsedCorner(height: CGFloat) -> CGFloat { height / 2 }

        /// Bottom lip radius for the physical-notch island.
        ///
        /// The MacBook Pro cutout is flush with the top of the active display
        /// and only rounds at the bottom edge. Scale lip with total island height
        /// (band + overhang) so a 48 pt island still reads as a soft lip, not a capsule.
        public static func notchBottomRadius(height: CGFloat) -> CGFloat {
            min(max(height * 0.28, 11), 16)
        }

        /// Pure window frame: content centred on the notch, top-anchored to the
        /// screen (or notch) top so the panel grows downward — never clipped by
        /// the physical top edge.
        public static func windowFrame(
            contentSize: CGSize,
            notchRect: CGRect,
            screenFrame: CGRect,
            hasNotch: Bool
        ) -> CGRect {
            let width = max(contentSize.width, 1)
            let height = max(contentSize.height, 1)
            let x = notchRect.midX - width / 2
            let clampedX = min(max(x, screenFrame.minX + 4),
                               screenFrame.maxX - width - 4)
            let top = hasNotch ? max(screenFrame.maxY, notchRect.maxY) : screenFrame.maxY
            let y = top - height
            return CGRect(x: clampedX, y: y, width: width, height: height)
        }

        /// Default / idle collapsed widths when no physical notch is measured.
        public static let defaultCollapsedWidth: CGFloat = 200
        public static let defaultIdleWidth: CGFloat = 118
        /// Horizontal inset from the physical notch cutout edges (pt).
        /// Zero on hardware: any positive inset shows the black cutout beside the
        /// pill and breaks the "one island" silhouette (MBP 14" ≈ 220 pt wide).
        public static let notchWidthInset: CGFloat = 0
        public static let minCollapsedWidth: CGFloat = 96

        /// Width that hugs a measured hardware notch (or falls back to defaults).
        ///
        /// - Parameters:
        ///   - notchWidth: `NotchGeometry.notchRect.width` when `hasNotch`.
        ///   - recessive: quiet idle strip (narrower) — **ignored** when
        ///     `physicalNotch` is true so the island always covers the cutout.
        ///   - physicalNotch: hardware cutout present; fill full measured width.
        public static func collapsedWidth(
            notchWidth: CGFloat?,
            recessive: Bool,
            physicalNotch: Bool = false
        ) -> CGFloat {
            if let nw = notchWidth, nw > 40 {
                let full = max(nw - notchWidthInset * 2, minCollapsedWidth)
                // Always paint the full cutout on real hardware — shrinking idle
                // width floats a small capsule *inside* the black notch hole.
                if physicalNotch { return full }
                if recessive {
                    return min(defaultIdleWidth, full * 0.62)
                }
                return full
            }
            return recessive ? defaultIdleWidth : defaultCollapsedWidth
        }

        /// Gap between the icon and its label in the collapsed state.
        public static let iconTextSpacing: CGFloat = ShannonSpacing.sm
        public static let iconSize: CGFloat = 18
    }

    /// iOS card — full width minus 32pt (16pt page margin each side),
    /// radius 16, `shannonSurface` background, 16pt internal padding.
    public enum IOSCard {
        public static let pageMargin: CGFloat = ShannonSpacing.md       // 16
        public static let totalHorizontalInset: CGFloat = pageMargin * 2 // 32
        public static let radius: CGFloat = ShannonRadius.lg            // 16
        public static let padding: CGFloat = ShannonSpacing.md          // 16
        public static let interCardSpacing: CGFloat = ShannonSpacing.md
    }

    /// watchOS card — full width, radius 12, `shannonBackground` fill,
    /// 8pt padding, text clamped to 2 lines.
    public enum WatchCard {
        public static let radius: CGFloat = ShannonRadius.md            // 12
        public static let padding: CGFloat = ShannonSpacing.sm          // 8
        public static let maxTextLines: Int = 2
        public static let interCardSpacing: CGFloat = ShannonSpacing.sm
    }
}
