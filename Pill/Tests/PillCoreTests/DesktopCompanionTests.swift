import XCTest
@testable import PillCore

// Desktop companion: bubble honesty + always-on-top window policy.
// Pure tests — no window server required.

// MARK: - Helpers

private func snap(
    id: String = "science",
    status: AgentRunStatus = .idle,
    presence: AgentPresence = .observed,
    secondsAgo: TimeInterval = 5,
    lastTask: String = "docking 1ACJ",
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

// MARK: - Bubble honesty matrix

final class CompanionBubbleTextTests: XCTestCase {

    /// Observed/offline must never produce claimsWork=true bubble text.
    func testNonLivePresenceNeverClaimsWorkInBubble() {
        for presence in [AgentPresence.observed, .offline] {
            for status in [AgentRunStatus.active, .midTask, .blocked, .idle] {
                let state = CompanionState(
                    agent: snap(status: status, presence: presence, secondsAgo: 1)
                )
                let bubble = CompanionBubbleText.derive(from: state)
                XCTAssertFalse(
                    bubble.claimsWork,
                    "presence=\(presence) status=\(status) must not claim work; text=\(bubble.text)"
                )
                // Must not use running language.
                let lower = bubble.text.lowercased()
                XCTAssertFalse(lower.contains("on it"), bubble.text)
                XCTAssertFalse(lower.contains("working"), bubble.text)
                XCTAssertFalse(lower.contains("running"), bubble.text)
            }
        }
    }

    func testLiveBusyBubbleClaimsWork() {
        let state = CompanionState(
            agent: snap(status: .active, presence: .live, secondsAgo: 1)
        )
        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertTrue(bubble.claimsWork)
        XCTAssertEqual(bubble.text, "On it")
        XCTAssertEqual(bubble.motion, .running)
        XCTAssertEqual(bubble.mood, .alert)
    }

    func testPendingAskBubbleIsNeedsYouNotWorking() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(status: .active, presence: .live, secondsAgo: 1, now: now),
        ], scannedAt: now)
        let asks = [
            GateDBReader.PendingAsk(
                interactionId: "a1",
                agentId: "science",
                prompt: "Approve?",
                createdAt: now
            ),
        ]
        let roster = CompanionRoster.build(from: summary, now: now, pendingAsks: asks)
        let bubble = CompanionBubbleText.derive(from: roster[0])
        XCTAssertEqual(bubble.text, "Needs you")
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.motion, .waiting)
    }

    func testCollapseBubbleIsUneasyNotWorking() {
        let state = CompanionState(
            agent: snap(status: .active, presence: .live, secondsAgo: 1),
            entropyDelta: -5.0
        )
        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertEqual(bubble.text, "Something feels off")
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.motion, .failed)
    }

    func testOfflineBubbleIsSleeping() {
        let state = CompanionState(
            agent: snap(status: .idle, presence: .offline, secondsAgo: 10)
        )
        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertEqual(bubble.text, "Sleeping")
        XCTAssertFalse(bubble.claimsWork)
    }

    func testObservedBubbleIsResting() {
        let state = CompanionState(
            agent: snap(status: .active, presence: .observed, secondsAgo: 2)
        )
        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertEqual(bubble.text, "Resting")
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.motion, .idle)
    }

    func testReviewBubble() {
        let bubble = CompanionBubbleText.derive(.init(
            presence: .live,
            status: .idle,
            mood: .idle,
            motion: .review,
            displayName: "Science",
            statusLine: "live",
            lastTask: "tests green"
        ))
        XCTAssertEqual(bubble.text, "Ready for review")
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.detail, "tests green")
    }

    /// B2: Signals(state:) must carry lastOutcome (was hard-coded nil).
    func testSignalsFromStateCarriesLastOutcome() {
        let state = CompanionState(
            agent: snap(status: .idle, presence: .live, secondsAgo: 1, lastTask: ""),
            lastOutcome: "success"
        )
        XCTAssertEqual(state.lastOutcome, "success")
        XCTAssertEqual(state.codexMotion, .review)
        let signals = CompanionBubbleText.Signals(state: state)
        XCTAssertEqual(signals.lastOutcome, "success")
        XCTAssertEqual(signals.motion, .review)
    }

    /// B2: derive(from:) with roster outcome → review bubble + task-complete detail.
    func testStateWithSuccessOutcomeShowsReviewBubbleEvidence() {
        let state = CompanionState(
            agent: snap(status: .idle, presence: .live, secondsAgo: 1, lastTask: ""),
            lastOutcome: "success"
        )
        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertEqual(bubble.text, "Ready for review")
        XCTAssertEqual(bubble.motion, .review)
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.detail, "Task complete")
    }

    /// B2: failed lastOutcome → failed bubble with "Failed" detail when no task.
    func testStateWithFailedOutcomeShowsFailedBubbleEvidence() {
        let state = CompanionState(
            agent: snap(status: .idle, presence: .live, secondsAgo: 1, lastTask: ""),
            lastOutcome: "failed"
        )
        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertEqual(bubble.text, "Something feels off")
        XCTAssertEqual(bubble.motion, .failed)
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.detail, "Failed")
    }

    /// B2: roster lastOutcomes plumb through CompanionState into bubble.
    func testRosterLastOutcomeReachesBubble() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(status: .idle, presence: .live, secondsAgo: 1, lastTask: "", now: now),
        ], scannedAt: now)
        let roster = CompanionRoster.build(
            from: summary, now: now, lastOutcomes: ["science": "review"]
        )
        XCTAssertEqual(roster.first?.lastOutcome, "review")
        let bubble = CompanionBubbleText.derive(from: roster[0])
        XCTAssertEqual(bubble.text, "Ready for review")
        XCTAssertEqual(bubble.detail, "Task complete")
        XCTAssertFalse(bubble.claimsWork)
    }

    /// Task snippet still outranks outcome evidence when both present.
    func testTaskDetailPrefersOverOutcomeEvidence() {
        let state = CompanionState(
            agent: snap(
                status: .idle, presence: .live, secondsAgo: 1, lastTask: "docking done"
            ),
            lastOutcome: "success"
        )
        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertEqual(bubble.text, "Ready for review")
        XCTAssertEqual(bubble.detail, "docking done")
    }

    func testApprovalBubble() {
        let bubble = CompanionBubbleText.derive(.init(
            presence: .live,
            status: .idle,
            mood: .happy,
            motion: .waving,
            displayName: "Codex"
        ))
        XCTAssertEqual(bubble.text, "Approved!")
        XCTAssertFalse(bubble.claimsWork)
    }

    func testEmptyRosterBubbleDoesNotClaimWork() {
        let bubble = CompanionBubbleText.emptyRoster()
        XCTAssertEqual(bubble.text, CompanionBubbleText.emptyRosterText)
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.motion, .idle)
    }

    /// Signal matrix: motion + bubble stay aligned for core cases.
    func testSignalMatrixMotionAndBubbleAlign() {
        let cases: [(CompanionBubbleText.Signals, String, Bool, PetCodexMotion)] = [
            (
                .init(presence: .live, status: .active, mood: .alert, motion: .running,
                      displayName: "A"),
                "On it", true, .running
            ),
            (
                .init(presence: .live, status: .blocked, mood: .alert, motion: .waiting,
                      displayName: "A", hasPendingAsk: true),
                "Needs you", false, .waiting
            ),
            (
                .init(presence: .live, status: .idle, mood: .wary, motion: .failed,
                      displayName: "A"),
                "Something feels off", false, .failed
            ),
            (
                .init(presence: .offline, status: .idle, mood: .sleepy, motion: .idle,
                      displayName: "A", statusLine: "offline"),
                "Sleeping", false, .idle
            ),
            (
                .init(presence: .observed, status: .active, mood: .idle, motion: .idle,
                      displayName: "A", statusLine: "seen 2s ago"),
                "Resting", false, .idle
            ),
        ]
        for (signals, text, claims, motion) in cases {
            let b = CompanionBubbleText.derive(signals)
            XCTAssertEqual(b.text, text, "signals \(signals)")
            XCTAssertEqual(b.claimsWork, claims, text)
            XCTAssertEqual(b.motion, motion, text)
        }
    }

    // MARK: - T3: roster + activity → bubble / moodLine honesty

    private let idleMoodWords = ["resting", "sleeping", "quiet", "idle"]

    /// T3: activity task_complete → review motion + bubble; mood still idle must
    /// not surface quiet words on moodLine or bubble text.
    func testRosterActivityReviewGoldenBubbleAndMoodLine() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(status: .idle, presence: .live, secondsAgo: 1, lastTask: "", now: now),
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
        XCTAssertEqual(state.mood, .idle, "procedural mood stays idle without busy status")
        XCTAssertEqual(state.lastOutcome, "review")

        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertEqual(bubble.text, "Ready for review")
        XCTAssertEqual(bubble.motion, .review)
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.detail, "Task complete")

        let bubbleBlob = "\(bubble.text) \(bubble.detail ?? "")".lowercased()
        for word in idleMoodWords {
            XCTAssertFalse(
                bubbleBlob.contains(word),
                "review bubble must not claim '\(word)'; got \(bubbleBlob)"
            )
        }

        XCTAssertEqual(state.moodDisplayWord, "ready")
        XCTAssertTrue(state.moodLine.hasSuffix("· ready"), state.moodLine)
        for word in idleMoodWords {
            XCTAssertFalse(
                state.moodLine.lowercased().contains(word),
                "moodLine must not claim '\(word)' when motion is review; \(state.moodLine)"
            )
        }
        XCTAssertTrue(state.accessibilityLine.contains("ready"), state.accessibilityLine)
    }

    /// T3: activity failure → failed motion + bubble; moodLine never resting.
    func testRosterActivityFailedGoldenBubbleAndMoodLine() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(status: .idle, presence: .live, secondsAgo: 1, lastTask: "", now: now),
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
        XCTAssertEqual(state.mood, .idle, "failed outcome alone does not set wary without ΔH")
        XCTAssertEqual(state.lastOutcome, "failed")

        let bubble = CompanionBubbleText.derive(from: state)
        XCTAssertEqual(bubble.text, "Something feels off")
        XCTAssertEqual(bubble.motion, .failed)
        XCTAssertEqual(bubble.mood, .wary, "failed bubble mood is wary, not idle")
        XCTAssertFalse(bubble.claimsWork)
        XCTAssertEqual(bubble.detail, "Failed")

        let bubbleBlob = "\(bubble.text) \(bubble.detail ?? "")".lowercased()
        for word in idleMoodWords {
            XCTAssertFalse(bubbleBlob.contains(word), bubbleBlob)
        }

        XCTAssertEqual(state.moodDisplayWord, "uneasy")
        XCTAssertTrue(state.moodLine.hasSuffix("· uneasy"), state.moodLine)
        for word in idleMoodWords {
            XCTAssertFalse(
                state.moodLine.lowercased().contains(word),
                "moodLine must not claim '\(word)' when motion is failed; \(state.moodLine)"
            )
        }
    }

    /// T3: DesktopCompanionSelector through roster+activity yields same goldens.
    func testSelectorPresentFromActivityReviewAndFailed() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(id: "science", status: .idle, presence: .live, secondsAgo: 1,
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

    /// T3: pure CompanionState(lastOutcome) moodLine honesty matrix.
    func testMoodLineHonestyWhenMotionReviewOrFailedButMoodIdle() {
        let review = CompanionState(
            agent: snap(status: .idle, presence: .live, secondsAgo: 1),
            lastOutcome: "success"
        )
        XCTAssertEqual(review.mood, .idle)
        XCTAssertEqual(review.codexMotion, .review)
        XCTAssertEqual(review.moodDisplayWord, "ready")
        XCTAssertFalse(review.moodLine.contains("resting"))
        XCTAssertFalse(review.moodLine.contains("sleeping"))

        let failed = CompanionState(
            agent: snap(status: .idle, presence: .live, secondsAgo: 1),
            lastOutcome: "failed"
        )
        XCTAssertEqual(failed.mood, .idle)
        XCTAssertEqual(failed.codexMotion, .failed)
        XCTAssertEqual(failed.moodDisplayWord, "uneasy")
        XCTAssertFalse(failed.moodLine.contains("resting"))

        let idle = CompanionState(
            agent: snap(status: .idle, presence: .live, secondsAgo: 1)
        )
        XCTAssertEqual(idle.codexMotion, .idle)
        XCTAssertEqual(idle.moodDisplayWord, "resting")
        XCTAssertTrue(idle.moodLine.hasSuffix("· resting"))
    }
}

