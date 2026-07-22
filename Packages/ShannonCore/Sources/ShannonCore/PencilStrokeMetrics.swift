import Foundation
import CoreGraphics

/// Captured Apple Pencil sensor data for a single touch sample.
///
/// All values use Apple's documented units. The struct is Codable so stroke
/// metadata can be included in agent context bundles sent to the Mac.
/// ShannonCore carries this type; UITouch sampling lives in the iPad target.
public struct PencilStrokeMetrics: Sendable, Codable, Equatable {

    // MARK: - Core sensor values

    /// Normalised force in [0, 1]. Derived as `UITouch.force / UITouch.maximumPossibleForce`.
    /// Use for stroke width: flat presses produce thick strokes.
    public var normalizedForce: Float

    /// Altitude angle from the surface plane in radians [0, π/2].
    /// 0 = Pencil lying flat; π/2 = perpendicular. `UITouch.altitudeAngle`.
    /// Low altitude → shading / broad marks. High altitude → fine lines.
    public var altitudeAngle: Float

    /// Azimuth direction around the perpendicular axis in radians [0, 2π].
    /// `UITouch.azimuthAngle(in:)`. Use for calligraphy nib orientation.
    public var azimuthAngle: Float

    /// Barrel roll (Pencil Pro, iPadOS 17.5+): rotation around the Pencil's own
    /// long axis. `UITouch.rollAngle`. Nil on hardware that does not expose it.
    public var rollAngle: Float?

    /// Normalised hover height above the surface [0, 1] (iPadOS 16+).
    /// Nil when the tip is on-surface.
    public var zOffset: Float?

    /// Canvas-space coordinates at sample time.
    public var location: CGPoint

    // MARK: - Init

    public init(
        normalizedForce: Float = 1,
        altitudeAngle: Float = Float.pi / 2,
        azimuthAngle: Float = 0,
        rollAngle: Float? = nil,
        zOffset: Float? = nil,
        location: CGPoint = .zero
    ) {
        self.normalizedForce = normalizedForce
        self.altitudeAngle = altitudeAngle
        self.azimuthAngle = azimuthAngle
        self.rollAngle = rollAngle
        self.zOffset = zOffset
        self.location = location
    }

    // MARK: - Derived drawing properties

    /// Variable stroke width multiplier in [0.5, 3.0] driven by force.
    public var strokeWidthMultiplier: CGFloat {
        CGFloat(0.5 + normalizedForce * 2.5)
    }

    /// Shading opacity [0.3, 1.0] driven by altitude.
    /// Flat Pencil (altitudeAngle ≈ 0) → broad soft marks; upright → crisp lines.
    public var tiltOpacity: CGFloat {
        CGFloat(0.3 + (altitudeAngle / (Float.pi / 2)) * 0.7)
    }

    /// Active tool rotation. Uses barrel roll when available, falls back to azimuth.
    /// Drives brush angle, annotation arrow direction, nib orientation.
    public var toolRotationRadians: CGFloat {
        CGFloat(rollAngle ?? azimuthAngle)
    }
}
