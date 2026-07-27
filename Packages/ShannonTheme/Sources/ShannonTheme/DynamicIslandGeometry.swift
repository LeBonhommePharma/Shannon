import CoreGraphics
import SwiftUI

// MARK: - Dynamic Island geometry (AgentNotch-style)
//
// Pure policy + animatable shape for the Mac notch pill. Matches the silhouette
// used by AgentNotch / DynamicNotchKit: **inward top wing curves** into the
// bezel and an **outward bottom lip** — not a flat flush-top rectangle.

/// Closed / open corner radii and wing-width policy for the Shannon notch island.
public enum DynamicIslandGeometry: Sendable {

    // MARK: Radii (pt) — AgentNotch `cornerRadiusInsets`

    /// Closed island: inward top bite into the bezel.
    public static let closedTopRadius: CGFloat = 6
    /// Closed island: outward bottom lip.
    public static let closedBottomRadius: CGFloat = 14
    /// Expanded board: larger top wing.
    public static let openTopRadius: CGFloat = 19
    /// Expanded board: larger bottom lip.
    public static let openBottomRadius: CGFloat = 24

    /// Extra width past the pure camera hole when live work is present (each side).
    public static let wingExtension: CGFloat = 28
    /// Hard ceiling so wings never run into menu-bar clock / status items.
    public static let maxWingedWidth: CGFloat = 320
    /// Absolute floor for a winged island (must still fit a label + glyph).
    public static let minWingedWidth: CGFloat = 160

    public static func topRadius(expanded: Bool) -> CGFloat {
        expanded ? openTopRadius : closedTopRadius
    }

    public static func bottomRadius(expanded: Bool) -> CGFloat {
        expanded ? openBottomRadius : closedBottomRadius
    }

    /// Pure radii pair for morph animation.
    public static func radii(expanded: Bool) -> (top: CGFloat, bottom: CGFloat) {
        (topRadius(expanded: expanded), bottomRadius(expanded: expanded))
    }

    /// Whether the closed island may grow left/right wings past the cutout.
    public static func shouldWing(
        liveWork: Bool,
        hasPendingAsk: Bool = false,
        collapseAlarm: Bool = false
    ) -> Bool {
        liveWork || hasPendingAsk || collapseAlarm
    }

    /// Closed width with optional AgentNotch-style wings.
    ///
    /// - Parameters:
    ///   - baseWidth: hardware cutout width (or synthetic base) from
    ///     ``ShannonLayout/Pill/collapsedWidth(notchWidth:recessive:physicalNotch:)``.
    ///   - winged: when true, extend past the camera hole for live activity.
    ///   - physicalNotch: hardware cutout — wings only apply here.
    public static func closedWidth(
        baseWidth: CGFloat,
        winged: Bool,
        physicalNotch: Bool
    ) -> CGFloat {
        let base = max(baseWidth, 1)
        guard physicalNotch, winged else { return base }
        let extended = base + wingExtension * 2
        return min(max(extended, minWingedWidth), maxWingedWidth)
    }

    /// Policy snapshot for diagnostics / tests.
    public static var policySnapshot: [String: String] {
        [
            "closedTopRadius": "\(closedTopRadius)",
            "closedBottomRadius": "\(closedBottomRadius)",
            "openTopRadius": "\(openTopRadius)",
            "openBottomRadius": "\(openBottomRadius)",
            "wingExtension": "\(wingExtension)",
            "maxWingedWidth": "\(maxWingedWidth)",
        ]
    }

    // MARK: Path samples (pure, no SwiftUI)

    /// Sample points on the island outline for unit tests (rect in local coords).
    ///
    /// Returns key control points: top-left wing, bottom-left lip, bottom-right
    /// lip, top-right wing. Used to prove inward top / outward bottom geometry
    /// without rendering.
    public static func outlineKeyPoints(
        in rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> (
        topLeftInner: CGPoint,
        bottomLeftOuter: CGPoint,
        bottomRightOuter: CGPoint,
        topRightInner: CGPoint
    ) {
        let t = max(0, topRadius)
        let b = max(0, bottomRadius)
        return (
            topLeftInner: CGPoint(x: rect.minX + t, y: rect.minY + t),
            bottomLeftOuter: CGPoint(x: rect.minX + t + b, y: rect.maxY),
            bottomRightOuter: CGPoint(x: rect.maxX - t - b, y: rect.maxY),
            topRightInner: CGPoint(x: rect.maxX - t, y: rect.minY + t)
        )
    }

    /// True when top curves sit **inboard** of the left/right edges (wing bite)
    /// and bottom lip sits at `maxY` outside the vertical sides.
    public static func isInwardTopOutwardBottom(
        in rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> Bool {
        let p = outlineKeyPoints(in: rect, topRadius: topRadius, bottomRadius: bottomRadius)
        // Top inner points inset from left/right edges.
        let topInset = p.topLeftInner.x > rect.minX + 0.5
            && p.topRightInner.x < rect.maxX - 0.5
        // Bottom outer points further inset (lip curves out under the body).
        let bottomLip = p.bottomLeftOuter.y >= rect.maxY - 0.5
            && p.bottomLeftOuter.x > p.topLeftInner.x
            && p.bottomRightOuter.x < p.topRightInner.x
        return topInset && bottomLip
    }
}

// MARK: - SwiftUI shape

/// AgentNotch / DynamicNotchKit silhouette: inward top wings + outward bottom lip.
///
/// Animatable via ``animatableData`` so expand/collapse can spring the radii.
public struct NotchIslandShape: Shape {
    public var topCornerRadius: CGFloat
    public var bottomCornerRadius: CGFloat

    public init(
        topCornerRadius: CGFloat = DynamicIslandGeometry.closedTopRadius,
        bottomCornerRadius: CGFloat = DynamicIslandGeometry.closedBottomRadius
    ) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    public init(expanded: Bool) {
        let r = DynamicIslandGeometry.radii(expanded: expanded)
        self.topCornerRadius = r.top
        self.bottomCornerRadius = r.bottom
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let top = max(0, topCornerRadius)
        let bottom = max(0, bottomCornerRadius)
        var path = Path()

        // Start top-left (outer bezel corner).
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left curve (inward wing).
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        // Left edge down.
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))

        // Bottom-left curve (outward lip).
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )

        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))

        // Bottom-right curve (outward lip).
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )

        // Right edge up.
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))

        // Top-right curve (inward wing).
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )

        // Top edge back to start.
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