// MARK: - Desktop companion selector

final class DesktopCompanionSelectorTests: XCTestCase {

    func testEmptyRosterUsesWatchingBubble() {
        let p = DesktopCompanionSelector.present(roster: [])
        XCTAssertNil(p.state)
        XCTAssertEqual(p.bubble.text, CompanionBubbleText.emptyRosterText)
        XCTAssertFalse(p.bubble.claimsWork)
        XCTAssertEqual(p.packagePetId, PetPackageResolver.defaultPetId)
        XCTAssertNotNil(p.kind)
    }

    func testPrimaryIsWorkingAgent() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(id: "chatgpt", status: .idle, presence: .observed, secondsAgo: 90, now: now),
            snap(id: "science", status: .active, presence: .live, secondsAgo: 1, now: now),
        ], scannedAt: now)
        let p = DesktopCompanionSelector.present(summary: summary, now: now)
        XCTAssertEqual(p.state?.id, "science")
        XCTAssertTrue(p.bubble.claimsWork)
        XCTAssertEqual(p.motion, .running)
    }

    func testPackagePetIdPropagates() {
        let p = DesktopCompanionSelector.present(roster: [], packagePetId: "shannon")
        XCTAssertEqual(p.packagePetId, "shannon")
    }

    // MARK: - E3 cycle / top-N helpers

    func testClampedIndexEmptyAndBounds() {
        XCTAssertEqual(DesktopCompanionSelector.clampedIndex(3, count: 0), 0)
        XCTAssertEqual(DesktopCompanionSelector.clampedIndex(-1, count: 3), 0)
        XCTAssertEqual(DesktopCompanionSelector.clampedIndex(0, count: 3), 0)
        XCTAssertEqual(DesktopCompanionSelector.clampedIndex(2, count: 3), 2)
        XCTAssertEqual(DesktopCompanionSelector.clampedIndex(99, count: 3), 2)
    }

    func testNextIndexWraps() {
        XCTAssertEqual(DesktopCompanionSelector.nextIndex(after: 0, count: 0), 0)
        XCTAssertEqual(DesktopCompanionSelector.nextIndex(after: 0, count: 1), 0)
        XCTAssertEqual(DesktopCompanionSelector.nextIndex(after: 0, count: 3), 1)
        XCTAssertEqual(DesktopCompanionSelector.nextIndex(after: 1, count: 3), 2)
        XCTAssertEqual(DesktopCompanionSelector.nextIndex(after: 2, count: 3), 0)
        XCTAssertEqual(DesktopCompanionSelector.nextIndex(after: 99, count: 3), 0)
        XCTAssertEqual(DesktopCompanionSelector.nextIndex(after: -1, count: 3), 1)
    }

    func testTopAgentsLimit() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(id: "a", status: .active, presence: .live, secondsAgo: 1, now: now),
            snap(id: "b", status: .active, presence: .live, secondsAgo: 2, now: now),
            snap(id: "c", status: .idle, presence: .observed, secondsAgo: 10, now: now),
            snap(id: "d", status: .idle, presence: .observed, secondsAgo: 20, now: now),
        ], scannedAt: now)
        let roster = CompanionRoster.build(from: summary, now: now)
        XCTAssertEqual(DesktopCompanionSelector.topAgents(roster, limit: 0), [])
        XCTAssertEqual(DesktopCompanionSelector.topAgents(roster, limit: 2).map(\.id).count, 2)
        XCTAssertEqual(
            DesktopCompanionSelector.topAgents(roster, limit: 10).count,
            roster.count
        )
        XCTAssertEqual(
            DesktopCompanionSelector.topAgents(roster).count,
            min(roster.count, DesktopCompanionSelector.defaultTopN)
        )
    }

    func testResolveSelectedIndexPrefersId() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(id: "chatgpt", status: .idle, presence: .observed, secondsAgo: 90, now: now),
            snap(id: "science", status: .active, presence: .live, secondsAgo: 1, now: now),
            snap(id: "grok", status: .active, presence: .live, secondsAgo: 2, now: now),
        ], scannedAt: now)
        let roster = CompanionRoster.build(from: summary, now: now)
        let cycle = DesktopCompanionSelector.topAgents(roster)
        let idx = DesktopCompanionSelector.resolveSelectedIndex(
            roster: cycle,
            preferredId: "grok",
            fallbackIndex: 0
        )
        XCTAssertEqual(cycle[idx].id, "grok")
        let fallback = DesktopCompanionSelector.resolveSelectedIndex(
            roster: cycle,
            preferredId: "missing",
            fallbackIndex: 1
        )
        XCTAssertEqual(fallback, DesktopCompanionSelector.clampedIndex(1, count: cycle.count))
    }

    func testPresentSelectedIndexCyclesSecondaryAgent() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(id: "chatgpt", status: .idle, presence: .observed, secondsAgo: 90, now: now),
            snap(id: "science", status: .active, presence: .live, secondsAgo: 1, now: now),
            snap(id: "grok", status: .active, presence: .live, secondsAgo: 2, now: now),
        ], scannedAt: now)
        let p0 = DesktopCompanionSelector.present(summary: summary, now: now, selectedIndex: 0)
        let p1 = DesktopCompanionSelector.present(summary: summary, now: now, selectedIndex: 1)
        XCTAssertEqual(p0.state?.id, "science")
        XCTAssertNotEqual(p0.state?.id, p1.state?.id)
        let roster = DesktopCompanionSelector.topAgents(
            CompanionRoster.build(from: summary, now: now)
        )
        var idx = 0
        var seen: [String] = []
        for _ in 0..<roster.count {
            seen.append(roster[idx].id)
            idx = DesktopCompanionSelector.nextIndex(after: idx, count: roster.count)
        }
        XCTAssertEqual(seen.count, roster.count)
        XCTAssertEqual(Set(seen).count, roster.count)
        XCTAssertEqual(idx, 0)
    }

    func testPresentPreferredIdStickyAcrossRefresh() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snap(id: "science", status: .active, presence: .live, secondsAgo: 1, now: now),
            snap(id: "grok", status: .active, presence: .live, secondsAgo: 2, now: now),
        ], scannedAt: now)
        let p = DesktopCompanionSelector.present(
            summary: summary,
            now: now,
            selectedIndex: 0,
            preferredId: "grok"
        )
        XCTAssertEqual(p.state?.id, "grok")
    }
}

