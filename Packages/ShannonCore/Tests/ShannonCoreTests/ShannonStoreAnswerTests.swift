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

    // MARK: ENH-024 — local notification dismiss (no Mac retract)

    func testDismissMirroredNotificationsLocallyClearsSnapshot() {
        let s = store()
        let notes = [
            NotificationMirror(id: "n1", sender: "S", title: "T1", body: "B1"),
            NotificationMirror(id: "n2", sender: "S", title: "T2", body: "B2"),
        ]
        s.apply(ShannonSnapshot(notifications: notes, capturedAt: now))
        XCTAssertEqual(s.snapshot.notifications.count, 2)

        let cleared = s.dismissMirroredNotificationsLocally()
        XCTAssertEqual(cleared, 2)
        XCTAssertTrue(s.snapshot.notifications.isEmpty)
        XCTAssertEqual(s.locallyDismissedNotificationIDs, Set(["n1", "n2"]))
    }

    func testDismissMirroredNotificationsSurvivesReapplyUntilMacDrops() {
        let s = store()
        let notes = [
            NotificationMirror(id: "n1", sender: "S", title: "T1", body: "B1"),
            NotificationMirror(id: "n2", sender: "S", title: "T2", body: "B2"),
        ]
        s.apply(ShannonSnapshot(notifications: notes, capturedAt: now))
        _ = s.dismissMirroredNotificationsLocally()
        XCTAssertTrue(s.snapshot.notifications.isEmpty)

        // Mac still publishes both — local dismiss must keep them hidden.
        s.apply(ShannonSnapshot(notifications: notes, capturedAt: now))
        XCTAssertTrue(s.snapshot.notifications.isEmpty)
        XCTAssertEqual(s.locallyDismissedNotificationIDs, Set(["n1", "n2"]))

        // Mac drops n1; n2 still published → only n2 stays dismissed.
        s.apply(ShannonSnapshot(
            notifications: [notes[1]],
            capturedAt: now
        ))
        XCTAssertTrue(s.snapshot.notifications.isEmpty)
        XCTAssertEqual(s.locallyDismissedNotificationIDs, Set(["n2"]))

        // Mac drops all → tracking set empties; new note can surface.
        s.apply(ShannonSnapshot(notifications: [], capturedAt: now))
        XCTAssertTrue(s.locallyDismissedNotificationIDs.isEmpty)

        let fresh = NotificationMirror(id: "n3", sender: "S", title: "T3", body: "B3")
        s.apply(ShannonSnapshot(notifications: [fresh], capturedAt: now))
        XCTAssertEqual(s.snapshot.notifications.map(\.id), ["n3"])
    }

    func testDismissMirroredNotificationsEmptyIsNoOp() {
        let s = store()
        s.apply(ShannonSnapshot(capturedAt: now))
        XCTAssertEqual(s.dismissMirroredNotificationsLocally(), 0)
        XCTAssertTrue(s.locallyDismissedNotificationIDs.isEmpty)
    }

    /// Phone stem tertiary must call store local dismiss (not haptic-only).
    func testPhoneStemTertiaryWiresLocalDismiss() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = (try? String(
            contentsOf: root.appendingPathComponent(
                "iOS/Sources/ShannonPhone/PhoneModel.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            model.contains("dismissMirroredNotificationsLocally"),
            "PhoneModel tertiary stem must call store.dismissMirroredNotificationsLocally (ENH-024)"
        )
        XCTAssertTrue(
            model.contains("case .tertiary"),
            "PhoneModel must keep tertiary stem mapping"
        )
    }
}
