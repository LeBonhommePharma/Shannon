import XCTest
@testable import ShannonCore

/// Covers the derived values the three apps render, and the edge-triggering
/// that decides when a device buzzes.
final class PresentationTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Derived display values

    func testDockingFractionHandlesZeroTotal() {
        let empty = DockingProgress(id: "b", benchmarkName: "B",
                                    targetsComplete: 0, targetsTotal: 0)
        XCTAssertEqual(empty.fraction, 0)
        XCTAssertFalse(empty.isComplete)
    }

    func testDockingFractionClampsOvershoot() {
        let over = DockingProgress(id: "b", benchmarkName: "B",
                                   targetsComplete: 90, targetsTotal: 85)
        XCTAssertEqual(over.fraction, 1.0)
        XCTAssertTrue(over.isComplete)
    }

    func testETALabelFormatting() {
        func eta(_ seconds: Double?) -> String? {
            DockingProgress(id: "b", benchmarkName: "B", targetsComplete: 0,
                            targetsTotal: 85, etaSeconds: seconds).etaLabel
        }
        XCTAssertEqual(eta(4380), "1h 13m")
        XCTAssertEqual(eta(240), "4m")
        XCTAssertEqual(eta(45), "45s")
        XCTAssertNil(eta(nil))
        XCTAssertNil(eta(0))
    }

    func testEntropyLabelShowsDeltaOnlyOnCollapse() {
        let base = AgentState(id: "a", name: "A", activity: .running, entropyBits: 8.42)
        XCTAssertEqual(base.entropyLabel, "H 8.4")

        var collapsing = base
        collapsing.entropyDelta = -3.4
        XCTAssertEqual(collapsing.entropyLabel, "H 8.4 ▽3.4")

        var rising = base
        rising.entropyDelta = 1.2
        XCTAssertEqual(rising.entropyLabel, "H 8.4", "positive delta is not an alarm")
    }

    func testCompactLinesTruncateToWatchWidth() {
        let agent = AgentState(id: "a", name: String(repeating: "x", count: 80),
                               activity: .running, turnCount: 3)
        XCTAssertEqual(agent.compactLine(maxLength: 20).count, 20)
        XCTAssertTrue(agent.compactLine(maxLength: 20).hasSuffix("…"))
    }

    func testNowPlayingCompactLineIsNilWhenIdle() {
        XCTAssertNil(NowPlayingSnapshot(title: "", artist: "").compactLine())
        XCTAssertEqual(
            NowPlayingSnapshot(title: "Blue in Green", artist: "Miles Davis",
                               isPlaying: true).compactLine(),
            "▶ Blue in Green — Miles Davis"
        )
    }

    /// UX-029: pad/watch empty media chrome share idleTitle / displayTitle.
    func testNowPlayingDisplayTitleIdleAndTrack() {
        XCTAssertEqual(NowPlayingSnapshot.idleTitle, "Nothing playing")
        XCTAssertEqual(
            NowPlayingSnapshot(title: "", artist: "").displayTitle,
            NowPlayingSnapshot.idleTitle
        )
        XCTAssertEqual(
            NowPlayingSnapshot(title: "   ", artist: "x").displayTitle,
            NowPlayingSnapshot.idleTitle
        )
        XCTAssertEqual(
            NowPlayingSnapshot(title: "Blue in Green", artist: "Miles").displayTitle,
            "Blue in Green"
        )
    }

    func testPadAndWatchWireNowPlayingIdleTitle() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let pad = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/NowPlayingCardView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            pad.contains("displayTitle") || pad.contains("NowPlayingSnapshot.idleTitle"),
            "pad NowPlayingCardView must use displayTitle / idleTitle"
        )
        XCTAssertFalse(
            pad.contains("\"Nothing playing\""),
            "pad must not hard-code dual Nothing playing string"
        )

        let watch = (try? String(
            contentsOf: root.appendingPathComponent(
                "watchOS/Sources/ShannonWatch/WatchRootView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            watch.contains("NowPlayingSnapshot.idleTitle"),
            "watch Now Playing empty must use NowPlayingSnapshot.idleTitle"
        )
        XCTAssertFalse(
            watch.contains("Text(\"Nothing playing\")"),
            "watch must not hard-code dual Nothing playing Text"
        )
    }

    func testTimerRemainingNeverGoesNegative() {
        let expired = TimerState(label: "Tea", fireAt: fixedDate.addingTimeInterval(-90))
        XCTAssertEqual(expired.remaining(now: fixedDate), 0)
        XCTAssertTrue(expired.hasFired(now: fixedDate))
        XCTAssertEqual(expired.remainingLabel(now: fixedDate), "0:00")
    }

    func testPausedTimerReportsFrozenRemainder() {
        let paused = TimerState(label: "Tea", fireAt: fixedDate.addingTimeInterval(-90),
                                isPaused: true, pausedRemaining: 125)
        XCTAssertEqual(paused.remaining(now: fixedDate), 125)
        XCTAssertFalse(paused.hasFired(now: fixedDate), "a paused timer never fires")
        XCTAssertEqual(paused.remainingLabel(now: fixedDate), "2:05")
    }

    func testNotificationBodyIsTruncatedAtConstruction() {
        let note = NotificationMirror(sender: "Mail", title: "T",
                                      body: String(repeating: "y", count: 400))
        XCTAssertEqual(note.body.count, NotificationMirror.maxBodyLength)
        XCTAssertTrue(note.body.hasSuffix("…"))
    }

    func testDeviceStaleness() {
        let device = MacDeviceState(deviceName: "Mac", batteryPercent: 50, isCharging: false,
                                    updatedAt: fixedDate)
        XCTAssertFalse(device.isStale(now: fixedDate.addingTimeInterval(60)))
        XCTAssertTrue(device.isStale(now: fixedDate.addingTimeInterval(3600)))
    }

    // MARK: Ranking and complication selection

    func testRankingPutsProblemsFirst() {
        let agents = [
            AgentState(id: "idle", name: "Idle", activity: .idle),
            AgentState(id: "run", name: "Run", activity: .running),
            AgentState(id: "err", name: "Err", activity: .errored),
            AgentState(id: "block", name: "Block", activity: .blocked),
        ]
        // UX-004 Mac parity: needs-you (blocked) before errored, then working → idle.
        XCTAssertEqual(agents.rankedForDisplay().map(\.id), ["block", "err", "run", "idle"])
        XCTAssertEqual(agents.runningCount, 1)
    }

    /// Pending confirmation elevates an otherwise-running agent to needs-you (Mac roster).
    func testRankingElevatesPendingConfirmationAgent() {
        let agents = [
            AgentState(id: "run", name: "Run", activity: .running, updatedAt: fixedDate),
            AgentState(id: "ask", name: "Ask", activity: .running, updatedAt: fixedDate),
            AgentState(id: "idle", name: "Idle", activity: .idle, updatedAt: fixedDate),
        ]
        XCTAssertEqual(
            agents.rankedForDisplay(pendingAgentIDs: ["ask"]).map(\.id),
            ["ask", "run", "idle"]
        )
        // Without pending ids, both running tie-break by id.
        XCTAssertEqual(
            agents.rankedForDisplay().map(\.id),
            ["ask", "run", "idle"]
        )
    }

    func testSnapshotAgentsRankedForDisplayUsesConfirmations() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(id: "a", name: "A", activity: .idle, updatedAt: fixedDate),
                AgentState(id: "b", name: "B", activity: .running, updatedAt: fixedDate),
            ],
            confirmations: [
                PendingConfirmation(
                    id: "c1",
                    question: "Approve?",
                    agentID: "a",
                    createdAt: fixedDate,
                    expiresAt: fixedDate.addingTimeInterval(600)
                ),
            ]
        )
        XCTAssertEqual(
            snap.agentsRankedForDisplay(now: fixedDate).map(\.id),
            ["a", "b"],
            "idle agent with open ask must rank above running"
        )
    }

    func testAttentionRankPriorityTokens() {
        XCTAssertEqual(
            AgentAttentionRank.priority(activity: .blocked),
            0
        )
        XCTAssertEqual(
            AgentAttentionRank.priority(activity: .idle, hasPendingConfirmation: true),
            0
        )
        XCTAssertEqual(AgentAttentionRank.priority(activity: .running), 2)
        XCTAssertEqual(AgentAttentionRank.priority(activity: .finished), 3)
        XCTAssertEqual(AgentAttentionRank.priority(activity: .idle), 4)
    }

    /// Same activity: newer `updatedAt` wins so the agent that just moved
    /// surfaces on the watch first.
    func testRankingBreaksTiesByRecency() {
        let older = AgentState(id: "old", name: "Old", activity: .running,
                               updatedAt: fixedDate)
        let newer = AgentState(id: "new", name: "New", activity: .running,
                               updatedAt: fixedDate.addingTimeInterval(30))
        XCTAssertEqual([older, newer].rankedForDisplay().map(\.id), ["new", "old"])
        XCTAssertEqual([newer, older].rankedForDisplay().map(\.id), ["new", "old"])
    }

    /// Fully tied agents (same activity + same timestamp) must sort by id so
    /// phone, watch and complication agree which three cards to show.
    func testRankingIsStableOnFullTie() {
        let agents = [
            AgentState(id: "zulu", name: "Z", activity: .running, updatedAt: fixedDate),
            AgentState(id: "alpha", name: "A", activity: .running, updatedAt: fixedDate),
            AgentState(id: "mike", name: "M", activity: .running, updatedAt: fixedDate),
        ]
        let expected = ["alpha", "mike", "zulu"]
        XCTAssertEqual(agents.rankedForDisplay().map(\.id), expected)
        XCTAssertEqual(agents.reversed().rankedForDisplay().map(\.id), expected)
        // Multi-pass: ranking is idempotent.
        XCTAssertEqual(
            agents.rankedForDisplay().rankedForDisplay().map(\.id),
            expected
        )
    }

    /// Mixed multi-agent board: activity rank first, then recency, then id.
    func testMultiAgentRankStabilityAcrossDevices() {
        let board = [
            AgentState(id: "idle-b", name: "IdleB", activity: .idle,
                       updatedAt: fixedDate.addingTimeInterval(100)),
            AgentState(id: "run-old", name: "RunOld", activity: .running,
                       updatedAt: fixedDate),
            AgentState(id: "err-a", name: "ErrA", activity: .errored,
                       updatedAt: fixedDate),
            AgentState(id: "run-new", name: "RunNew", activity: .running,
                       updatedAt: fixedDate.addingTimeInterval(50)),
            AgentState(id: "err-b", name: "ErrB", activity: .errored,
                       updatedAt: fixedDate),
            AgentState(id: "block", name: "Block", activity: .blocked,
                       updatedAt: fixedDate),
            AgentState(id: "done", name: "Done", activity: .finished,
                       updatedAt: fixedDate),
        ]
        let ranked = board.rankedForDisplay().map(\.id)
        XCTAssertEqual(ranked, [
            "block",            // needs-you first (Mac parity UX-004)
            "err-a", "err-b",   // errored, id order on equal time
            "run-new", "run-old", // running by recency
            "done",             // finished
            "idle-b",           // idle
        ])
        // Shuffling input must not change the ranked order.
        XCTAssertEqual(board.shuffled().rankedForDisplay().map(\.id), ranked)
    }

    func testComplicationPrefersRunningBenchmark() {
        let snapshot = ShannonSnapshot(
            agents: [AgentState(id: "a", name: "A", activity: .running, entropyBits: 0.61)],
            docking: [DockingProgress(id: "b", benchmarkName: "Astex", targetsComplete: 34,
                                      targetsTotal: 85, bestRMSD: 1.42)],
            nowPlaying: NowPlayingSnapshot(title: "Track", isPlaying: true)
        )
        XCTAssertEqual(snapshot.complicationLine(), "34/85 ✓ 1.42Å H=0.61")
    }

    func testComplicationFallsBackThroughAgentsThenMedia() {
        let media = ShannonSnapshot(
            nowPlaying: NowPlayingSnapshot(title: "Track", artist: "Artist", isPlaying: true)
        )
        XCTAssertEqual(media.complicationLine(), "▶ Track — Artist")
        XCTAssertEqual(ShannonSnapshot().complicationLine(), "Shannon")
    }

    func testWatchShowsAtMostThreeCards() {
        let snapshot = ShannonSnapshot(
            agents: (0..<6).map { AgentState(id: "a\($0)", name: "A\($0)", activity: .running) },
            docking: [DockingProgress(id: "b", benchmarkName: "B", targetsComplete: 1,
                                      targetsTotal: 85)],
            nowPlaying: NowPlayingSnapshot(title: "Track", isPlaying: true)
        )
        XCTAssertEqual(snapshot.watchCards().count, 3)
    }

    // MARK: Alert edge-triggering

    func testDockingAlertsFireOnceOnCompletion() {
        var tracker = DockingAlertTracker()
        func progress(_ done: Int) -> DockingProgress {
            DockingProgress(id: "b", benchmarkName: "Astex", targetsComplete: done,
                            targetsTotal: 3)
        }

        XCTAssertNil(tracker.consume(progress(0)), "first sighting establishes a baseline")
        XCTAssertEqual(tracker.consume(progress(1)),
                       .targetCompleted(benchmark: "Astex", completed: 1, total: 3))
        XCTAssertNil(tracker.consume(progress(1)), "no change, no alert")
        XCTAssertEqual(tracker.consume(progress(3)), .benchmarkFinished(benchmark: "Astex"))
        XCTAssertNil(tracker.consume(progress(3)), "finish alerts exactly once")
    }

    func testAssemblerStaysSilentOnFirstSnapshot() {
        var assembler = SnapshotAssembler()
        let snapshot = ShannonSnapshot(
            agents: [AgentState(id: "a", name: "A", activity: .errored)],
            docking: [DockingProgress(id: "b", benchmarkName: "B", targetsComplete: 85,
                                      targetsTotal: 85)],
            notifications: [NotificationMirror(id: "n1", sender: "S", title: "T", body: "B")]
        )
        XCTAssertTrue(assembler.consume(snapshot).isEmpty,
                      "launching mid-run must not replay history as haptics")
    }

    func testAssemblerReportsTransitionsAfterPriming() {
        var assembler = SnapshotAssembler()
        let running = AgentState(id: "a", name: "Docking", activity: .running)
        _ = assembler.consume(ShannonSnapshot(agents: [running]))

        var failed = running
        failed.activity = .errored
        let alerts = assembler.consume(ShannonSnapshot(agents: [failed]))
        XCTAssertEqual(alerts, [.agentErrored(name: "Docking")])

        XCTAssertTrue(assembler.consume(ShannonSnapshot(agents: [failed])).isEmpty,
                      "a persistent error must not buzz on every refresh")
    }

    func testAssemblerReportsEachNotificationOnce() {
        var assembler = SnapshotAssembler()
        _ = assembler.consume(ShannonSnapshot())

        let note = NotificationMirror(id: "n1", sender: "Messages", title: "Anne", body: "Hi")
        XCTAssertEqual(assembler.consume(ShannonSnapshot(notifications: [note])),
                       [.notification(note)])
        XCTAssertTrue(assembler.consume(ShannonSnapshot(notifications: [note])).isEmpty)
    }

    func testStaleCommandDetection() {
        let command = RemoteCommand(command: .nextTrack, origin: "watch", issuedAt: fixedDate)
        XCTAssertFalse(command.isStale(now: fixedDate.addingTimeInterval(10)))
        XCTAssertTrue(command.isStale(now: fixedDate.addingTimeInterval(120)))
        // Contract is age > 60s (MULTI_DEVICE.md); exact 60s is still fresh.
        XCTAssertFalse(command.isStale(now: fixedDate.addingTimeInterval(RemoteCommand.staleAfter)))
        XCTAssertTrue(command.isStale(now: fixedDate.addingTimeInterval(RemoteCommand.staleAfter + 0.001)))
    }
}