// MARK: - Refresh cadence (pure, O1)

final class DesktopCompanionRefreshCadenceTests: XCTestCase {

    func testQuietPollIsThirtySecondsNotTwo() {
        XCTAssertEqual(DesktopCompanionRefreshCadence.quietPollInterval, 30, accuracy: 1e-9)
        XCTAssertEqual(DesktopCompanionRefreshCadence.nearSleepyPollInterval, 2, accuracy: 1e-9)
        XCTAssertGreaterThan(
            DesktopCompanionRefreshCadence.quietPollInterval,
            DesktopCompanionRefreshCadence.nearSleepyPollInterval
        )
        XCTAssertGreaterThanOrEqual(
            DesktopCompanionRefreshCadence.nearSleepyWindow,
            DesktopCompanionRefreshCadence.quietPollInterval
        )
        XCTAssertEqual(
            DesktopCompanionRefreshCadence.sleepyAfter,
            CompanionMood.sleepyAfter,
            accuracy: 1e-9
        )
    }

    func testEmptyAgesUseQuietPoll() {
        XCTAssertEqual(
            DesktopCompanionRefreshCadence.pollInterval(secondsSinceSeen: []),
            DesktopCompanionRefreshCadence.quietPollInterval,
            accuracy: 1e-9
        )
    }

