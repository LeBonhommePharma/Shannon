import CoreGraphics

/// The 8pt grid. `xs` is the one half-step, for tight icon/label pairings.
///
/// Nothing in Shannon should use a bare numeric literal for padding — if a
/// value is missing here, add it here rather than inlining it at the call site.
public enum ShannonSpacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48
}

/// Corner radii, kept alongside spacing because they are chosen together —
/// a 16pt-padded card wants a 16pt radius.
public enum ShannonRadius {
    /// Chips, badges, inline pills.
    public static let sm: CGFloat = 8
    /// watchOS cards.
    public static let md: CGFloat = 12
    /// iOS cards, collapsed Mac pill.
    public static let lg: CGFloat = 16
    /// Expanded Mac pill.
    public static let xl: CGFloat = 20
}

/// Hairline and glow metrics for the pill chrome.
public enum ShannonStroke {
    /// Border width at rest and when active. Deliberately sub-pixel on Retina —
    /// the pill edge should read as a seam, not a drawn outline.
    public static let hairline: CGFloat = 0.5
    /// Blur radius of the active-state accent glow.
    public static let glowRadius: CGFloat = 8
    /// Opacity of the active-state accent glow.
    public static let glowOpacity: Double = 0.4
}
