import XCTest
@testable import PillCore

/// Continuous scarcity tint — not 4 solid bands.
final class ResourceScarcityTintTests: XCTestCase {

    func testLowLoadIsMutedAndNonRed() {
        let ink = ResourceScarcityTint.sRGB(percent: 12)
        XCTAssertLessThan(ink.chroma, 0.35, "low load must be desaturated, not full solid green")
        XCTAssertTrue(ResourceScarcityTint.isNonRed(ink), "low load must not lean red")
        XCTAssertLessThan(ResourceScarcityTint.intensity(percent: 12), 0.15)
        XCTAssertFalse(ResourceScarcityTint.isCriticalRed(ink, percent: 12))
    }

    func testMidLoadIntermediateNotCriticalRed() {
        let mid = ResourceScarcityTint.sRGB(percent: 70)
        let low = ResourceScarcityTint.sRGB(percent: 15)
        let crit = ResourceScarcityTint.sRGB(percent: 96)
        // Rising scarcity increases intensity / chroma vs calm.
        XCTAssertGreaterThan(
            ResourceScarcityTint.intensity(percent: 70),
            ResourceScarcityTint.intensity(percent: 15)
        )
        XCTAssertGreaterThan(mid.chroma, low.chroma - 0.05)
        XCTAssertTrue(ResourceScarcityTint.isNonRed(mid), "70% must stay non-red")
        XCTAssertFalse(ResourceScarcityTint.isCriticalRed(mid, percent: 70))
        // Not the same as emergency red.
        XCTAssertLessThan(mid.redDominance, crit.redDominance)
    }

    func testHotLoadGoldNotFullRed() {
        let hot = ResourceScarcityTint.sRGB(percent: 85)
        XCTAssertTrue(ResourceScarcityTint.isNonRed(hot) || hot.redDominance < 0.2,
                      "pre-critical should not be full emergency red")
        XCTAssertFalse(ResourceScarcityTint.isCriticalRed(hot, percent: 85))
        // Gold-ish: green still material.
        XCTAssertGreaterThan(hot.g, 0.25)
    }

    func testCriticalIsRedwardEmergency() {
        let ink = ResourceScarcityTint.sRGB(percent: 96)
        XCTAssertTrue(
            ResourceScarcityTint.isCriticalRed(ink, percent: 96),
            "critical percent must lean red with real chroma"
        )
        XCTAssertGreaterThan(ink.redDominance, 0.15)
        XCTAssertGreaterThan(ink.r, ink.g)
        XCTAssertGreaterThan(ink.r, ink.b)
    }

    func testIntensityMonotonicWithPercent() {
        var prev = ResourceScarcityTint.intensity(percent: 0)
        for p in stride(from: 5.0, through: 100.0, by: 5.0) {
            let i = ResourceScarcityTint.intensity(percent: p)
            XCTAssertGreaterThanOrEqual(i, prev - 1e-9, "intensity must not drop as load rises")
            prev = i
        }
        XCTAssertEqual(ResourceScarcityTint.intensity(percent: 100), 1, accuracy: 1e-6)
    }

    func testNilPercentIsMutedNeutral() {
        let ink = ResourceScarcityTint.sRGB(percent: nil)
        XCTAssertTrue(ResourceScarcityTint.isNonRed(ink))
        XCTAssertLessThan(ink.chroma, 0.15)
    }

    func testNotFullSaturationAtModestLoad() {
        // Discrete band mapping painted full green/gold; continuous must not.
        let p50 = ResourceScarcityTint.sRGB(percent: 50)
        let p100 = ResourceScarcityTint.sRGB(percent: 100)
        XCTAssertLessThan(p50.chroma, p100.chroma)
        // 50% is not max-chroma emergency ink.
        XCTAssertLessThan(p50.chroma, 0.55)
    }

    /// Shipped thresholds: red only past criticalThreshold (92).
    func testRedOnlyPastCriticalThreshold() {
        let justUnder = ResourceScarcityTint.sRGB(percent: ResourceScarcityTint.criticalThreshold - 0.5)
        let justOver = ResourceScarcityTint.sRGB(percent: ResourceScarcityTint.criticalThreshold + 1)
        XCTAssertFalse(ResourceScarcityTint.isCriticalRed(justUnder, percent: 91.5))
        XCTAssertTrue(ResourceScarcityTint.isCriticalRed(justOver, percent: 93))
    }
}