    func testFreshAgentUsesQuietPoll() {
        let ages: [TimeInterval] = [5, 12, 60]
        XCTAssertEqual(
            DesktopCompanionRefreshCadence.pollInterval(secondsSinceSeen: ages),
            DesktopCompanionRefreshCadence.quietPollInterval,
            accuracy: 1e-9
        )
    }

    func testAlreadyPastSleepyUsesQuietPoll() {
        let past = CompanionMood.sleepyAfter + 10
        XCTAssertFalse(
            DesktopCompanionRefreshCadence.isNearSleepyThreshold(secondsSinceSeen: past)
        )
        XCTAssertEqual(
            DesktopCompanionRefreshCadence.pollInterval(secondsSinceSeen: [past]),
            DesktopCompanionRefreshCadence.quietPollInterval,
            accuracy: 1e-9
        )
    }

    func testNearSleepyThresholdUsesTwoSecondPoll() {
        let window = DesktopCompanionRefreshCadence.nearSleepyWindow
        let nearAge = CompanionMood.sleepyAfter - (window / 2)
        XCTAssertTrue(
            DesktopCompanionRefreshCadence.isNearSleepyThreshold(secondsSinceSeen: nearAge)
        )
        XCTAssertEqual(
            DesktopCompanionRefreshCadence.pollInterval(secondsSinceSeen: [nearAge]),
            DesktopCompanionRefreshCadence.nearSleepyPollInterval,
            accuracy: 1e-9
        )
    }

