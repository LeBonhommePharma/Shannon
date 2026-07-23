import XCTest
import SwiftUI
@testable import ShannonTheme

/// The daylight readability contract for agent brand colours.
///
/// These are the real brand values from `hub/agent_identity.py` — several are
/// deliberately light (Science amber, Cowork green) because they were chosen to
/// glow on a near-black slab. The point of these tests is that no matter how
/// light the brand colour is, the derived `ink` role always clears the contrast
/// bar against the surface it will actually be drawn on.
final class AgentIdentityColorTests: XCTestCase {

    /// (label, r, g, b) — mirrors AgentStyleCatalog / agent_identity.py.
    private let brands: [(String, Double, Double, Double)] = [
        ("science", 1.00, 0.72, 0.10),
        ("grok_build", 0.68, 0.28, 0.98),
        ("claude_code", 1.00, 0.50, 0.08),
        ("codex", 0.30, 0.55, 1.00),
        ("dispatch", 0.72, 0.50, 0.28),
        ("cowork", 0.20, 0.85, 0.45),
        ("chatgpt", 0.10, 0.72, 0.55),
        ("dataset_runner", 0.15, 0.70, 0.80),
        ("terminal", 0.55, 0.60, 0.65),
        ("browser", 0.35, 0.55, 0.95),
    ]

    /// WCAG contrast ratio between two relative luminances.
    private func contrast(_ a: Double, _ b: Double) -> Double {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }

    func testDayInkClearsContrastOnWhiteSurface() {
        let white = AgentColor.luminance(ShannonRGBA(hex: 0xFFFFFF))
        for (name, r, g, b) in brands {
            let ink = AgentColor.darkened(
                ShannonRGBA(red: r, green: g, blue: b),
                toAtMost: AgentColor.dayInkMaxLuminance
            )
            let ratio = contrast(AgentColor.luminance(ink), white)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(name) day ink is \(ratio):1 on white — unreadable in daylight"
            )
        }
    }

    func testNightInkClearsContrastOnNightSurface() {
        let surface = AgentColor.luminance(ShannonRGBA(hex: 0x18181C))
        for (name, r, g, b) in brands {
            let ink = AgentColor.brightened(
                ShannonRGBA(red: r, green: g, blue: b),
                toAtLeast: AgentColor.nightInkMinLuminance
            )
            let ratio = contrast(AgentColor.luminance(ink), surface)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(name) night ink is \(ratio):1 on #18181C"
            )
        }
    }

    /// Correction must not overshoot — an agent that is already dark enough
    /// keeps its exact brand colour rather than being pushed to near-black.
    func testAlreadyDarkColourIsLeftUntouched() {
        let deepBrown = ShannonRGBA(hex: 0x92400E)
        let corrected = AgentColor.darkened(deepBrown, toAtMost: AgentColor.dayInkMaxLuminance)
        XCTAssertEqual(corrected.red, deepBrown.red, accuracy: 1e-9)
        XCTAssertEqual(corrected.green, deepBrown.green, accuracy: 1e-9)
        XCTAssertEqual(corrected.blue, deepBrown.blue, accuracy: 1e-9)
    }

    /// Hue must survive the correction, otherwise every agent collapses toward
    /// the same muddy dark and identity is lost — the whole point of the colour.
    func testCorrectionPreservesHueOrdering() {
        // Science is a warm amber: red stays dominant over blue after darkening.
        let amber = AgentColor.darkened(
            ShannonRGBA(red: 1.00, green: 0.72, blue: 0.10),
            toAtMost: AgentColor.dayInkMaxLuminance
        )
        XCTAssertGreaterThan(amber.red, amber.green)
        XCTAssertGreaterThan(amber.green, amber.blue)

        // Codex is a cool blue: blue stays dominant over red.
        let blue = AgentColor.darkened(
            ShannonRGBA(red: 0.30, green: 0.55, blue: 1.00),
            toAtMost: AgentColor.dayInkMaxLuminance
        )
        XCTAssertGreaterThan(blue.blue, blue.green)
        XCTAssertGreaterThan(blue.green, blue.red)
    }

    func testAlphaSurvivesRoleDerivation() {
        let washed = ShannonRGBA(red: 1.0, green: 0.72, blue: 0.10).withAlpha(0.10)
        XCTAssertEqual(washed.alpha, 0.10, accuracy: 1e-9)
        XCTAssertEqual(washed.scaled(by: 0.5).alpha, 0.10, accuracy: 1e-9)
        XCTAssertEqual(washed.blendedTowardWhite(0.5).alpha, 0.10, accuracy: 1e-9)
    }
}

/// LP's constraint: the light theme must not read as grey.
///
/// "Warm" is testable — red must exceed blue on every day surface and grey. A
/// neutral or cool value (B >= R) is what makes a light UI feel clinical, so
/// this fails the build rather than waiting for someone to notice by eye.
final class WarmDayPaletteTests: XCTestCase {

    /// (label, day hex, minimum red-minus-blue in 0-255 units)
    private let daySurfaces: [(String, UInt32, Int)] = [
        ("background", 0xFAF8F3, 4),
        ("surfaceElevated", 0xF2EEE5, 8),
        ("surfaceSunken", 0xF6F2EA, 8),
        ("quaternary", 0xDED6C8, 12),
        ("tertiary", 0x7D7365, 12),
        ("secondary", 0x6B6257, 12),
        ("primary", 0x1C1917, 3),
        ("neutral", 0x857C6E, 12),
        ("separator tint", 0x7A5C3A, 40),
        ("shadow tint", 0x5C482D, 40),
    ]

    func testEveryDaySurfaceIsWarm() {
        for (name, hex, minWarmth) in daySurfaces {
            let r = Int((hex >> 16) & 0xFF)
            let b = Int(hex & 0xFF)
            XCTAssertGreaterThanOrEqual(
                r - b, minWarmth,
                "\(name) has red \(r) vs blue \(b) — reads grey or cool, not warm"
            )
        }
    }

    /// The greys must still descend monotonically, or the surface ladder stops
    /// communicating depth.
    func testDayGreyLadderDescends() {
        let ladder: [UInt32] = [0xFFFFFF, 0xFAF8F3, 0xF6F2EA, 0xF2EEE5,
                                0xDED6C8, 0x857C6E, 0x7D7365, 0x6B6257, 0x1C1917]
        let lums = ladder.map { AgentColor.luminance(ShannonRGBA(hex: $0)) }
        for i in 1 ..< lums.count {
            XCTAssertLessThan(lums[i], lums[i - 1],
                              "day ladder is not monotonically darker at index \(i)")
        }
    }

    /// Text tokens must still clear their contrast bars after the warm shift.
    func testWarmTextStillMeetsContrastOnWhite() {
        let white = AgentColor.luminance(ShannonRGBA(hex: 0xFFFFFF))
        for (name, hex, target) in [("primary", UInt32(0x1C1917), 7.0),
                                    ("secondary", UInt32(0x6B6257), 4.5),
                                    ("tertiary", UInt32(0x7D7365), 4.5)] {
            let l = AgentColor.luminance(ShannonRGBA(hex: hex))
            let ratio = (max(l, white) + 0.05) / (min(l, white) + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, target, "\(name) is \(ratio):1 on white")
        }
    }
}
