import XCTest
@testable import ShannonCore

/// ENH-031 — Gate ask change paths/summary when payload has them (parity G9).
final class GateAskChangePathsTests: XCTestCase {

    // MARK: - Empty / fail-closed

    func testEmptyPathsAndSummaryIsEmpty() {
        let p = GateAskChangePaths.present(paths: [], summary: nil)
        XCTAssertTrue(p.isEmpty)
        XCTAssertNil(p.joinedDisplay)
        XCTAssertTrue(p.displayLines.isEmpty)
        XCTAssertNil(p.accessibilityLabel)
    }

    func testWhitespaceOnlyPathsDropped() {
        let p = GateAskChangePaths.present(paths: ["  ", "\n", ""], summary: "   ")
        XCTAssertTrue(p.isEmpty)
        XCTAssertNil(p.joinedDisplay)
    }

    func testInvalidJSONYieldsEmpty() {
        let p = GateAskChangePaths.present(json: "not-json")
        XCTAssertTrue(p.isEmpty)
        let p2 = GateAskChangePaths.present(json: "[1,2,3]")
        XCTAssertTrue(p2.isEmpty, "array root is not a payload object")
        let p3 = GateAskChangePaths.present(json: "")
        XCTAssertTrue(p3.isEmpty)
    }

    func testUnknownKeysNeverInventPaths() {
        let payload: [String: Any] = [
            "prompt": "Edit /Users/me/secret.swift?",
            "question": "Apply patch to main.py and util.ts",
            "text": "touch src/a.swift src/b.swift",
            "tool": "edit",
            "bogus_paths": ["nope.swift"],
        ]
        let extracted = GateAskChangePaths.extract(fromPayload: payload)
        XCTAssertTrue(extracted.paths.isEmpty, "must not invent paths from prose or unknown keys")
        XCTAssertNil(extracted.summary)
        let p = GateAskChangePaths.present(payload: payload)
        XCTAssertTrue(p.isEmpty)
    }

    // MARK: - Real payload fields

    func testPathsArrayPresent() {
        let payload: [String: Any] = [
            "paths": ["src/a.swift", "src/b.swift", "tests/a_tests.swift"],
        ]
        let extracted = GateAskChangePaths.extract(fromPayload: payload)
        XCTAssertEqual(extracted.paths, ["src/a.swift", "src/b.swift", "tests/a_tests.swift"])
        let p = GateAskChangePaths.present(payload: payload)
        XCTAssertFalse(p.isEmpty)
        XCTAssertEqual(p.pathLines.count, 3)
        XCTAssertEqual(p.overflowCount, 0)
        XCTAssertNil(p.summary)
        XCTAssertEqual(
            p.joinedDisplay,
            "src/a.swift\nsrc/b.swift\ntests/a_tests.swift"
        )
    }

    func testFilesKeyAccepted() {
        let payload: [String: Any] = ["files": ["hub/shannon_gate.py"]]
        XCTAssertEqual(
            GateAskChangePaths.extract(fromPayload: payload).paths,
            ["hub/shannon_gate.py"]
        )
    }

    func testScalarPathKey() {
        let payload: [String: Any] = ["path": "/tmp/one.py"]
        XCTAssertEqual(
            GateAskChangePaths.extract(fromPayload: payload).paths,
            ["/tmp/one.py"]
        )
    }

    func testChangeSummaryWithPaths() {
        let payload: [String: Any] = [
            "change_summary": "Refactor entropy clock",
            "changed_files": ["Pill/Sources/PillCore/GateDBReader.swift"],
        ]
        let p = GateAskChangePaths.present(payload: payload)
        XCTAssertEqual(p.summary, "Refactor entropy clock")
        XCTAssertEqual(p.pathLines, ["Pill/Sources/PillCore/GateDBReader.swift"])
        XCTAssertEqual(
            p.displayLines,
            ["Refactor entropy clock", "Pill/Sources/PillCore/GateDBReader.swift"]
        )
    }