    func testAnyNearAgeTightensInterval() {
        let near = CompanionMood.sleepyAfter - 5
        let ages: [TimeInterval] = [3, near, 40]
        XCTAssertEqual(
            DesktopCompanionRefreshCadence.pollInterval(secondsSinceSeen: ages),
            DesktopCompanionRefreshCadence.nearSleepyPollInterval,
            accuracy: 1e-9
        )
    }

    func testBoundaryJustInsideWindowIsNear() {
        let age = CompanionMood.sleepyAfter - DesktopCompanionRefreshCadence.nearSleepyWindow
        XCTAssertTrue(
            DesktopCompanionRefreshCadence.isNearSleepyThreshold(secondsSinceSeen: age)
        )
        XCTAssertEqual(
            DesktopCompanionRefreshCadence.pollInterval(secondsSinceSeen: [age]),
            DesktopCompanionRefreshCadence.nearSleepyPollInterval,
            accuracy: 1e-9
        )
    }

    func testBoundaryJustOutsideWindowIsQuiet() {
        let age = CompanionMood.sleepyAfter
            - DesktopCompanionRefreshCadence.nearSleepyWindow
            - 0.5
        XCTAssertFalse(
            DesktopCompanionRefreshCadence.isNearSleepyThreshold(secondsSinceSeen: age)
        )
        XCTAssertEqual(
            DesktopCompanionRefreshCadence.pollInterval(secondsSinceSeen: [age]),
            DesktopCompanionRefreshCadence.quietPollInterval,
            accuracy: 1e-9
        )
    }

