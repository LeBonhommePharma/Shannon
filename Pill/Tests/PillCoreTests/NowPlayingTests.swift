import XCTest
@testable import PillCore

final class NowPlayingTests: XCTestCase {

    private func track(
        _ title: String = "Configurational Entropy",
        artist: String = "Shannon",
        playing: Bool = true,
        duration: Double = 200,
        elapsed: Double = 0
    ) -> NowPlayingInfo {
        NowPlayingInfo(title: title, artist: artist, duration: duration,
                       elapsed: elapsed, isPlaying: playing)
    }

    // MARK: State machine

    func testStartsIdle() {
        let m = NowPlayingStateMachine()
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.collapsedLabel())
    }

    func testUpdateEntersPlayingOrPaused() {
        var m = NowPlayingStateMachine()
        m.apply(.updated(track(playing: true)))
        XCTAssertEqual(m.state, .playing(track(playing: true)))

        m.apply(.updated(track(playing: false)))
        XCTAssertEqual(m.state, .paused(track(playing: false)))
    }

    func testEmptyMetadataCollapsesToIdle() {
        var m = NowPlayingStateMachine()
        m.apply(.updated(track()))
        m.apply(.updated(NowPlayingInfo(title: "", artist: "")))
        XCTAssertEqual(m.state, .idle)
    }

    func testPlaybackChangedPreservesMetadata() {
        var m = NowPlayingStateMachine()
        m.apply(.updated(track(elapsed: 30)))
        m.apply(.playbackChanged(isPlaying: false))

        XCTAssertEqual(m.state.info?.title, "Configurational Entropy")
        XCTAssertEqual(m.state.info?.elapsed, 30)
        XCTAssertEqual(m.state.info?.isPlaying, false)
        if case .paused = m.state {} else { XCTFail("expected paused") }
    }

    func testPlaybackChangedOnIdleIsIgnored() {
        var m = NowPlayingStateMachine()
        m.apply(.playbackChanged(isPlaying: true))
        XCTAssertEqual(m.state, .idle)
    }

    func testElapsedClampsToDuration() {
        var m = NowPlayingStateMachine()
        m.apply(.updated(track(duration: 100)))
        m.apply(.elapsed(150))
        XCTAssertEqual(m.state.info?.elapsed, 100)
    }

    func testElapsedOnLiveStreamIsNotClamped() {
        // Duration 0 means a live stream; elapsed should keep counting up.
        var m = NowPlayingStateMachine()
        m.apply(.updated(track(duration: 0)))
        m.apply(.elapsed(4_000))
        XCTAssertEqual(m.state.info?.elapsed, 4_000)
        XCTAssertEqual(m.state.info?.progress, 0)
    }

    func testClearedReturnsToIdle() {
        var m = NowPlayingStateMachine()
        m.apply(.updated(track()))
        m.apply(.cleared)
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.collapsedLabel())
    }

    // MARK: Collapsed label

    func testCollapsedLabelShowsGlyphTitleAndArtist() {
        var m = NowPlayingStateMachine()
        m.apply(.updated(track(playing: true)))
        XCTAssertEqual(m.collapsedLabel(), "▶ Configurational Entropy — Shannon")

        m.apply(.playbackChanged(isPlaying: false))
        XCTAssertEqual(m.collapsedLabel(), "❙❙ Configurational Entropy — Shannon")
    }

    func testCollapsedLabelOmitsEmptyArtist() {
        var m = NowPlayingStateMachine()
        m.apply(.updated(NowPlayingInfo(title: "Podcast 42", isPlaying: true)))
        XCTAssertEqual(m.collapsedLabel(), "▶ Podcast 42")
    }

    func testCollapsedLabelTruncatesToFitTheNotch() {
        var m = NowPlayingStateMachine()
        m.apply(.updated(track("A Very Long Track Title That Will Not Fit",
                               artist: "An Equally Long Artist Name")))
        let label = try! XCTUnwrap(m.collapsedLabel(maxLength: 20))
        XCTAssertEqual(label.count, 20)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    // MARK: Progress / formatting

    func testProgressFraction() {
        XCTAssertEqual(track(duration: 200, elapsed: 50).progress, 0.25)
        XCTAssertEqual(track(duration: 0, elapsed: 50).progress, 0)
    }

    func testTimeFormatting() {
        XCTAssertEqual(NowPlayingInfo.formatTime(0), "0:00")
        XCTAssertEqual(NowPlayingInfo.formatTime(65), "1:05")
        XCTAssertEqual(NowPlayingInfo.formatTime(3_599), "59:59")
        XCTAssertEqual(NowPlayingInfo.formatTime(-4), "0:00")
        XCTAssertEqual(NowPlayingInfo.formatTime(.nan), "0:00")
    }

    // MARK: MediaRemote payload translation

    func testMediaRemotePayloadBecomesUpdateEvent() throws {
        let raw: [String: Any] = [
            "kMRMediaRemoteNowPlayingInfoTitle": "Bohemian Entropy",
            "kMRMediaRemoteNowPlayingInfoArtist": "Queue",
            "kMRMediaRemoteNowPlayingInfoAlbum": "A Night At The Notch",
            "kMRMediaRemoteNowPlayingInfoDuration": 355.0,
            "kMRMediaRemoteNowPlayingInfoElapsedTime": 42.0,
            "kMRMediaRemoteNowPlayingInfoPlaybackRate": 1.0,
        ]
        let event = try XCTUnwrap(MediaRemoteProvider.event(from: raw))
        guard case .updated(let info) = event else { return XCTFail("expected .updated") }
        XCTAssertEqual(info.title, "Bohemian Entropy")
        XCTAssertEqual(info.artist, "Queue")
        XCTAssertEqual(info.duration, 355)
        XCTAssertTrue(info.isPlaying)
    }

    func testZeroPlaybackRateReadsAsPaused() throws {
        let raw: [String: Any] = [
            "kMRMediaRemoteNowPlayingInfoTitle": "Paused Track",
            "kMRMediaRemoteNowPlayingInfoPlaybackRate": 0.0,
        ]
        let event = try XCTUnwrap(MediaRemoteProvider.event(from: raw))
        guard case .updated(let info) = event else { return XCTFail("expected .updated") }
        XCTAssertFalse(info.isPlaying)
    }

    func testEmptyMediaRemotePayloadYieldsNil() {
        // This is what a non-entitled process sees on macOS 15.4+.
        XCTAssertNil(MediaRemoteProvider.event(from: [:]))
    }

    // MARK: Model + provider wiring

    @MainActor
    func testModelForwardsTransportCommandsToProvider() {
        let stub = StubNowPlayingProvider()
        let model = NowPlayingModel(provider: stub)
        model.togglePlayPause()
        model.nextTrack()
        model.previousTrack()
        model.seek(to: 0.5)
        XCTAssertEqual(stub.commands, ["togglePlayPause", "nextTrack", "previousTrack", "seek:0.500"])
    }

    @MainActor
    func testModelPublishesProviderEvents() {
        let stub = StubNowPlayingProvider()
        let model = NowPlayingModel(provider: stub)
        model.start()

        let expectation = expectation(description: "state updated")
        stub.emit(.updated(track()))
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(model.state.info?.title, "Configurational Entropy")
        XCTAssertEqual(model.collapsedLabel, "▶ Configurational Entropy — Shannon")
        model.stop()
    }
}
