import XCTest
@testable import PillCore

final class FocusModeTests: XCTestCase {

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: Assertions.json shapes

    func testEmptyTopLevelArrayIsOff() {
        XCTAssertEqual(FocusModeLogic.parseAssertionsJSON(data("[]")), .off)
    }

    func testNonEmptyTopLevelArrayIsOn() {
        XCTAssertEqual(FocusModeLogic.parseAssertionsJSON(data(#"[{"id":1}]"#)), .on)
    }

    func testDataArrayEmptyIsOff() {
        XCTAssertEqual(FocusModeLogic.parseAssertionsJSON(data(#"{"data":[]}"#)), .off)
    }

    func testDataArrayNonEmptyIsOn() {
        XCTAssertEqual(
            FocusModeLogic.parseAssertionsJSON(data(#"{"data":[{"assertion":true}]}"#)),
            .on
        )
    }

    func testActiveModeAssertionKeyIsOn() {
        XCTAssertEqual(
            FocusModeLogic.parseAssertionsJSON(data(#"{"activeModeAssertion":{"mode":"x"}}"#)),
            .on
        )
    }

    func testNestedAssertionsEmptyIsOff() {
        let json = #"{"data":{"assertions":[]}}"#
        XCTAssertEqual(FocusModeLogic.parseAssertionsJSON(data(json)), .off)
    }

    func testNestedAssertionsNonEmptyIsOn() {
        let json = #"{"data":{"assertions":[{"a":1}]}}"#
        XCTAssertEqual(FocusModeLogic.parseAssertionsJSON(data(json)), .on)
    }

    func testUnknownSchemaFailsClosedToUnknown() {
        // Recognisable object but none of the known keys → do not invent off/on.
        XCTAssertEqual(
            FocusModeLogic.parseAssertionsJSON(data(#"{"schemaVersion":3,"foo":"bar"}"#)),
            .unknown
        )
    }

    func testInvalidJSONIsUnknown() {
        XCTAssertEqual(FocusModeLogic.parseAssertionsJSON(data("not-json{")), .unknown)
    }

    func testEmptyObjectUnderDataTreatsAsOff() {
        // Empty nested map under data → off (no active assertions).
        XCTAssertEqual(FocusModeLogic.parseAssertionsJSON(data(#"{"data":{}}"#)), .off)
    }

    // MARK: Mode name

    func testParseActiveModeNameTopLevel() {
        let json = #"{"activeModeIdentifier":"com.apple.donotdisturb.mode.work"}"#
        XCTAssertEqual(
            FocusModeLogic.parseActiveModeName(data(json)),
            "com.apple.donotdisturb.mode.work"
        )
    }

    func testParseActiveModeNameNested() {
        let json = #"{"data":{"modeIdentifier":"Sleep"}}"#
        XCTAssertEqual(FocusModeLogic.parseActiveModeName(data(json)), "Sleep")
    }

    func testParseActiveModeNameMissing() {
        XCTAssertNil(FocusModeLogic.parseActiveModeName(data(#"{"other":1}"#)))
    }

    // MARK: Reader fail-closed

    func testReaderMissingFileIsUnknown() {
        let missing = URL(fileURLWithPath: "/tmp/shannon-focus-missing-\(UUID().uuidString).json")
        let r = FocusModeReader.read(assertionsURL: missing, modesURL: missing)
        XCTAssertEqual(r.state, .unknown)
        XCTAssertNil(r.modeName)
    }

    func testReaderWithValidAssertions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let assertions = dir.appendingPathComponent("Assertions.json")
        let modes = dir.appendingPathComponent("Modes.json")
        try data(#"{"data":[{"id":"a"}]}"#).write(to: assertions)
        try data(#"{"activeModeIdentifier":"Work"}"#).write(to: modes)

        let r = FocusModeReader.read(assertionsURL: assertions, modesURL: modes)
        XCTAssertEqual(r.state, .on)
        XCTAssertEqual(r.modeName, "Work")
    }

    // MARK: Labels

    func testStateShortLabels() {
        XCTAssertEqual(FocusModeState.off.shortLabel, "Focus: off")
        XCTAssertEqual(FocusModeState.on.shortLabel, "Focus: on")
        XCTAssertEqual(FocusModeState.unknown.shortLabel, "Focus: unknown")
    }
}
