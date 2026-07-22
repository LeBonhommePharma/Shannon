import Foundation

// MARK: - PetAvatarShapeParams

/// Deterministic, seed-derived parameters for a procedural pet avatar.
/// Same `seed` → same `PetAvatarShapeParams` on every device.
/// Rendered by each platform's `PetAvatarCanvas` into pure SwiftUI shapes.
/// No image assets required — this is pure maths, no SwiftUI dependency.
public struct PetAvatarShapeParams: Sendable, Equatable {
    /// Primary hue, 0.0–1.0.
    public var hue: Double
    /// Accent hue (complementary, 0.0–1.0).
    public var accentHue: Double
    /// Saturation, 0.6–1.0.
    public var saturation: Double
    /// Body shape index: 0 = circle, 1 = rounded-rect, 2 = diamond, 3 = leaf.
    public var bodyShape: Int
    /// Eye style index: 0 = dots, 1 = ovals, 2 = stars, 3 = crescents.
    public var eyeStyle: Int
    /// Pupil scale relative to eye, 0.3–0.8.
    public var pupilScale: Double
    /// Number of decorative orbiting particles, 0–3.
    public var particleCount: Int
    /// Rotation of the accent secondary element, 0–360°.
    public var accentRotation: Double
}

// MARK: - PetAvatarDescriptor

public struct PetAvatarDescriptor: Sendable {

    /// Derive avatar shape parameters deterministically from an arbitrary seed.
    /// Uses the splitmix64 hash so output is well-distributed over the full range.
    public static func params(for seed: UInt64) -> PetAvatarShapeParams {
        var s = seed ^ (seed &>> 30) &* 0xbf58476d1ce4e5b9
        s = s ^ (s &>> 27) &* 0x94d049bb133111eb
        s = s ^ (s &>> 31)

        func frac(_ shift: Int) -> Double {
            Double((s &>> shift) & 0xFFFF) / 65536.0
        }
        func intN(_ n: Int, shift: Int) -> Int {
            Int((s &>> shift) & 0xFF) % n
        }

        return PetAvatarShapeParams(
            hue:            frac(0),
            accentHue:      (frac(16) + 0.5).truncatingRemainder(dividingBy: 1.0),
            saturation:     0.6 + frac(32) * 0.4,
            bodyShape:      intN(4, shift: 48),
            eyeStyle:       intN(4, shift: 56),
            pupilScale:     0.3 + frac(8) * 0.5,
            particleCount:  intN(4, shift: 24),
            accentRotation: frac(40) * 360
        )
    }

    /// Stable integer hash of the params — used in unit tests to verify that
    /// two calls with the same seed produce an identical avatar.
    public static func paramsHash(seed: UInt64) -> Int {
        let p = params(for: seed)
        var h = Int(p.hue * 1_000)
        h ^= Int(p.saturation * 1_000) << 10
        h ^= p.bodyShape << 20
        h ^= p.eyeStyle  << 22
        h ^= p.particleCount << 24
        return h
    }
}

// MARK: - PetMoodOverlay

/// Adjustments layered on top of base params at render time for a given mood.
public struct PetMoodOverlay: Sendable {
    /// Multiplier applied to the pupil radius. > 1 = dilated (excited).
    public var pupilScale: Double
    /// Vertical eye offset as fraction of avatar height. Negative = furrowed.
    public var eyeVerticalOffset: Double
    /// Whether the eyes render closed (sleeping / blinking).
    public var eyesClosed: Bool
    /// Overall avatar scale for bounce / shrink effects (1.0 = normal).
    public var avatarScale: Double

    public init(pupilScale: Double, eyeVerticalOffset: Double,
                eyesClosed: Bool, avatarScale: Double) {
        self.pupilScale = pupilScale
        self.eyeVerticalOffset = eyeVerticalOffset
        self.eyesClosed = eyesClosed
        self.avatarScale = avatarScale
    }

    public static func from(mood: PetMood) -> PetMoodOverlay {
        switch mood {
        case .calm:
            return PetMoodOverlay(pupilScale: 1.0, eyeVerticalOffset: 0,    eyesClosed: false, avatarScale: 1.00)
        case .curious:
            return PetMoodOverlay(pupilScale: 1.1, eyeVerticalOffset: 0.05, eyesClosed: false, avatarScale: 1.00)
        case .excited:
            return PetMoodOverlay(pupilScale: 1.4, eyeVerticalOffset: 0.05, eyesClosed: false, avatarScale: 1.05)
        case .worried:
            return PetMoodOverlay(pupilScale: 0.9, eyeVerticalOffset: -0.08,eyesClosed: false, avatarScale: 0.95)
        case .sleeping:
            return PetMoodOverlay(pupilScale: 0.5, eyeVerticalOffset: 0,    eyesClosed: true,  avatarScale: 0.95)
        case .playful:
            return PetMoodOverlay(pupilScale: 1.2, eyeVerticalOffset: 0.08, eyesClosed: false, avatarScale: 1.08)
        }
    }
}