    func testSummaryAloneWithoutPaths() {
        let p = GateAskChangePaths.present(paths: [], summary: "Touches 3 source files")
        XCTAssertFalse(p.isEmpty)
        XCTAssertEqual(p.displayLines, ["Touches 3 source files"])
        XCTAssertEqual(p.joinedDisplay, "Touches 3 source files")
    }

    func testSummaryKeyPreferenceOrder() {
        // change_summary wins over generic summary.
        let payload: [String: Any] = [
            "summary": "generic",
            "change_summary": "specific change",
            "paths": ["a.swift"],
        ]
        let extracted = GateAskChangePaths.extract(fromPayload: payload)
        XCTAssertEqual(extracted.summary, "specific change")
    }

    func testJSONExtraction() {
        let json = """
        {"paths":["a.swift","b.swift"],"change_summary":"two files"}
        """
        let p = GateAskChangePaths.present(json: json)
        XCTAssertEqual(p.summary, "two files")
        XCTAssertEqual(p.pathLines, ["a.swift", "b.swift"])
    }

    // MARK: - Clip / overflow

    func testClipsLongPathList() {
        let paths = (1...10).map { "file\($0).swift" }
        let p = GateAskChangePaths.present(paths: paths, maxPaths: 4)
        XCTAssertEqual(p.pathLines.count, 4)
        XCTAssertEqual(p.overflowCount, 6)
        XCTAssertEqual(p.displayLines.last, "+6 more")
        XCTAssertTrue(p.joinedDisplay?.contains("+6 more") == true)
    }

    func testClipsLongPathString() {
        let long = String(repeating: "a", count: 80) + ".swift"
        let p = GateAskChangePaths.present(paths: [long], maxPathLength: 20)
        XCTAssertEqual(p.pathLines.count, 1)
        XCTAssertEqual(p.pathLines[0].count, 20)
        XCTAssertTrue(p.pathLines[0].hasSuffix("…"))
    }

    func testClipsLongSummary() {
        let long = String(repeating: "x", count: 120)
        let p = GateAskChangePaths.present(paths: [], summary: long, maxSummaryLength: 30)
        XCTAssertEqual(p.summary?.count, 30)
        XCTAssertTrue(p.summary?.hasSuffix("…") == true)
    }

    func testDedupesExactPaths() {
        let p = GateAskChangePaths.present(paths: ["a.swift", "a.swift", "b.swift", "a.swift"])
        XCTAssertEqual(p.pathLines, ["a.swift", "b.swift"])
        XCTAssertEqual(p.overflowCount, 0)
    }

    func testZeroMaxPathsShowsOnlyOverflowAndSummary() {
        let p = GateAskChangePaths.present(
            paths: ["a.swift", "b.swift"],
            summary: "two",
            maxPaths: 0
        )
        XCTAssertEqual(p.summary, "two")
        XCTAssertTrue(p.pathLines.isEmpty)
        XCTAssertEqual(p.overflowCount, 2)
        XCTAssertEqual(p.displayLines, ["two", "+2 more"])
    }

    // MARK: - Non-string values ignored

    func testNonStringArrayElementsIgnored() {
        let payload: [String: Any] = [
            "paths": [1, "real.swift", true, ["nested"]],
        ]
        let extracted = GateAskChangePaths.extract(fromPayload: payload)
        XCTAssertEqual(extracted.paths, ["real.swift"])
    }

    func testNonStringSummaryIgnored() {
        let payload: [String: Any] = [
            "summary": 42,
            "paths": ["a.swift"],
        ]
        let extracted = GateAskChangePaths.extract(fromPayload: payload)
        XCTAssertNil(extracted.summary)
        XCTAssertEqual(extracted.paths, ["a.swift"])
    }

    // MARK: - Accessibility

    func testAccessibilityLabelJoinsSummaryAndPaths() throws {
        let p = GateAskChangePaths.present(
            paths: ["a.swift", "b.swift"],
            summary: "Refactor"
        )
        let a11y = try XCTUnwrap(p.accessibilityLabel)
        XCTAssertTrue(a11y.contains("Refactor"))
        XCTAssertTrue(a11y.contains("a.swift"))
        XCTAssertTrue(a11y.contains("b.swift"))
    }
}
