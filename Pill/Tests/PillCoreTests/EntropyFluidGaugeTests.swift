import XCTest
@testable import PillCore

final class EntropyFluidGaugeTests: XCTestCase {

    func testAbsentBitsNeverLive() {
        let s = EntropyFluidGauge.sample(
            bits: nil,
            isMeasuredCurrent: true,
            agentAttached: true,
            phaseSeconds: 1.0,
            reduceMotion: false
        )
        XCTAssertFalse(s.isLive)
        XCTAssertEqual(s.fill, 0.04, accuracy: 1e-12)
        XCTAssertEqual(s.waveOffset, 0, accuracy: 1e-12)
    }

    func testNoAgentNoFluidEvenWithMeasuredH() {
        let s = EntropyFluidGauge.sample(
            bits: 8.0,
            isMeasuredCurrent: true,
            agentAttached: false,
            phaseSeconds: 2.0,
            reduceMotion: false
        )
        XCTAssertFalse(s.isLive)
        XCTAssertEqual(s.fill, EntropyGauge.fillFraction(bits: 8), accuracy: 1e-12)
        XCTAssertEqual(s.waveOffset, 0, accuracy: 1e-12)
    }

    func testReduceMotionFreezesDynamics() {
        let a = EntropyFluidGauge.sample(
            bits: 7.0,
            isMeasuredCurrent: true,
            agentAttached: true,
            phaseSeconds: 0.0,
            reduceMotion: true
        )
        let b = EntropyFluidGauge.sample(
            bits: 7.0,
            isMeasuredCurrent: true,
            agentAttached: true,
            phaseSeconds: 1.5,
            reduceMotion: true
        )
        XCTAssertFalse(a.isLive)
        XCTAssertFalse(b.isLive)
        XCTAssertEqual(a.fill, b.fill, accuracy: 1e-12)
        XCTAssertEqual(a.waveOffset, 0, accuracy: 1e-12)
        XCTAssertEqual(b.waveOffset, 0, accuracy: 1e-12)
    }

    func testStaleNotCurrentNotLive() {
        let s = EntropyFluidGauge.sample(
            bits: 6.0,
            isMeasuredCurrent: false,
            agentAttached: true,
            phaseSeconds: 3.0,
            reduceMotion: false
        )
        XCTAssertFalse(s.isLive)
        XCTAssertEqual(s.waveOffset, 0, accuracy: 1e-12)
    }

    func testMeasuredAttachedPhasesChangeFill() {
        let p0 = EntropyFluidGauge.sample(
            bits: 6.0,
            isMeasuredCurrent: true,
            agentAttached: true,
            phaseSeconds: 0.0,
            reduceMotion: false
        )
        let p1 = EntropyFluidGauge.sample(
            bits: 6.0,
            isMeasuredCurrent: true,
            agentAttached: true,
            phaseSeconds: 0.7,
            reduceMotion: false
        )
        XCTAssertTrue(p0.isLive)
        XCTAssertTrue(p1.isLive)
        // Continuous undulation: successive phases must differ (fill or wave).
        let changed = abs(p0.fill - p1.fill) > 1e-6 || abs(p0.waveOffset - p1.waveOffset) > 1e-6
        XCTAssertTrue(changed, "fluid phase should move fill/wave over time")
        // Stay in unit interval
        XCTAssertGreaterThanOrEqual(p0.fill, 0.04)
        XCTAssertLessThanOrEqual(p0.fill, 1.0)
        XCTAssertGreaterThanOrEqual(p1.fill, 0.04)
        XCTAssertLessThanOrEqual(p1.fill, 1.0)
    }

    func testNonFiniteBitsStatic() {
        let s = EntropyFluidGauge.sample(
            bits: .nan,
            isMeasuredCurrent: true,
            agentAttached: true,
            phaseSeconds: 1.0,
            reduceMotion: false
        )
        XCTAssertFalse(s.isLive)
        XCTAssertEqual(s.fill, 0.04, accuracy: 1e-12)
    }

    func testDisplayConvenienceMeasuredLive() {
        let now = Date()
        guard let m = EntropyMeasurement(
            bits: 9.0,
            deltaH: nil,
            collapsed: false,
            source: .bridge(backend: "test"),
            measuredAt: now,
            now: now
        ) else {
            return XCTFail("measurement should construct")
        }
        let reading = EntropyReading.measured(m)
        guard let display = reading.display(at: now) else {
            return XCTFail("measured must display")
        }
        let s = EntropyFluidGauge.sample(
            display: display,
            agentAttached: true,
            phaseSeconds: 0.4,
            reduceMotion: false
        )
        XCTAssertTrue(s.isLive)
        XCTAssertGreaterThan(s.fill, 0.04)
    }

    func testShouldAnimateGates() {
        XCTAssertTrue(EntropyFluidGauge.shouldAnimate(
            agentAttached: true, isMeasuredCurrent: true, bits: 5, reduceMotion: false
        ))
        XCTAssertFalse(EntropyFluidGauge.shouldAnimate(
            agentAttached: false, isMeasuredCurrent: true, bits: 5, reduceMotion: false
        ))
        XCTAssertFalse(EntropyFluidGauge.shouldAnimate(
            agentAttached: true, isMeasuredCurrent: false, bits: 5, reduceMotion: false
        ))
        XCTAssertFalse(EntropyFluidGauge.shouldAnimate(
            agentAttached: true, isMeasuredCurrent: true, bits: 5, reduceMotion: true
        ))
        XCTAssertFalse(EntropyFluidGauge.shouldAnimate(
            agentAttached: true, isMeasuredCurrent: true, bits: nil, reduceMotion: false
        ))
    }
}
