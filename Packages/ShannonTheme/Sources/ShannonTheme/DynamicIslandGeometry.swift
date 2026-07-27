import CoreGraphics
import SwiftUI

// MARK: - Dynamic Island geometry (AgentNotch-style)
//
// Pure policy + animatable shape for the Mac notch pill. Matches the silhouette
// used by AgentNotch / DynamicNotchKit: **inward top wing curves** into the
// bezel and an **outward bottom lip** — not an inverted keystone (wide top /
// narrow bottom), which stroked as inverted parentheses under the camera.

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

    /// Key outline points for unit tests (rect in local coords).
    ///
    /// Geometry contract for a **full-width body** uneven rounded rect
    /// (correct Dynamic Island — not an inverted keystone):
    /// - Top edge sits at `minY`, inset by `topRadius` from left/right.
    /// - Bottom edge sits at `maxY`, inset by `bottomRadius` from left/right.
    /// - Vertical sides run at `minX` / `maxX` (full body width).
    /// - Bottom lip radius is typically larger than top wing radius.
    public static func outlineKeyPoints(
        in rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> (
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomLeft: CGPoint,
        bottomRight: CGPoint,
        leftSideX: CGFloat,
        rightSideX: CGFloat
    ) {
        let t = max(0, topRadius)
        let b = max(0, bottomRadius)
        return (
            topLeft: CGPoint(x: rect.minX + t, y: rect.minY),
            topRight: CGPoint(x: rect.maxX - t, y: rect.minY),
            bottomLeft: CGPoint(x: rect.minX + b, y: rect.maxY),
            bottomRight: CGPoint(x: rect.maxX - b, y: rect.maxY),
            leftSideX: rect.minX,
            rightSideX: rect.maxX
        )
    }

    /// True when the outline is a non-inverted island:
    /// full-width vertical sides, top edge at `minY`, bottom lip at `maxY`,
    /// and bottom radius ≥ top (outward lip at least as deep as the top wing).
    public static func isInwardTopOutwardBottom(
        in rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> Bool {
        guard rect.width > 1, rect.height > 1 else { return false }
        let t = max(0, topRadius)
        let b = max(0, bottomRadius)
        // Must fit both radii on each side.
        guard t + b < rect.width, t + b < rect.height * 2 else { return false }
        let p = outlineKeyPoints(in: rect, topRadius: t, bottomRadius: b)
        // Top edge on the bezel line, inset from outer corners.
        let topOnBezel = abs(p.topLeft.y - rect.minY) < 0.5
            && abs(p.topRight.y - rect.minY) < 0.5
            && p.topLeft.x > rect.minX + 0.5
            && p.topRight.x < rect.maxX - 0.5
        // Bottom lip on maxY.
        let bottomLip = abs(p.bottomLeft.y - rect.maxY) < 0.5
            && abs(p.bottomRight.y - rect.maxY) < 0.5
            && p.bottomLeft.x > rect.minX + 0.5
            && p.bottomRight.x < rect.maxX - 0.5
        // Full-width body (not keystone: sides must be at outer edges).
        let fullWidthSides = abs(p.leftSideX - rect.minX) < 0.5
            && abs(p.rightSideX - rect.maxX) < 0.5
        // Bottom lip at least as deep as top wing (AgentNotch closed 6/14).
        let lipAtLeastTop = b + 0.01 >= t
        return topOnBezel && bottomLip && fullWidthSides && lipAtLeastTop
    }

    /// Bounding-box of the island path must match the input rect (full width).
    /// Catches the inverted-keystone bug where sides inset and bottom narrows.
    public static func pathUsesFullWidthBody(
        in rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> Bool {
        let shape = NotchIslandShape(
            topCornerRadius: topRadius,
            bottomCornerRadius: bottomRadius
        )
        let path = shape.path(in: rect)
        let bounds = path.boundingRect
        // Path may be slightly inside due to curve control points sitting on
        // the edge — require near-full width (not the old minX+top inset).
        let widthOK = bounds.width >= rect.width - 1.0
        let heightOK = bounds.height >= rect.height - 1.0
        let leftOK = bounds.minX <= rect.minX + 0.5
        let rightOK = bounds.maxX >= rect.maxX - 0.5
        return widthOK && heightOK && leftOK && rightOK
    }
}

// MARK: - SwiftUI shape

/// AgentNotch / DynamicNotchKit silhouette: full-width body with rounded top
/// wings and a deeper outward bottom lip.
///
/// Path is a standard uneven rounded rectangle (convex body). The previous
/// keystone path (top edge full width, sides inset by top radius, bottom even
/// narrower) stroked as inverted parentheses under the hardware notch.
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
        // Clamp radii so corners never overlap on a small rect.
        let maxR = min(rect.width, rect.height) / 2
        let top = min(max(0, topCornerRadius), maxR)
        let bottom = min(max(0, bottomCornerRadius), maxR)
        var path = Path()

        // Full-width uneven rounded rect (Y-down, clockwise from top edge):
        //
        //      (minX+top)————(maxX-top)        top edge at minY
        //     /                               \
        //  (minX)                           (maxX)   vertical sides
        //     \                               /
        //      (minX+bot)————(maxX-bot)        bottom lip at maxY

        // Start top edge, after top-left corner.
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))

        // Top edge → top-right corner start.
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))

        // Top-right wing (convex, control on outer corner).
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + top),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )

        // Right side down → bottom-right corner start.
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))

        // Bottom-right lip (outward / convex).
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )

        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))

        // Bottom-left lip.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )

        // Left side up → top-left corner start.
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))

        // Top-left wing.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}