    func testSecondsUntilSleepy() {
        XCTAssertEqual(
            DesktopCompanionRefreshCadence.secondsUntilSleepy(secondsSinceSeen: 0),
            CompanionMood.sleepyAfter,
            accuracy: 1e-9
        )
        XCTAssertNil(
            DesktopCompanionRefreshCadence.secondsUntilSleepy(
                secondsSinceSeen: CompanionMood.sleepyAfter + 1
            )
        )
    }

    func testAgentsOfflineSkippedForNearness() {
        let now = Date()
        let offline = snap(
            status: .idle,
            presence: .offline,
            secondsAgo: CompanionMood.sleepyAfter - 5,
            now: now
        )
        let interval = DesktopCompanionRefreshCadence.pollInterval(
            agents: [offline],
            now: now
        )
        XCTAssertEqual(
            interval,
            DesktopCompanionRefreshCadence.quietPollInterval,
            accuracy: 1e-9
        )
    }

    func testAgentsNearSleepyFromSnapshots() {
        let now = Date()
        let near = snap(
            status: .idle,
            presence: .observed,
            secondsAgo: CompanionMood.sleepyAfter - 10,
            now: now
        )
        let interval = DesktopCompanionRefreshCadence.pollInterval(
            agents: [near],
            now: now
        )
        XCTAssertEqual(
            interval,
            DesktopCompanionRefreshCadence.nearSleepyPollInterval,
            accuracy: 1e-9
        )
    }

