import XCTest
@testable import PillCore

// T3 — Bubble honesty when motion is review/failed but mood is idle.
// Pure tests: CompanionBubbleText / CompanionState / moodLine.

private func t3Snap(
    id: String = "science",
    status: AgentRunStatus = .idle,
    presence: AgentPresence = .observed,
    secondsAgo: TimeInterval = 5,
    lastTask: String = "",
    now: Date = Date()
) -> AgentActivitySnapshot {
    AgentActivitySnapshot(
        id: id,
        displayName: AgentStyleCatalog.style(for: id).displayName,
        status: status,
        lastTask: lastTask,
        source: "test",
        updatedAt: now.addingTimeInterval(-secondsAgo),
        resumable: false,
        historyCount: 0,
        presence: presence
    )
}

final class CompanionBubbleHonestyT3Tests: XCTestCase {

    private let idleMoodWords = ["resting", "sleeping", "quiet", "idle"]

    func testRosterActivityReviewGoldenBubbleAndMoodLine() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            t3Snap(status: .idle, presence: .live, secondsAgo: 1, lastTask: "", now: now),
        ], scannedAt: now)
        let activity = [
            GateDBReader.ActivityEvent(
                id: 1,
                agentId: "science",
                at: now.addingTimeInterval(-5),
                type: "task_complete",
                label: "all tests passed",
                output: "ready for review"
            ),
        ]
        let roster = CompanionRoster.build(from: summary, now: now, activity: activity)
        XCTAssertEqual(roster.count, 1)
        let state = roster[0]
        XCTAssertEqual(state.codexMotion, .review)
        XCTAssertEqual(state.mood, .idle)
        XCTAssertEqual(state.lastOutcome, "review")

        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertEqual(bubble.text, "Ready for review")
        XCTAssertEqual(bubble.motion, .review)
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.detail, "Task complete")

        let bubbleBlob = "\(bubble.text) \(bubble.detail ?? "")".lowercased()
        for word in idleMoodWords {
            XCTAssertFalse(bubbleBlob.contains(word), bubbleBlob)
        }

        XCTAssertEqual(state.moodDisplayWord, "ready")
        XCTAssertTrue(state.moodLine.hasSuffix("· ready"), state.moodLine)
        for word in idleMoodWords {
            XCTAssertFalse(state.moodLine.lowercased().contains(word), state.moodLine)
        }
        XCTAssertTrue(state.accessibilityLine.contains("ready"))
    }

    func testRosterActivityFailedGoldenBubbleAndMoodLine() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            t3Snap(status: .idle, presence: .live, secondsAgo: 1, lastTask: "", now: now),
        ], scannedAt: now)
        let activity = [
            GateDBReader.ActivityEvent(
                id: 2,
                agentId: "science",
                at: now.addingTimeInterval(-2),
                type: "error",
                label: "build failed",
                output: "exit 1"
            ),
        ]
        let roster = CompanionRoster.build(from: summary, now: now, activity: activity)
        let state = roster[0]
        XCTAssertEqual(state.codexMotion, .failed)
        XCTAssertEqual(state.mood, .idle)
        XCTAssertEqual(state.lastOutcome, "failed")

        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertEqual(bubble.text, "Something feels off")
        XCTAssertEqual(bubble.motion, .failed)
        XCTAssertEqual(bubble.mood, .wary)
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.detail, "Failed")

        XCTAssertEqual(state.moodDisplayWord, "uneasy")
        XCTAssertTrue(state.moodLine.hasSuffix("· uneasy"), state.moodLine)
        for word in idleMoodWords {
            XCTAssertFalse(state.moodLine.lowercased().contains(word), state.moodLine)
        }
    }

    func testSelectorPresentFromActivityReviewAndFailed() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            t3Snap(id: "science", status: .idle, presence: .live, secondsAgo: 1,
                   lastTask: "", now: now),
        ], scannedAt: now)

        let reviewP = DesktopCompanionSelector.present(
            summary: summary,
            now: now,
            activity: [
                GateDBReader.ActivityEvent(
                    id: 10, agentId: "science", at: now.addingTimeInterval(-3),
                    type: "task_complete", label: "done", output: ""
                ),
            ]
        )
        XCTAssertEqual(reviewP.motion, .review)
        XCTAssertEqual(reviewP.bubble.text, "Ready for review")
        XCTAssertFalse(reviewP.bubble.claimsWork)
        XCTAssertEqual(reviewP.state?.moodDisplayWord, "ready")
        XCTAssertFalse(reviewP.state?.moodLine.lowercased().contains("resting") ?? true)

        let failedP = DesktopCompanionSelector.present(
            summary: summary,
            now: now,
            lastOutcomes: ["science": "failed"]
        )
        XCTAssertEqual(failedP.motion, .failed)
        XCTAssertEqual(failedP.bubble.text, "Something feels off")
        XCTAssertEqual(failedP.bubble.mood, .wary)
        XCTAssertEqual(failedP.state?.moodDisplayWord, "uneasy")
        XCTAssertFalse(failedP.state?.moodLine.lowercased().contains("resting") ?? true)
    }

    func testMoodLineHonestyWhenMotionReviewOrFailedButMoodIdle() {
        let review = CompanionState(
            agent: t3Snap(status: .idle, presence: .live, secondsAgo: 1),
            lastOutcome: "success"
        )
        XCTAssertEqual(review.mood, .idle)
        XCTAssertEqual(review.codexMotion, .review)
        XCTAssertEqual(review.moodDisplayWord, "ready")
        XCTAssertFalse(review.moodLine.contains("resting"))

        let failed = CompanionState(
            agent: t3Snap(status: .idle, presence: .live, secondsAgo: 1),
            lastOutcome: "failed"
        )
        XCTAssertEqual(failed.mood, .idle)
        XCTAssertEqual(failed.codexMotion, .failed)
        XCTAssertEqual(failed.moodDisplayWord, "uneasy")
        XCTAssertFalse(failed.moodLine.contains("resting"))

        let idle = CompanionState(
            agent: t3Snap(status: .idle, presence: .live, secondsAgo: 1)
        )
        XCTAssertEqual(idle.codexMotion, .idle)
        XCTAssertEqual(idle.moodDisplayWord, "resting")
        XCTAssertTrue(idle.moodLine.hasSuffix("· resting"))
    }
}
