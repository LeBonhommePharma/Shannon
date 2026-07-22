import XCTest
@testable import PillCore

@MainActor
final class VoiceSessionTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        var events: [String] = []
    }

    private func make(
        pendingConfirmation: Bool = false
    ) -> (VoiceSession, StubDictationProvider, Recorder) {
        let provider = StubDictationProvider()
        let rec = Recorder()
        let actions = VoiceActions(
            confirm: { rec.events.append("confirm") },
            deny: { rec.events.append("deny") },
            showStatus: { rec.events.append("status") },
            pause: { rec.events.append("pause") },
            runBenchmark: { rec.events.append("benchmark") },
            whatsDocking: { rec.events.append("docking") },
            query: { rec.events.append("query:\($0)") }
        )
        let session = VoiceSession(provider: provider, actions: actions)
        session.isConfirmationPending = { pendingConfirmation }
        return (session, provider, rec)
    }

    // MARK: Lifecycle

    func testStartBeginsListening() {
        let (session, provider, _) = make()
        session.start()
        XCTAssertTrue(session.isListening)
        XCTAssertTrue(provider.isRunning)
    }

    func testCancelStopsWithoutDispatching() {
        let (session, provider, rec) = make(pendingConfirmation: true)
        session.start()
        session.cancel()
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(provider.isRunning)
        XCTAssertTrue(rec.events.isEmpty)
    }

    func testToggleStartsThenStops() {
        let (session, _, _) = make()
        session.toggle()
        XCTAssertTrue(session.isListening)
        session.toggle()
        XCTAssertFalse(session.isListening)
    }

    func testPartialResultsSurfaceAsLiveTranscript() {
        let (session, provider, _) = make()
        session.start()
        provider.emit(.listening(partial: "run bench"))
        XCTAssertEqual(session.state.transcript, "run bench")
    }

    // MARK: Dispatch

    func testCommandsDispatchToTheirActions() {
        for (utterance, expected) in [
            ("show status", "status"),
            ("pause", "pause"),
            ("run benchmark", "benchmark"),
            ("what's docking", "docking"),
        ] {
            let (session, provider, rec) = make()
            session.start()
            provider.emit(.finished(utterance))
            XCTAssertEqual(rec.events, [expected], "failed on '\(utterance)'")
        }
    }

    func testFreeTextBecomesQuery() {
        let (session, provider, rec) = make()
        session.start()
        provider.emit(.finished("dock 1a4g against the Astex set"))
        XCTAssertEqual(rec.events, ["query:dock 1a4g against the Astex set"])
    }

    // MARK: Confirm/deny gating

    func testConfirmOnlyFiresWhenAPromptIsPending() {
        let (session, provider, rec) = make(pendingConfirmation: true)
        session.start()
        provider.emit(.finished("yes"))
        XCTAssertEqual(rec.events, ["confirm"])
    }

    func testSayingYesAtAnIdlePillDoesNotConfirmAnything() {
        // Must not silently approve whatever ran last.
        let (session, provider, rec) = make(pendingConfirmation: false)
        session.start()
        provider.emit(.finished("yes"))
        XCTAssertEqual(rec.events, ["query:yes"])
    }

    func testDenyIsGatedTheSameWay() {
        let (pending, p1, r1) = make(pendingConfirmation: true)
        pending.start()
        p1.emit(.finished("no"))
        XCTAssertEqual(r1.events, ["deny"])

        let (idle, p2, r2) = make(pendingConfirmation: false)
        idle.start()
        p2.emit(.finished("no"))
        XCTAssertEqual(r2.events, ["query:no"])
    }

    func testAmbiguousSentenceIsNeverTreatedAsConfirmation() {
        let (session, provider, rec) = make(pendingConfirmation: true)
        session.start()
        provider.emit(.finished("yes but check the ligand first"))
        XCTAssertEqual(rec.events, ["query:yes but check the ligand first"])
    }

    func testEmptyTranscriptDispatchesNothing() {
        let (session, provider, rec) = make(pendingConfirmation: true)
        session.start()
        provider.emit(.finished("   "))
        XCTAssertTrue(rec.events.isEmpty)
        XCTAssertEqual(session.state, .idle)
    }

    // MARK: Availability / authorization

    func testDeniedAuthorizationBlocksListening() {
        let (session, provider, _) = make()
        provider.authorization = .denied
        session.start()
        XCTAssertFalse(session.isListening)
        XCTAssertFalse(session.isAvailable)
        if case .failed = session.state {} else { XCTFail("expected .failed") }
    }

    func testNoOnDeviceModelRefusesRatherThanUsingServers() {
        // Shannon never falls back to server recognition.
        let (session, provider, _) = make()
        provider.supportsOnDevice = false
        session.start()
        XCTAssertFalse(session.isListening)
        XCTAssertFalse(session.isAvailable)
    }

    func testNotDeterminedTriggersAuthorizationRequestThenListens() {
        let (session, provider, _) = make()
        provider.authorization = .notDetermined
        session.start()
        // Stub grants immediately via its completion.
        XCTAssertEqual(session.authorization, .notDetermined)
        XCTAssertFalse(session.isListening, "must not listen before consent resolves")
    }
}
