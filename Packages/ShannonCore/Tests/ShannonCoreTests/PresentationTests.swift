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
        XCTAssertEqual(agents.rankedForDisplay().map(\.id), ["err", "block", "run", "idle"])
        XCTAssertEqual(agents.runningCount, 1)
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
    }
}
