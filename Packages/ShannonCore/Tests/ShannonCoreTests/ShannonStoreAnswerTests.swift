import XCTest
@testable import ShannonCore

/// Store-level answer / answerPending fail-closed paths (shipped ShannonStore).
@available(iOS 17.0, watchOS 10.0, macOS 14.0, *)
@MainActor
final class ShannonStoreAnswerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_850_000_000)

    private func store() -> ShannonStore {
        ShannonStore(backend: InMemorySyncBackend(), interval: 60, deviceName: "Test")
    }

    private func pending(
        id: String = "c1",
        question: String = "Dock?",
        createdOffset: TimeInterval = 0,
        lifetime: TimeInterval = 900
    ) -> PendingConfirmation {
        let created = now.addingTimeInterval(createdOffset)
        return PendingConfirmation(
            id: id,
            question: question,
            agentID: "science",
            createdAt: created,
            expiresAt: created.addingTimeInterval(lifetime)
        )
    }

    func testAnswerRefusesExpiredAndLeavesSnapshot() {
        let s = store()
        let expired = pending(id: "old", createdOffset: -2000, lifetime: 60)
        s.apply(ShannonSnapshot(confirmations: [expired], capturedAt: now))
        XCTAssertEqual(s.snapshot.confirmations.count, 1)

        let ok = s.answer(expired, .confirmed, source: .tap, origin: "Test", now: now)
        XCTAssertFalse(ok, "expired must refuse")
        XCTAssertEqual(s.snapshot.confirmations.count, 1, "snapshot must not clear on refuse")
        XCTAssertFalse(s.answeredConfirmations.contains("old"))
    }

    func testAnswerRefusesEmptyQuestion() {
        let s = store()
        let empty = pending(id: "empty", question: "   ")
        s.apply(ShannonSnapshot(confirmations: [empty], capturedAt: now))

        let ok = s.answer(empty, .denied, source: .voice, origin: "Test", now: now)
        XCTAssertFalse(ok)
        XCTAssertEqual(s.snapshot.confirmations.count, 1)
        XCTAssertFalse(s.answeredConfirmations.contains("empty"))
    }

    func testAnswerAcceptsFreshAndClearsSnapshot() {
        let s = store()
        let p = pending(id: "fresh")
        s.apply(ShannonSnapshot(confirmations: [p], capturedAt: now))

        let ok = s.answer(p, .confirmed, source: .headNod, origin: "iPhone", now: now)
        XCTAssertTrue(ok)
        XCTAssertTrue(s.snapshot.confirmations.isEmpty)
        XCTAssertTrue(s.answeredConfirmations.contains("fresh"))
    }

    func testAnswerPendingReturnsNilOnRefuse() {
        let s = store()
        // Expired is filtered out of oldestPendingConfirmation — inject empty
        // question so it is still "active" by age but fail-closed on answer.
        let bad = pending(id: "bad", question: "  ")
        s.apply(ShannonSnapshot(confirmations: [bad], capturedAt: now))

        let result = s.answerPending(.confirmed, source: .tap, now: now)
        XCTAssertNil(result, "answerPending must not return pending when answer refuses")
        XCTAssertEqual(s.snapshot.confirmations.count, 1)
    }

    func testAnswerPendingReturnsPendingOnlyWhenAccepted() {
        let s = store()
        let p = pending(id: "ok")
        s.apply(ShannonSnapshot(confirmations: [p], capturedAt: now))

        let result = s.answerPending(.denied, source: .crown, now: now)
        XCTAssertEqual(result?.id, "ok")
        XCTAssertTrue(s.snapshot.confirmations.isEmpty)
    }

    func testAnswerPendingNilWhenNoPending() {
        let s = store()
        s.apply(ShannonSnapshot(capturedAt: now))
        XCTAssertNil(s.answerPending(.confirmed, source: .tap, now: now))
    }

    /// Pad-path contract: callers must only run success haptic when answer is true.
    func testPadPathDoesNotTreatRefuseAsSuccess() {
        let s = store()
        let expired = pending(id: "exp", createdOffset: -5000, lifetime: 10)
        s.apply(ShannonSnapshot(confirmations: [expired], capturedAt: now))

        var didSuccessHaptic = false
        let accepted = s.answer(expired, .confirmed, source: .tap, origin: "iPad", now: now)
        if accepted {
            didSuccessHaptic = true
        }
        XCTAssertFalse(accepted)
        XCTAssertFalse(didSuccessHaptic)
        XCTAssertEqual(s.snapshot.confirmations.map(\.id), ["exp"])
    }
}
