import XCTest
@testable import PillCore

final class HeadGestureTests: XCTestCase {

    private let deg = Double.pi / 180

    /// Feed a sequence of (pitch°, yaw°, t) and collect whatever fires.
    private func run(
        _ detector: inout HeadGestureDetector,
        _ samples: [(Double, Double, TimeInterval)]
    ) -> [HeadGesture] {
        var fired: [HeadGesture] = []
        for (pitch, yaw, t) in samples {
            if let g = detector.process(
                HeadAttitudeSample(pitch: pitch * deg, yaw: yaw * deg, timestamp: t)
            ) {
                fired.append(g)
            }
        }
        return fired
    }

    private func armed(_ config: HeadGestureConfig = .default) -> HeadGestureDetector {
        var d = HeadGestureDetector(config: config)
        d.arm()
        return d
    }

    // MARK: Gating

    func testDisarmedDetectorIgnoresEverything() {
        var d = HeadGestureDetector()
        XCTAssertFalse(d.isArmed)
        // A textbook nod, but nothing is being asked.
        XCTAssertEqual(run(&d, [(0, 0, 0), (25, 0, 0.2), (0, 0, 0.4)]), [])
    }

    func testDisarmingMidGestureCancelsIt() {
        var d = armed()
        _ = run(&d, [(0, 0, 0), (25, 0, 0.2)])   // mid-excursion
        d.disarm()
        d.arm()
        // The return alone must not complete the abandoned excursion.
        XCTAssertEqual(run(&d, [(0, 0, 0.4)]), [])
    }

    // MARK: Nod

    func testNodFiresOnReturnToNeutral() {
        var d = armed()
        let fired = run(&d, [
            (0, 0, 0.0),     // neutral reference
            (10, 0, 0.1),    // below threshold
            (25, 0, 0.2),    // excursion
            (12, 0, 0.3),    // still outside the return band
            (2, 0, 0.4),     // back to neutral -> fire
        ])
        XCTAssertEqual(fired, [.nod])
    }

    func testNodFiresOnUpwardPitchToo() {
        // Direction is not prescribed: pitch back-and-return is still a nod.
        var d = armed()
        XCTAssertEqual(run(&d, [(0, 0, 0), (-25, 0, 0.2), (0, 0, 0.4)]), [.nod])
    }

    func testExcursionWithoutReturnDoesNotFire() {
        var d = armed()
        // Head goes down and stays there — leaning, not nodding.
        XCTAssertEqual(run(&d, [(0, 0, 0), (25, 0, 0.2), (26, 0, 0.4), (25, 0, 0.6)]), [])
    }

    func testMovementBelowThresholdDoesNotFire() {
        var d = armed()
        XCTAssertEqual(run(&d, [(0, 0, 0), (12, 0, 0.2), (0, 0, 0.4)]), [])
    }

    func testTooSlowToBeDeliberateDoesNotFire() {
        var d = armed()
        // Same shape, but the return lands after maxDuration (0.8 s).
        XCTAssertEqual(run(&d, [(0, 0, 0), (25, 0, 0.2), (0, 0, 1.3)]), [])
    }

    // MARK: Shake

    func testShakeFiresOnYawExcursionAndReturn() {
        var d = armed()
        XCTAssertEqual(run(&d, [(0, 0, 0), (0, -25, 0.2), (0, -10, 0.3), (0, 0, 0.4)]), [.shake])
    }

    func testNodAndShakeAreNotConfused() {
        var nodder = armed()
        XCTAssertEqual(run(&nodder, [(0, 0, 0), (30, 0, 0.2), (0, 0, 0.4)]), [.nod])

        var shaker = armed()
        XCTAssertEqual(run(&shaker, [(0, 0, 0), (0, 30, 0.2), (0, 0, 0.4)]), [.shake])
    }

    func testDominantAxisWins() {
        // A nod with incidental sway must still read as a nod.
        var d = armed()
        XCTAssertEqual(run(&d, [(0, 0, 0), (30, 18, 0.2), (0, 0, 0.4)]), [.nod])

        // And the converse.
        var e = armed()
        XCTAssertEqual(run(&e, [(0, 0, 0), (18, 30, 0.2), (0, 0, 0.4)]), [.shake])
    }

    // MARK: Relative-to-neutral baseline

    func testNeutralIsCapturedOnArmingNotAssumedLevel() {
        // User sits with head tilted 20° down — already past the 15° threshold
        // in absolute terms, but that is their neutral.
        var d = armed()
        XCTAssertEqual(run(&d, [(20, 0, 0.0), (22, 0, 0.2), (20, 0, 0.4)]), [])

        // A real nod from that posture still registers.
        XCTAssertEqual(run(&d, [(45, 0, 0.6), (21, 0, 0.8)]), [.nod])
    }

    // MARK: Debounce

    func testSecondGestureIsSuppressedDuringLockout() {
        var d = armed()
        XCTAssertEqual(run(&d, [(0, 0, 0), (25, 0, 0.2), (0, 0, 0.4)]), [.nod])
        // Another full nod 0.6 s later, inside the 2 s lockout.
        XCTAssertEqual(run(&d, [(25, 0, 0.6), (0, 0, 1.0)]), [])
    }

    func testGesturesResumeAfterLockoutExpires() {
        var d = armed()
        XCTAssertEqual(run(&d, [(0, 0, 0), (25, 0, 0.2), (0, 0, 0.4)]), [.nod])
        XCTAssertEqual(run(&d, [(25, 0, 2.6), (0, 0, 2.8)]), [.nod])
    }

    // MARK: Angle wrapping

    func testYawWrapAroundIsNotReadAsHugeMovement() {
        // Neutral just under +pi, drifting just over -pi: a 4° move, not 356°.
        XCTAssertEqual(HeadGestureDetector.angleDelta(-3.10, 3.12), 0.06, accuracy: 0.02)

        var d = HeadGestureDetector()
        d.arm()
        let samples = [
            HeadAttitudeSample(pitch: 0, yaw: 3.12, timestamp: 0),
            HeadAttitudeSample(pitch: 0, yaw: -3.10, timestamp: 0.2),
            HeadAttitudeSample(pitch: 0, yaw: 3.12, timestamp: 0.4),
        ]
        XCTAssertEqual(samples.compactMap { d.process($0) }, [])
    }

    func testAngleDeltaIsSignedAndShortestPath() {
        XCTAssertEqual(HeadGestureDetector.angleDelta(0.5, 0.2), 0.3, accuracy: 1e-9)
        XCTAssertEqual(HeadGestureDetector.angleDelta(0.2, 0.5), -0.3, accuracy: 1e-9)
    }

    // MARK: Config

    func testCustomThresholdIsHonoured() {
        // A 30° threshold should ignore the 25° nod that the default accepts.
        var strict = armed(HeadGestureConfig(thresholdDegrees: 30))
        XCTAssertEqual(run(&strict, [(0, 0, 0), (25, 0, 0.2), (0, 0, 0.4)]), [])
        XCTAssertEqual(run(&strict, [(35, 0, 0.6), (0, 0, 0.8)]), [.nod])
    }

    func testDefaultConfigMatchesDocumentedValues() {
        let c = HeadGestureConfig.default
        XCTAssertEqual(c.thresholdRadians, 15 * deg, accuracy: 1e-12)
        XCTAssertEqual(c.maxDuration, 0.8)
        XCTAssertEqual(c.lockout, 2.0)
    }
}
