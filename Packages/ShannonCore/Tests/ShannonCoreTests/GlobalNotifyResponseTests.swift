import XCTest
@testable import ShannonCore

/// OS-agnostic global notify/respond contract — pure, no UIKit/AppKit.
final class GlobalNotifyResponseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pending(
        id: String = "c1",
        question: String = "Dock 1a4g?",
        agent: String? = "science",
        created: TimeInterval = 0,
        lifetime: TimeInterval = 900
    ) -> PendingConfirmation {
        let createdAt = now.addingTimeInterval(created)
        return PendingConfirmation(
            id: id,
            question: question,
            detail: "",
            agentID: agent,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(lifetime)
        )
    }

    // MARK: Expiry fail-closed

    func testExpiredPromptRejectsAnswer() {
        let p = pending(created: -2000, lifetime: 60)
        XCTAssertTrue(p.isExpired(now: now))
        XCTAssertFalse(GlobalNotifyResponse.canAnswer(p, now: now))
        XCTAssertNil(
            GlobalNotifyResponse.makeResponse(
                for: p, answer: .confirmed, source: .tap, origin: "iPhone", now: now
            )
        )
    }

    func testFreshPromptAcceptsAnswerWithSource() {
        let p = pending()
        XCTAssertTrue(GlobalNotifyResponse.canAnswer(p, now: now))
        let r = GlobalNotifyResponse.makeResponse(
            for: p, answer: .denied, source: .headShake, origin: "iPhone", now: now
        )
        XCTAssertEqual(r?.id, p.id)
        XCTAssertEqual(r?.answer, .denied)
        XCTAssertEqual(r?.source, .headShake)
        XCTAssertEqual(r?.origin, "iPhone")
        // Optional agent not invented on the response — lives only on pending.
        XCTAssertEqual(p.agentID, "science")
    }

    func testEmptyQuestionCannotAnswer() {
        let p = pending(question: "   ", agent: nil)
        XCTAssertFalse(GlobalNotifyResponse.canAnswer(p, now: now))
    }

    func testOptionalAgentStaysNilWhenOmitted() {
        let p = pending(agent: nil)
        XCTAssertNil(p.agentID)
        let content = GlobalNotifyResponse.content(for: p)
        XCTAssertNil(content.agentID)
        XCTAssertEqual(content.title, "Approval needed")
    }

    // MARK: Edge-triggered alerts

    func testConfirmationEdgeFiresOnceNotOnRepeat() {
        var edge = ConfirmationAlertEdge()
        let snap = ShannonSnapshot(confirmations: [pending(id: "c1")])
        let first = edge.edges(from: snap, now: now)
        XCTAssertEqual(first.map(\.id), ["c1"])
        XCTAssertTrue(edge.edges(from: snap, now: now).isEmpty, "identical pending must not re-haptic")
        // New id still edges.
        let snap2 = ShannonSnapshot(confirmations: [
            pending(id: "c1"),
            pending(id: "c2", question: "Other?"),
        ])
        XCTAssertEqual(edge.edges(from: snap2, now: now).map(\.id), ["c2"])
    }

    func testAssemblerAndEdgeAgreeOnSingleFire() {
        var assembler = SnapshotAssembler()
        var edge = ConfirmationAlertEdge()
        let p = pending(id: "edge-1")
        let snap = ShannonSnapshot(confirmations: [p])
        XCTAssertEqual(assembler.consume(snap).count, 1)
        XCTAssertEqual(edge.edges(from: snap, now: now).count, 1)
        XCTAssertTrue(assembler.consume(snap).isEmpty)
        XCTAssertTrue(edge.edges(from: snap, now: now).isEmpty)
    }

    // MARK: Multi-surface identity

    func testConsumersAgreeOnSameSnapshotPending() {
        let snap = ShannonSnapshot(confirmations: [
            pending(id: "shared", question: "Approve deploy?", agent: "claude_code"),
        ])
        // Two platform consumers fed the same snapshot.
        XCTAssertTrue(GlobalNotifyResponse.consumersAgreeOnPending([snap, snap], now: now))
        let a = GlobalPendingView.from(GlobalNotifyResponse.primaryPending(in: snap, now: now)!, now: now)
        let b = GlobalPendingView.from(GlobalNotifyResponse.primaryPending(in: snap, now: now)!, now: now)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.question, b.question)
        XCTAssertEqual(a.focusLine, "Needs you · claude_code")
        XCTAssertTrue(a.isAnswerable)
    }

    func testDivergentQueuesDisagree() {
        let mac = ShannonSnapshot(confirmations: [pending(id: "a", question: "Mac only?")])
        let phone = ShannonSnapshot(confirmations: [pending(id: "b", question: "Phone only?")])
        XCTAssertFalse(GlobalNotifyResponse.consumersAgreeOnPending([mac, phone], now: now))
    }

    func testNeedsYouFocusLineConsistent() {
        let snap = ShannonSnapshot(confirmations: [
            pending(id: "c", question: "Run migrate?", agent: "codex"),
        ])
        XCTAssertEqual(
            GlobalNotifyResponse.needsYouFocusLine(in: snap, now: now),
            "Needs you · codex"
        )
    }

    // MARK: Gesture / voice mapping

    func testHeadGestureMapsNodConfirmShakeDeny() {
        let nod = GlobalNotifyResponse.mapHeadGesture(.nod)
        XCTAssertEqual(nod.0, .confirmed)
        XCTAssertEqual(nod.1, .headNod)
        let shake = GlobalNotifyResponse.mapHeadGesture(.shake)
        XCTAssertEqual(shake.0, .denied)
        XCTAssertEqual(shake.1, .headShake)
    }

    func testVoiceAndTapAndCrownAndStemMappings() {
        XCTAssertEqual(GlobalNotifyResponse.mapVoice(.confirm)?.0, .confirmed)
        XCTAssertEqual(GlobalNotifyResponse.mapVoice(.deny)?.1, .voice)
        XCTAssertNil(GlobalNotifyResponse.mapVoice(.status))
        XCTAssertEqual(GlobalNotifyResponse.mapTap(approved: true).1, .tap)
        XCTAssertEqual(GlobalNotifyResponse.mapCrown(approved: false).0, .denied)
        XCTAssertEqual(GlobalNotifyResponse.mapStem(approved: true).1, .stemPress)
        XCTAssertEqual(GlobalNotifyResponse.mapDoubleTap(approved: false).1, .doubleTap)
    }

    func testWatchMessageAnswerRoundTripWithSource() throws {
        let msg = WatchMessage.answer(id: "c9", answer: .confirmed, source: .crown)
        let encoded = try WatchMessageCodec.encode(msg)
        let decoded = try WatchMessageCodec.decode(encoded)
        guard case .answer(let id, let answer, let source) = decoded else {
            return XCTFail("expected answer message")
        }
        XCTAssertEqual(id, "c9")
        XCTAssertEqual(answer, .confirmed)
        XCTAssertEqual(source, .crown)
    }
}
