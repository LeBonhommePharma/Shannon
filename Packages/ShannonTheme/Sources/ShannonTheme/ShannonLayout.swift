import CoreGraphics

// MARK: - Platform layout specs
//
// The canonical geometry for each surface. These are the numbers the design
// system guarantees; a platform target should reference them rather than
// re-deriving sizes locally.

public enum ShannonLayout {

    /// macOS notch pill.
    ///
    /// **Collapsed** — 160×32pt, radius 16. A single line: icon + text, nothing
    /// else. At night it should be barely visible at rest.
    ///
    /// **Expanded** — 320pt wide, height is content + 32pt (16pt padding top and
    /// bottom), radius 20. Springs open from the centre with `.shannonFloat`,
    /// backed by an `NSVisualEffectView` using the `.hudWindow` material in both
    /// colour schemes.
    public enum Pill {
        public static let collapsedWidth: CGFloat = 160
        public static let collapsedHeight: CGFloat = 32
        public static let collapsedRadius: CGFloat = ShannonRadius.lg   // 16

        public static let expandedWidth: CGFloat = 320
        public static let expandedRadius: CGFloat = ShannonRadius.xl    // 20

        /// Padding added above and below the expanded content (16 + 16 = 32).
        public static let expandedVerticalPadding: CGFloat = ShannonSpacing.md
        public static let expandedHorizontalPadding: CGFloat = ShannonSpacing.md

        /// Expanded height for a given intrinsic content height.
        public static func expandedHeight(contentHeight: CGFloat) -> CGFloat {
            contentHeight + expandedVerticalPadding * 2
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