    func testPolicySnapshotKeys() {
        let snap = DesktopCompanionRefreshCadence.policySnapshot
        for key in [
            "quietPollInterval",
            "nearSleepyPollInterval",
            "nearSleepyWindow",
            "sleepyAfter",
        ] {
            XCTAssertNotNil(snap[key], "missing \(key)")
        }
        XCTAssertEqual(snap["quietPollInterval"], "30.0")
        XCTAssertEqual(snap["nearSleepyPollInterval"], "2.0")
    }
}

// MARK: - Window policy (pure)

final class DesktopCompanionWindowPolicyTests: XCTestCase {

    func testLevelIsStatusWindowClassOrAbove() {
        let level = DesktopCompanionWindowPolicy.windowLevelRawValue
        XCTAssertTrue(
            DesktopCompanionWindowPolicy.isAlwaysOnTopLevel(level),
            "level \(level) must be >= status-window class"
        )
        XCTAssertEqual(DesktopCompanionWindowPolicy.levelOffsetAboveStatusWindow, 2)
    }

    func testNonActivatingAndVisibleOnDeactivate() {
        XCTAssertFalse(DesktopCompanionWindowPolicy.canBecomeKey)
        XCTAssertFalse(DesktopCompanionWindowPolicy.canBecomeMain)
        XCTAssertTrue(DesktopCompanionWindowPolicy.usesNonactivatingPanelStyle)
        XCTAssertFalse(DesktopCompanionWindowPolicy.hidesOnDeactivate)
    }

    func testJoinsAllSpacesAndReassertPath() {
        XCTAssertTrue(DesktopCompanionWindowPolicy.joinsAllSpaces)
        XCTAssertTrue(DesktopCompanionWindowPolicy.stationary)
        XCTAssertTrue(DesktopCompanionWindowPolicy.fullScreenAuxiliary)
        XCTAssertTrue(DesktopCompanionWindowPolicy.ignoresCycle)
        XCTAssertTrue(DesktopCompanionWindowPolicy.reassertOnActiveSpaceChange)
        XCTAssertTrue(DesktopCompanionWindowPolicy.reassertOnScreenParametersChange)
        XCTAssertGreaterThan(DesktopCompanionWindowPolicy.launchReassertTickCount, 0)
    }

    func testMatchesAlwaysOnTopHelper() {
        let ok = DesktopCompanionWindowPolicy.matchesAlwaysOnTop(
            levelRawValue: DesktopCompanionWindowPolicy.windowLevelRawValue,
            hidesOnDeactivate: false,
            canBecomeKey: false,
            joinsAllSpaces: true
        )
        XCTAssertTrue(ok)

        let bad = DesktopCompanionWindowPolicy.matchesAlwaysOnTop(
            levelRawValue: 0, // normal window
            hidesOnDeactivate: false,
            canBecomeKey: false,
            joinsAllSpaces: true
        )
        XCTAssertFalse(bad)
    }

    func testPolicySnapshotHasRequiredKeys() {
        let snap = DesktopCompanionWindowPolicy.policySnapshot
        for key in [
            "windowLevelRawValue",
            "hidesOnDeactivate",
            "canBecomeKey",
            "joinsAllSpaces",
            "reassertOnActiveSpaceChange",
            "isAlwaysOnTopLevel",
        ] {
            XCTAssertNotNil(snap[key], "missing \(key)")
        }
        XCTAssertEqual(snap["hidesOnDeactivate"], "false")
        XCTAssertEqual(snap["canBecomeKey"], "false")
        XCTAssertEqual(snap["joinsAllSpaces"], "true")
        XCTAssertEqual(snap["isAlwaysOnTopLevel"], "true")
    }

    #if canImport(AppKit)
    func testCollectionBehaviorIncludesJoinAllSpaces() {
        let b = DesktopCompanionWindowPolicy.collectionBehavior
        XCTAssertTrue(b.contains(.canJoinAllSpaces))
        XCTAssertTrue(b.contains(.fullScreenAuxiliary))
        XCTAssertTrue(b.contains(.stationary))
        XCTAssertTrue(b.contains(.ignoresCycle))
    }

