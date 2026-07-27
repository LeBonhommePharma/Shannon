import XCTest
@testable import ShannonCore

/// NATURaL SCI / HRV contracts — drives shipped `NaturalEntropyCalculator` + `NaturalSCI`.
final class NaturalSCITests: XCTestCase {

    // MARK: Domain constants

    func testRRDomainIsFixed300to1500() {
        XCTAssertEqual(NaturalSCI.rrDomainMinMs, 300, accuracy: 0)
        XCTAssertEqual(NaturalSCI.rrDomainMaxMs, 1500, accuracy: 0)
    }

    // MARK: SCI score (ScienceRobustnessTests parity)

    func testSCIScoreFullDisorderNearZeroFor32Bins() {
        let calc = NaturalEntropyCalculator(binCount: 32)
        let uniform = (0..<1024).map { Double($0) }
        let score = calc.entropyToScore(calc.shannonEntropy(uniform))
        XCTAssertLessThan(score, 0.15)
        XCTAssertEqual(calc.entropyToScore(log2(32)), 0, accuracy: 1e-12)
    }

    func testSCIScoreConcentratedHigh() {
        let calc = NaturalEntropyCalculator(binCount: 32)
        let concentrated = Array(repeating: 800.0, count: 64)
        let score = calc.entropyToScore(calc.shannonEntropy(concentrated))
        XCTAssertGreaterThan(score, 0.9)
    }

    // MARK: Fixed RR domain SCI path

    func testHRVUsesFixedDomainNotAdaptive() {
        let sci = NaturalSCI()
        let narrow = Array(repeating: 800.0, count: 40)
        let wide = (0..<40).map { 300.0 + Double($0) * 30.0 } // 300…1470
        let hNarrow = sci.shannonEntropy(rrIntervalsMs: narrow)
        let hWide = sci.shannonEntropy(rrIntervalsMs: wide)
        XCTAssertLessThan(hNarrow, 1.0)
        XCTAssertGreaterThan(hWide, hNarrow)
        XCTAssertGreaterThanOrEqual(hNarrow, 0)
        XCTAssertTrue(hNarrow.isFinite && hWide.isFinite)
    }

    func testConcentratedSCIHigherThanWideOnFixedDomain() throws {
        let sci = NaturalSCI()
        let concentrated = NaturalSCIHub.demoConcentratedRR()
        let wide = NaturalSCIHub.demoWideRR()
        let sC = try XCTUnwrap(sci.score(rrIntervalsMs: concentrated))
        let sW = try XCTUnwrap(sci.score(rrIntervalsMs: wide))
        XCTAssertGreaterThan(sC, sW)
        XCTAssertGreaterThan(sC, 0.85)
    }

    func testAnalyzeReturnsStatusLineAndCollapseFlag() throws {
        let sci = NaturalSCI(collapseThresholdBits: 3.2)
        let result = try XCTUnwrap(sci.analyze(rrIntervalsMs: NaturalSCIHub.demoConcentratedRR()))
        XCTAssertTrue(result.isCollapsed, "tight RR cluster should collapse under 3.2 bits")
        XCTAssertTrue(result.statusLine.contains("SCI"))
        XCTAssertTrue(result.statusLine.contains("300"))
        XCTAssertTrue(result.statusLine.contains("1500"))
    }

    func testInsufficientRRReturnsNilScore() {
        let sci = NaturalSCI()
        XCTAssertNil(sci.score(rrIntervalsMs: [800, 810, 820]))
        XCTAssertNil(sci.analyze(rrIntervalsMs: [800]))
    }

    // MARK: NaN / non-finite guards

    func testNonFiniteFiltered() {
        let calc = NaturalEntropyCalculator(binCount: 32)
        let h = calc.shannonEntropy([1, 2, .nan, 3, .infinity, 4, -.infinity, 5])
        XCTAssertFalse(h.isNaN)
        XCTAssertGreaterThan(h, 0)
    }

    // MARK: Circular (NATURaL EntropyCalculator parity, optional)

    func testCircularEntropyUniformNearMax() {
        let calc = NaturalEntropyCalculator(binCount: 32)
        let uniform = (0..<1000).map { i in -180.0 + 360.0 * Double(i) / 1000.0 }
        let h = calc.circularShannonEntropy(uniform)
        XCTAssertGreaterThan(h, calc.maxEntropyBits * 0.95)
    }

    // MARK: Hub + fleet coexistence

    func testDemoStatusLineNonEmpty() {
        let line = NaturalSCIHub.demoStatusLine()
        XCTAssertTrue(line.contains("SCI"), line)
        XCTAssertTrue(line.contains("focused"), line)
    }

    func testFleetPresenceStillWorksAlongsideSCI() {
        // Regression: NATURaL presence port must remain green.
        let rec = BonhommeFleetPresence(
            deviceId: "n1", displayName: "Watch", platform: .watchOS
        )
        XCTAssertFalse(rec.isStale())
        let devices = BonhommeFleetHub.devices(fromPresence: [rec])
        XCTAssertEqual(devices.count, 1)
    }
}
