import XCTest
@testable import ShannonCore

/// Covers the paths that can act on LP's behalf — gestures, voice, and the
/// confirmation round-trip. A false positive here answers a real agent
/// question wrongly, so the negative cases matter more than the happy path.
final class ConfirmationAndVoiceTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Voice parsing

    func testConfirmAndDenyPhrases() {
        for phrase in ["confirm", "Confirm.", "yes", "yep", "go ahead", "OK"] {
            XCTAssertEqual(VoiceCommand.parse(phrase), .confirm, "\(phrase)")
        }
        for phrase in ["deny", "no", "nope", "cancel", "abort", "Reject!"] {
            XCTAssertEqual(VoiceCommand.parse(phrase), .deny, "\(phrase)")
        }
    }

    /// The worst failure this parser could have: hearing "confirm" inside a
    /// refusal and answering yes.
    func testNegationWinsOverEmbeddedConfirm() {
        XCTAssertEqual(VoiceCommand.parse("no, don't confirm"), .deny)
        XCTAssertEqual(VoiceCommand.parse("do not confirm that"), .deny)
        XCTAssertEqual(VoiceCommand.parse("cancel, I said confirm earlier"), .deny)
    }

    func testWakePhraseIsStripped() {
        XCTAssertEqual(VoiceCommand.parse("Hey Siri, Shannon confirm"), .confirm)
        XCTAssertEqual(VoiceCommand.parse("shannon status"), .status)
    }

    func testQueryCommands() {
        XCTAssertEqual(VoiceCommand.parse("what's docking"), .benchmark)
        XCTAssertEqual(VoiceCommand.parse("show status"), .status)
        XCTAssertEqual(VoiceCommand.parse("what's playing"), .nowPlaying)
    }

    /// Whole-word matching: "ok" must not fire inside "okra", and "no" must
    /// not fire inside "notice".
    func testSubstringsDoNotFireCommands() {
        XCTAssertEqual(VoiceCommand.parse("okra harvest report"), .freeform("okra harvest report"))
        XCTAssertEqual(VoiceCommand.parse("notice the pattern"), .freeform("notice the pattern"))
    }

    func testUnrecognisedSpeechBecomesFreeform() {
        XCTAssertEqual(
            VoiceCommand.parse("how many targets are left in the run"),
            .freeform("how many targets are left in the run")
        )
        XCTAssertEqual(VoiceCommand.parse("   "), .freeform(""))
    }

    func testConfirmationAnswerMapping() {
        XCTAssertEqual(VoiceCommand.confirm.confirmationAnswer, .confirmed)
        XCTAssertEqual(VoiceCommand.deny.confirmationAnswer, .denied)
        XCTAssertNil(VoiceCommand.status.confirmationAnswer)
    }

    // MARK: Head gestures

    private func samples(
        axis: WritableKeyPath<HeadAttitudeSample, Double>,
        degrees: Double,
        start: TimeInterval = 0,
        step: TimeInterval = 0.1
    ) -> [HeadAttitudeSample] {
        // neutral -> excursion -> back to neutral
        let magnitudes = [0.0, degrees, degrees, 0.0]
        return magnitudes.enumerated().map { index, degrees in
            var sample = HeadAttitudeSample(pitch: 0, yaw: 0, timestamp: start + Double(index) * step)
            sample[keyPath: axis] = degrees * .pi / 180
            return sample
        }
    }

    func testNodConfirmsAndShakeDenies() {
        var detector = HeadGestureDetector()
        detector.arm()
        var fired: HeadGesture?
        for sample in samples(axis: \.pitch, degrees: 25) {
            if let g = detector.process(sample) { fired = g }
        }
        XCTAssertEqual(fired, .nod)
        XCTAssertEqual(fired?.answer, .confirmed)

        var shakeDetector = HeadGestureDetector()
        shakeDetector.arm()
        var shook: HeadGesture?
        for sample in samples(axis: \.yaw, degrees: 25) {
            if let g = shakeDetector.process(sample) { shook = g }
        }
        XCTAssertEqual(shook, .shake)
        XCTAssertEqual(shook?.answer, .denied)
    }

    /// The single most important safety property: head movement while no
    /// question is pending must never produce an answer.
    func testDisarmedDetectorNeverFires() {
        var detector = HeadGestureDetector()
        for sample in samples(axis: \.pitch, degrees: 40) {
            XCTAssertNil(detector.process(sample))
        }
        XCTAssertFalse(detector.isArmed)
    }

    func testSmallMovementsAreIgnored() {
        var detector = HeadGestureDetector()
        detector.arm()
        for sample in samples(axis: \.pitch, degrees: 8) {
            XCTAssertNil(detector.process(sample))
        }
    }

    /// A head held down and slowly raised is posture, not a nod.
    func testSlowMovementIsNotAGesture() {
        var detector = HeadGestureDetector()
        detector.arm()
        var fired: HeadGesture?
        for sample in samples(axis: \.pitch, degrees: 25, step: 0.5) {
            if let g = detector.process(sample) { fired = g }
        }
        XCTAssertNil(fired, "excursion longer than maxDuration must not fire")
    }

    /// 2 s debounce: one enthusiastic nod must not answer two questions.
    func testLockoutSuppressesImmediateSecondGesture() {
        var detector = HeadGestureDetector()
        detector.arm()
        var count = 0
        for sample in samples(axis: \.pitch, degrees: 25) where detector.process(sample) != nil {
            count += 1
        }
        // Second nod immediately after, inside the 2 s lockout.
        for sample in samples(axis: \.pitch, degrees: 25, start: 0.4)
        where detector.process(sample) != nil {
            count += 1
        }
        XCTAssertEqual(count, 1)

        // Once the lockout expires, gestures work again.
        var fired: HeadGesture?
        for sample in samples(axis: \.pitch, degrees: 25, start: 3.0) {
            if let g = detector.process(sample) { fired = g }
        }
        XCTAssertEqual(fired, .nod)
    }

    /// A user whose head rests tilted must still be able to nod.
    func testNeutralIsRelativeToArmedPosture() {
        var detector = HeadGestureDetector()
        detector.arm()
        let tilt = 20.0 * .pi / 180
        var fired: HeadGesture?
        for (index, delta) in [0.0, 25.0, 25.0, 0.0].enumerated() {
            let sample = HeadAttitudeSample(
                pitch: tilt + delta * .pi / 180,
                yaw: 0,
                timestamp: Double(index) * 0.1
            )
            if let g = detector.process(sample) { fired = g }
        }
        XCTAssertEqual(fired, .nod)
    }

    func testYawWrapAroundDoesNotFireGesture() {
        // Crossing the ±π seam is a 0.02 rad move, not a full circle.
        XCTAssertEqual(HeadGestureDetector.angleDelta(.pi - 0.01, -.pi + 0.01), -0.02, accuracy: 1e-9)
    }

    // MARK: Confirmation records

    func testPendingConfirmationRoundTrips() throws {
        let pending = PendingConfirmation(
            id: "c1",
            question: "Dock this ligand?",
            detail: "1a4g · Astex Diverse",
            agentID: "local_9c754fdc",
            createdAt: fixedDate
        )
        XCTAssertEqual(try pending.reencoded(), pending)
    }

    func testConfirmationResponseRoundTrips() throws {
        let response = ConfirmationResponse(
            id: "c1", answer: .confirmed, source: .headNod,
            origin: "iPhone", answeredAt: fixedDate
        )
        XCTAssertEqual(try response.reencoded(), response)
    }

    func testExpiredConfirmationIsNotSurfaced() {
        let stale = PendingConfirmation(
            id: "old", question: "Old?", createdAt: fixedDate,
            expiresAt: fixedDate.addingTimeInterval(60)
        )
        let fresh = PendingConfirmation(
            id: "new", question: "New?", createdAt: fixedDate.addingTimeInterval(120),
            expiresAt: fixedDate.addingTimeInterval(9999)
        )
        let snapshot = ShannonSnapshot(confirmations: [stale, fresh])
        let now = fixedDate.addingTimeInterval(300)

        XCTAssertEqual(snapshot.oldestPendingConfirmation(now: now)?.id, "new")
        XCTAssertTrue(stale.isExpired(now: now))
    }

    /// A pending question outranks docking progress and media everywhere.
    func testPendingConfirmationDominatesComplication() {
        let snapshot = ShannonSnapshot(
            docking: [DockingProgress(id: "b", benchmarkName: "Astex",
                                      targetsComplete: 34, targetsTotal: 85)],
            nowPlaying: NowPlayingSnapshot(title: "Track", isPlaying: true),
            confirmations: [PendingConfirmation(id: "c", question: "Dock 1a4g?")]
        )
        XCTAssertEqual(snapshot.complicationLine(), "? Dock 1a4g?")
        XCTAssertEqual(snapshot.watchCards().first, "? Dock 1a4g?")
        XCTAssertTrue(snapshot.isAwaitingConfirmation)
    }

    func testAssemblerAlertsOnFirstPendingConfirmation() {
        var assembler = SnapshotAssembler()
        let pending = PendingConfirmation(id: "c1", question: "Dock?")
        // Unlike other alerts, this fires on the very first snapshot: the
        // agent is blocked right now, whether or not the app just launched.
        XCTAssertEqual(
            assembler.consume(ShannonSnapshot(confirmations: [pending])),
            [.confirmationRequested(pending)]
        )
        XCTAssertTrue(assembler.consume(ShannonSnapshot(confirmations: [pending])).isEmpty)
    }

    // MARK: Publisher side

    func testResponsesRetractPromptsAndClearQueue() async throws {
        let backend = InMemorySyncBackend()
        let publisher = ShannonPublisher(backend: backend)
        let pending = PendingConfirmation(id: "c1", question: "Dock?", createdAt: fixedDate,
                                          expiresAt: fixedDate.addingTimeInterval(600))
        try await publisher.publish(pending)
        try await backend.save(ConfirmationResponse(id: "c1", answer: .confirmed,
                                                    source: .headNod, origin: "iPhone",
                                                    answeredAt: fixedDate))

        let handled = try await publisher.consumeConfirmationResponses(now: fixedDate)
        XCTAssertEqual(handled.count, 1)
        XCTAssertEqual(handled.first?.response.answer, .confirmed)
        XCTAssertEqual(handled.first?.confirmation?.id, "c1")
        XCTAssertEqual(backend.recordCount(PendingConfirmation.recordType), 0,
                       "answering retracts the prompt from every device")
        XCTAssertEqual(backend.recordCount(ConfirmationResponse.recordType), 0)
    }

    /// An answer arriving after the agent gave up must not be acted on.
    func testExpiredPromptResponseIsDiscarded() async throws {
        let backend = InMemorySyncBackend()
        let publisher = ShannonPublisher(backend: backend)
        try await publisher.publish(
            PendingConfirmation(id: "c1", question: "Dock?", createdAt: fixedDate,
                                expiresAt: fixedDate.addingTimeInterval(60))
        )
        try await backend.save(ConfirmationResponse(id: "c1", answer: .confirmed,
                                                    source: .voice, origin: "Watch",
                                                    answeredAt: fixedDate.addingTimeInterval(600)))

        let handled = try await publisher.consumeConfirmationResponses(
            now: fixedDate.addingTimeInterval(600)
        )
        XCTAssertTrue(handled.isEmpty)
        XCTAssertEqual(backend.recordCount(ConfirmationResponse.recordType), 0,
                       "discarded answers are still drained from the queue")
    }
}
