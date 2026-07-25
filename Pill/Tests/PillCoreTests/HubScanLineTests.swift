import XCTest
@testable import PillCore

final class HubScanLineTests: XCTestCase {

    func testCollapseWins() {
        let s = HubScanLine.resolve(
            collapseBits: 2.4,
            collapseDelta: -3.5,
            busyNames: ["Claude"],
            busyStatus: "working",
            benchmarkTitle: "12/85 · 1hpv",
            hubReady: true
        )
        XCTAssertTrue(s.contains("Entropy collapse"))
        XCTAssertTrue(s.contains("2.4"))
        XCTAssertTrue(s.contains("ΔH"))
    }

    func testBusySingleAndMulti() {
        XCTAssertEqual(
            HubScanLine.resolve(
                collapseBits: nil,
                busyNames: ["Grok Build"],
                busyStatus: "working",
                benchmarkTitle: nil,
                hubReady: true
            ),
            "Grok Build · working"
        )
        XCTAssertEqual(
            HubScanLine.resolve(
                collapseBits: nil,
                busyNames: ["a", "b", "c"],
                busyStatus: nil,
                benchmarkTitle: "34/85",
                hubReady: true
            ),
            "3 agents active"
        )
    }

    func testBenchmarkWhenIdle() {
        let s = HubScanLine.resolve(
            collapseBits: nil,
            busyNames: [],
            busyStatus: nil,
            benchmarkTitle: "12/85 · 1hpv",
            hubReady: true
        )
        XCTAssertEqual(s, "FlexAIDdS · 12/85 · 1hpv")
    }

    func testHubStatesHonest() {
        XCTAssertEqual(
            HubScanLine.resolve(
                collapseBits: nil, busyNames: [], busyStatus: nil,
                benchmarkTitle: nil, hubReady: true
            ),
            "Hub ready · no agents busy"
        )
        XCTAssertEqual(
            HubScanLine.resolve(
                collapseBits: nil, busyNames: [], busyStatus: nil,
                benchmarkTitle: nil, hubReady: false
            ),
            "Hub offline · start gate for FlexAIDdS"
        )
    }

    func testNoInventedSuccessRate() {
        let s = HubScanLine.resolve(
            collapseBits: nil,
            busyNames: [],
            busyStatus: nil,
            benchmarkTitle: "34/85",
            hubReady: true
        )
        XCTAssertFalse(s.contains("%"))
        XCTAssertFalse(s.contains("success"))
    }
}
