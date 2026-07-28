import XCTest
import SwiftUI
@testable import ShannonTheme

final class ShannonMotionSpringTests: XCTestCase {

    func testFloatSpringMatchesLegacyConstants() {
        XCTAssertEqual(ShannonSpring.float.response, 0.40, accuracy: 1e-12)
        XCTAssertEqual(ShannonSpring.float.dampingFraction, 0.88, accuracy: 1e-12)
        // AppKit panel morph duration must equal float response (in-phase).
        XCTAssertEqual(ShannonMotion.panelMorphDuration, ShannonSpring.float.response, accuracy: 1e-12)
        XCTAssertEqual(ShannonMotion.panelMorphDuration, 0.40, accuracy: 1e-12)
    }

    func testReduceMotionScalesToInstant() {
        let s = ShannonSpring.float.scaled(reduceMotion: true)
        XCTAssertLessThanOrEqual(s.response, 0.01)
        XCTAssertEqual(s.dampingFraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(
            ShannonMotion.panelMorphDuration(reduceMotion: true),
            0,
            accuracy: 1e-12
        )
        XCTAssertFalse(ShannonMotion.allowsForeverPulse(reduceMotion: true))
        XCTAssertTrue(ShannonMotion.allowsForeverPulse(reduceMotion: false))
    }

    func testAnimationSpeedScalesResponse() {
        let fast = ShannonSpring.float.scaled(reduceMotion: false, animationSpeed: 2.0)
        XCTAssertEqual(fast.response, 0.20, accuracy: 1e-9)
        XCTAssertEqual(fast.dampingFraction, ShannonSpring.float.dampingFraction, accuracy: 1e-12)
    }

    func testShannonAnimationNilUnderReduceMotion() {
        XCTAssertNil(Animation.shannon(.shannonFloat, reduceMotion: true))
        XCTAssertNotNil(Animation.shannon(.shannonFloat, reduceMotion: false))
        XCTAssertNil(Animation.shannonSpring(ShannonSpring.float, reduceMotion: true))
        XCTAssertNotNil(Animation.shannonSpring(ShannonSpring.float, reduceMotion: false))
    }

    func testSnapEaseLiquidChromeVocabulary() {
        XCTAssertEqual(ShannonSpring.snap.response, 0.25, accuracy: 1e-12)
        XCTAssertEqual(ShannonSpring.ease.response, 0.38, accuracy: 1e-12)
        XCTAssertEqual(ShannonSpring.liquid.response, 0.26, accuracy: 1e-12)
        XCTAssertEqual(ShannonSpring.chrome.response, 0.36, accuracy: 1e-12)
        XCTAssertEqual(ShannonMotion.popoverMorphDuration, ShannonSpring.ease.response, accuracy: 1e-12)
    }
}
