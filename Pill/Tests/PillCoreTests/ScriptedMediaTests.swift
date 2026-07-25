import XCTest
@testable import PillCore

final class ScriptedMediaTests: XCTestCase {

    func testParsePipeLinePlayingTrack() {
        let raw = "Configurational Entropy|Shannon|Docking|240.5|12.0|true\n"
        let info = ScriptedMediaLogic.parsePipeLine(raw, source: .music)
        XCTAssertEqual(info?.title, "Configurational Entropy")
        XCTAssertEqual(info?.artist, "Shannon")
        XCTAssertEqual(info?.album, "Docking")
        XCTAssertEqual(info?.duration ?? 0, 240.5, accuracy: 0.001)
        XCTAssertEqual(info?.elapsed ?? 0, 12.0, accuracy: 0.001)
        XCTAssertEqual(info?.isPlaying, true)
        XCTAssertEqual(info?.sourceBundleID, "com.apple.Music")
    }

    func testParsePipeLinePausedSpotify() {
        let raw = "Track|Artist|Album|180|30|false"
        let info = ScriptedMediaLogic.parsePipeLine(raw, source: .spotify)
        XCTAssertEqual(info?.isPlaying, false)
        XCTAssertEqual(info?.sourceBundleID, "com.spotify.client")
    }

    func testParsePipeLinePlayingKeyword() {
        let info = ScriptedMediaLogic.parsePipeLine(
            "A|B|C|1|0|playing", source: .music
        )
        XCTAssertEqual(info?.isPlaying, true)
    }

    func testParsePipeLineRejectsEmptyTitleAndArtist() {
        XCTAssertNil(ScriptedMediaLogic.parsePipeLine("||||0|true", source: .music))
    }

    func testParsePipeLineRejectsTooFewFields() {
        XCTAssertNil(ScriptedMediaLogic.parsePipeLine("only|two", source: .music))
    }

    func testParsePipeLineUsesLastLine() {
        let raw = "noise\nReal Title|Real Artist|Alb|10|1|1"
        let info = ScriptedMediaLogic.parsePipeLine(raw, source: .music)
        XCTAssertEqual(info?.title, "Real Title")
        XCTAssertEqual(info?.artist, "Real Artist")
    }

    func testParsePipeLineAllowsTitleOnly() {
        let info = ScriptedMediaLogic.parsePipeLine("Solo||||0|false", source: .music)
        XCTAssertEqual(info?.title, "Solo")
        XCTAssertEqual(info?.artist, "")
    }

    func testStatusScriptMentionsApp() {
        XCTAssertTrue(ScriptedMediaLogic.statusScript(for: .music).contains("Music"))
        XCTAssertTrue(ScriptedMediaLogic.statusScript(for: .spotify).contains("Spotify"))
        // Operator precedence: running AND (playing OR paused)
        XCTAssertTrue(ScriptedMediaLogic.statusScript(for: .music)
            .contains("(player state is playing or player state is paused)"))
    }

    func testTransportScripts() {
        XCTAssertTrue(ScriptedMediaLogic.toggleScript(for: .music).contains("playpause"))
        XCTAssertTrue(ScriptedMediaLogic.nextScript(for: .spotify).contains("next track"))
        XCTAssertTrue(ScriptedMediaLogic.previousScript(for: .music).contains("previous track"))
    }

    func testAppBundleIDs() {
        XCTAssertEqual(ScriptedMediaLogic.App.music.bundleID, "com.apple.Music")
        XCTAssertEqual(ScriptedMediaLogic.App.spotify.bundleID, "com.spotify.client")
    }
}
