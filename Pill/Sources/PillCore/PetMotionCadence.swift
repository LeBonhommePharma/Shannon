// PetMotionCadence.swift — pure TimelineView tick policy for companion sprites.
//
// Keeps atlas / procedural pet motion fluid when visible without burning a
// display-link forever on idle boards. Reduce Motion → static pose (no tick).

import Foundation

/// Pure motion-tick intervals for `CompanionView` / desktop pet surfaces.
public enum PetMotionCadence: Sendable {

    /// Busy / waiting / alert atlas playback — matches `PetAtlasGrid.defaultFPS`.
    public static let activeTickInterval: TimeInterval = 1.0 / PetAtlasGrid.defaultFPS  // 0.125 @ 8 fps

    /// Idle / sleepy breathing — smoother than the historical 0.5 s (2 Hz) tick
    /// but coarser than active work (half-core idle burn avoided).
    public static let idleTickInterval: TimeInterval = 0.12  // ~8.3 Hz

    /// Floor / ceiling for injected periods.
    public static let tickIntervalMin: TimeInterval = 1.0 / 30.0
    public static let tickIntervalMax: TimeInterval = 1.0

    public static func clampTickInterval(_ raw: TimeInterval) -> TimeInterval {
        min(max(raw, tickIntervalMin), tickIntervalMax)
    }

    /// Moods that only need a slow breathing cycle (not display-link).
    public static func isQuietMood(_ mood: CompanionMood) -> Bool {
        switch mood {
        case .idle, .sleepy: return true
        case .alert, .wary, .happy: return false
        }
    }

    /// Motions that claim work / attention — prefer active tick.
    public static func isActiveMotion(_ motion: PetCodexMotion) -> Bool {
        switch motion {
        case .idle: return false
        case .running, .runningRight, .runningLeft,
             .waiting, .failed, .review, .waving, .jumping:
            return true
        }
    }

    /// Timeline period for one companion surface, or `nil` when static (Reduce Motion).
    ///
    /// - `reduceMotion == true` → `nil` (paint one static frame; no TimelineView churn)
    /// - active mood/motion → `activeTickInterval`
    /// - quiet mood → `idleTickInterval`
    public static func timelineInterval(
        mood: CompanionMood,
        motion: PetCodexMotion = .idle,
        reduceMotion: Bool = false
    ) -> TimeInterval? {
        if reduceMotion { return nil }
        if isActiveMotion(motion) || !isQuietMood(mood) {
            return activeTickInterval
        }
        return idleTickInterval
    }

    /// Policy: active tick is at least atlas FPS and sub-second.
    public static func activeTickIsFluid() -> Bool {
        activeTickInterval > 0
            && activeTickInterval <= 0.2
            && abs(activeTickInterval - 1.0 / PetAtlasGrid.defaultFPS) < 1e-9
    }

    /// Policy: idle tick is snappier than the legacy 0.5 s freeze.
    public static func idleFasterThanLegacyHalfSecond() -> Bool {
        idleTickInterval < 0.5 && idleTickInterval >= tickIntervalMin
    }

    public static var policySnapshot: [String: String] {
        [
            "activeTickInterval": "\(activeTickInterval)",
            "idleTickInterval": "\(idleTickInterval)",
            "atlasFPS": "\(PetAtlasGrid.defaultFPS)",
            "activeTickIsFluid": "\(activeTickIsFluid())",
            "idleFasterThanLegacyHalfSecond": "\(idleFasterThanLegacyHalfSecond())",
        ]
    }
}