    func testStyleMaskIsNonactivatingPanel() {
        let mask = DesktopCompanionWindowPolicy.styleMask
        XCTAssertTrue(mask.contains(.borderless))
        XCTAssertTrue(mask.contains(.nonactivatingPanel))
    }
    #endif
}

// MARK: - Codex package resolve smoke (real home roots optional)

final class DesktopCompanionPackageResolveTests: XCTestCase {

    func testDefaultPetIdIsShannon() {
        XCTAssertEqual(PetPackageResolver.defaultPetId, "shannon")
    }

    func testResolveNeverReturnsBlankCapableFailure() {
        // Always succeeds: procedural or package.
        let pkg = PetPackageResolver.resolve(petId: "totally-missing-xyz")
        if pkg.useProcedural {
            XCTAssertNil(pkg.spritesheetURL)
            XCTAssertFalse(pkg.notes.isEmpty)
        } else {
            XCTAssertNotNil(pkg.spritesheetURL)
        }
    }

    /// When ~/.codex/pets/shannon exists, resolve should prefer the package.
    func testRealCodexShannonPackageIfPresent() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shannon = home.appendingPathComponent(".codex/pets/shannon")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: shannon.path, isDirectory: &isDir)
            && isDir.boolValue
        let pkg = PetPackageResolver.resolve(petId: "shannon", requireV2: true)
        if exists {
            // pet.json + spritesheet should resolve.
            let meta = shannon.appendingPathComponent("pet.json")
            if FileManager.default.fileExists(atPath: meta.path) {
                XCTAssertFalse(pkg.useProcedural, "live shannon package should resolve")
                XCTAssertTrue(pkg.isV2)
                XCTAssertNotNil(pkg.spritesheetURL)
            }
        } else {
            XCTAssertTrue(pkg.useProcedural)
        }
    }

    /// B1: sheet + pet.json without `spriteVersionNumber` infers v2 so
    /// CompanionDrawMode / desktop atlas (`requireV2: true`) can draw.
    func testMissingSpriteVersionNumberInferredAsV2ForAtlas() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-nov-\(UUID().uuidString)")
        let pkgDir = root.appendingPathComponent("no-version-pet")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta: [String: Any] = [
            "id": "no-version-pet",
            "displayName": "No Version",
            "spritesheetPath": "spritesheet.webp",
            // deliberately omit spriteVersionNumber
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: pkgDir.appendingPathComponent("pet.json"))
        try Data("RIFF....WEBP".utf8)
            .write(to: pkgDir.appendingPathComponent("spritesheet.webp"))

        let loose = PetPackageResolver.resolve(
            petId: "no-version-pet", roots: [root], requireV2: false
        )
        XCTAssertFalse(loose.useProcedural, "sheet+json must resolve without requireV2")
        XCTAssertTrue(loose.isV2, "missing version + sheet infers v2")
        XCTAssertEqual(loose.spriteVersion, 2)

        let strict = PetPackageResolver.resolve(
            petId: "no-version-pet", roots: [root], requireV2: true
        )
        XCTAssertFalse(
            strict.useProcedural,
            "requireV2 must accept inferred v2 when sheet is present"
        )
        XCTAssertEqual(strict.spriteVersion, 2)
    }

    /// Desktop / board atlas path always requires v2 — same as CompanionDrawMode.
    func testCompanionDrawModeRequiresV2Package() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-draw-\(UUID().uuidString)")
        let pkgDir = root.appendingPathComponent("v1-only")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta: [String: Any] = [
            "id": "v1-only",
            "displayName": "V1",
            "spriteVersionNumber": 1,
            "spritesheetPath": "spritesheet.webp",
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: pkgDir.appendingPathComponent("pet.json"))
        try Data("RIFF....WEBP".utf8)
            .write(to: pkgDir.appendingPathComponent("spritesheet.webp"))

        let mode = CompanionDrawMode.resolve(
            petId: "v1-only", motion: .idle, roots: [root]
        )
        XCTAssertEqual(mode, .procedural, "draw path must not use non-v2 packages")
    }
}
