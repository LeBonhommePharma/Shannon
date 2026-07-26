import XCTest
@testable import ShannonCore

final class SyncBehaviourTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Publisher

    func testPublisherSkipsUnchangedState() async throws {
        let backend = InMemorySyncBackend()
        let publisher = ShannonPublisher(backend: backend)
        let agent = AgentState(id: "a1", name: "Shannon gate", activity: .running,
                               turnCount: 3, updatedAt: fixedDate)

        let first = try await publisher.publish(agent)
        let second = try await publisher.publish(agent)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "identical state should not rewrite")
        XCTAssertEqual(backend.writeLog.count, 1)
    }

    /// A newer `updatedAt` alone is not a change — otherwise a 1 s poll loop
    /// would write to CloudKit every second forever.
    func testPublisherIgnoresTimestampOnlyChanges() async throws {
        let backend = InMemorySyncBackend()
        let publisher = ShannonPublisher(backend: backend)
        var agent = AgentState(id: "a1", name: "Shannon gate", activity: .running,
                               updatedAt: fixedDate)

        let initial = try await publisher.publish(agent)
        XCTAssertTrue(initial)

        agent.updatedAt = fixedDate.addingTimeInterval(60)
        let timestampOnly = try await publisher.publish(agent)
        XCTAssertFalse(timestampOnly)

        agent.turnCount += 1
        let realChange = try await publisher.publish(agent)
        XCTAssertTrue(realChange, "real change must publish")
    }

    func testPublisherOverwritesInPlaceRatherThanAccumulating() async throws {
        let backend = InMemorySyncBackend()
        let publisher = ShannonPublisher(backend: backend)
        for turn in 1...5 {
            try await publisher.publish(
                AgentState(id: "a1", name: "Agent", activity: .running, turnCount: turn)
            )
        }
        XCTAssertEqual(backend.recordCount(AgentState.recordType), 1)
    }

    func testRetractRemovesRecord() async throws {
        let backend = InMemorySyncBackend()
        let publisher = ShannonPublisher(backend: backend)
        let agent = AgentState(id: "a1", name: "Agent", activity: .finished)

        try await publisher.publish(agent)
        try await publisher.retract(agent)
        XCTAssertEqual(backend.recordCount(AgentState.recordType), 0)

        // Republishing after a retract must write again, not dedupe against
        // the pre-retract cache.
        let republished = try await publisher.publish(agent)
        XCTAssertTrue(republished)
    }

    func testStaleCommandsAreDroppedButStillDeleted() async throws {
        let backend = InMemorySyncBackend()
        let publisher = ShannonPublisher(backend: backend)
        let now = fixedDate

        try await backend.save(RemoteCommand(id: "fresh", command: .nextTrack,
                                             origin: "phone", issuedAt: now))
        try await backend.save(RemoteCommand(id: "old", command: .togglePlayPause,
                                             origin: "watch",
                                             issuedAt: now.addingTimeInterval(-600)))

        let executed = try await publisher.consumeCommands(now: now)
        XCTAssertEqual(executed.map(\.id), ["fresh"])
        XCTAssertEqual(backend.recordCount(RemoteCommand.recordType), 0,
                       "both commands must be cleared from the queue")
    }

    func testOversizedArtworkIsDroppedBeforePublish() async throws {
        let backend = InMemorySyncBackend()
        let publisher = ShannonPublisher(backend: backend)
        let huge = Data(repeating: 0xAB, count: NowPlayingSnapshot.maxArtworkBytes + 1)
        try await publisher.publish(
            nowPlaying: NowPlayingSnapshot(title: "T", artworkJPEG: huge)
        )

        let stored = try await backend.fetch(NowPlayingSnapshot.self)
        XCTAssertNil(stored.first?.artworkJPEG)
        XCTAssertEqual(stored.first?.title, "T")
    }

    // MARK: Fetch resilience

    /// One record written by an older build of the Mac app must not blank the
    /// whole list on the phone.
    func testUndecodableRecordIsSkippedNotFatal() async throws {
        let backend = InMemorySyncBackend()
        try await backend.save(AgentState(id: "good", name: "Good", activity: .running))
        try await backend.save(recordType: AgentState.recordType,
                               recordName: "agent-broken",
                               fields: ["agentID": .string("broken")])

        let agents = try await backend.fetch(AgentState.self)
        XCTAssertEqual(agents.map(\.id), ["good"])
    }

    // MARK: Watch relay

    func testWatchRelayRoundTrips() throws {
        let snapshot = ShannonSnapshot(
            agents: [AgentState(id: "a1", name: "Agent", activity: .running, updatedAt: fixedDate)],
            docking: [DockingProgress(id: "b", benchmarkName: "Astex Diverse",
                                      targetsComplete: 34, targetsTotal: 85,
                                      updatedAt: fixedDate)],
            nowPlaying: NowPlayingSnapshot(title: "Blue in Green", artist: "Miles Davis",
                                           updatedAt: fixedDate),
            device: MacDeviceState(deviceName: "Mac", batteryPercent: 80, isCharging: false,
                                   updatedAt: fixedDate),
            capturedAt: fixedDate
        )
        let decoded = try WatchRelayCodec.decode(try WatchRelayCodec.encode(snapshot))
        XCTAssertEqual(decoded.agents, snapshot.agents)
        XCTAssertEqual(decoded.docking, snapshot.docking)
        XCTAssertEqual(decoded.nowPlaying?.title, "Blue in Green")
    }

    /// The watch renders no artwork, and WatchConnectivity payloads are
    /// size-capped, so artwork must not cross the relay.
    func testWatchRelayStripsArtworkAndOldNotifications() throws {
        let notes = (0..<9).map {
            NotificationMirror(id: "n\($0)", sender: "S", title: "T", body: "B",
                               postedAt: fixedDate.addingTimeInterval(Double($0)))
        }
        let snapshot = ShannonSnapshot(
            nowPlaying: NowPlayingSnapshot(title: "T",
                                           artworkJPEG: Data(repeating: 1, count: 4096)),
            notifications: notes
        )
        let decoded = try WatchRelayCodec.decode(try WatchRelayCodec.encode(snapshot))
        XCTAssertNil(decoded.nowPlaying?.artworkJPEG)
        XCTAssertEqual(decoded.notifications.count, 5)
        XCTAssertEqual(decoded.notifications.first?.id, "n8", "newest notifications survive")
    }

    func testWatchRelayRejectsMalformedPayload() {
        XCTAssertThrowsError(try WatchRelayCodec.decode(["wrongKey": Data()]))
    }

    // MARK: trimmedForWatch bounds

    /// Direct trim contract: newest notifications survive, artwork is stripped,
    /// and every other field is preserved so the watch still has full agent
    /// / docking / confirmation state.
    func testTrimmedForWatchBoundsAndPreservation() {
        let notes = (0..<9).map {
            NotificationMirror(
                id: "n\($0)", sender: "S", title: "T", body: "B",
                postedAt: fixedDate.addingTimeInterval(Double($0))
            )
        }
        let agents = [
            AgentState(id: "a1", name: "A", activity: .running,
                       entropyBits: 2.1, updatedAt: fixedDate),
        ]
        let docking = [
            DockingProgress(id: "b", benchmarkName: "Astex",
                            targetsComplete: 1, targetsTotal: 85, updatedAt: fixedDate),
        ]
        let confirmations = [
            PendingConfirmation(id: "c1", question: "Dock?", createdAt: fixedDate,
                                expiresAt: fixedDate.addingTimeInterval(600)),
        ]
        let snapshot = ShannonSnapshot(
            agents: agents,
            docking: docking,
            nowPlaying: NowPlayingSnapshot(
                title: "Track", artworkJPEG: Data(repeating: 1, count: 256),
                updatedAt: fixedDate
            ),
            device: MacDeviceState(deviceName: "Mac", batteryPercent: 50,
                                   isCharging: false, updatedAt: fixedDate),
            notifications: notes,
            timers: [TimerState(id: "t1", label: "Tea",
                                fireAt: fixedDate.addingTimeInterval(60),
                                updatedAt: fixedDate)],
            confirmations: confirmations,
            capturedAt: fixedDate
        )

        let defaultTrim = snapshot.trimmedForWatch()
        XCTAssertEqual(defaultTrim.notifications.count, 5)
        XCTAssertEqual(defaultTrim.notifications.map(\.id), ["n8", "n7", "n6", "n5", "n4"])
        XCTAssertNil(defaultTrim.nowPlaying?.artworkJPEG)
        XCTAssertEqual(defaultTrim.nowPlaying?.title, "Track")
        XCTAssertEqual(defaultTrim.agents, agents)
        XCTAssertEqual(defaultTrim.docking, docking)
        XCTAssertEqual(defaultTrim.confirmations, confirmations)
        XCTAssertEqual(defaultTrim.timers.count, 1)
        XCTAssertEqual(defaultTrim.device?.deviceName, "Mac")
        XCTAssertEqual(defaultTrim.agents.first?.entropyBits, 2.1,
                       "trim must not drop optional entropy")

        let zero = snapshot.trimmedForWatch(maxNotifications: 0)
        XCTAssertTrue(zero.notifications.isEmpty)
        XCTAssertEqual(zero.agents.count, 1)

        let negative = snapshot.trimmedForWatch(maxNotifications: -3)
        XCTAssertTrue(negative.notifications.isEmpty,
                      "negative limit must clamp, not trap")

        let oversized = snapshot.trimmedForWatch(maxNotifications: 100)
        XCTAssertEqual(oversized.notifications.count, notes.count)
    }

    /// Encode path always trims; decode must not re-inflate stripped artwork.
    func testWatchRelayEncodeAlwaysAppliesTrim() throws {
        let notes = (0..<8).map {
            NotificationMirror(id: "n\($0)", sender: "S", title: "T", body: "B",
                               postedAt: fixedDate.addingTimeInterval(Double($0)))
        }
        let snapshot = ShannonSnapshot(
            nowPlaying: NowPlayingSnapshot(title: "T",
                                           artworkJPEG: Data(repeating: 9, count: 128)),
            notifications: notes,
            capturedAt: fixedDate
        )
        let payload = try WatchRelayCodec.encode(snapshot)
        let decoded = try WatchRelayCodec.decode(payload)
        XCTAssertNil(decoded.nowPlaying?.artworkJPEG)
        XCTAssertEqual(decoded.notifications.count, 5)
    }

    // MARK: WatchMessageCodec

    func testWatchMessageSnapshotRoundTripAndTrim() throws {
        let snapshot = ShannonSnapshot(
            agents: [AgentState(id: "a", name: "A", activity: .blocked,
                                updatedAt: fixedDate)],
            nowPlaying: NowPlayingSnapshot(title: "T",
                                           artworkJPEG: Data([1, 2, 3]),
                                           updatedAt: fixedDate),
            notifications: (0..<7).map {
                NotificationMirror(id: "n\($0)", sender: "S", title: "T", body: "B",
                                   postedAt: fixedDate.addingTimeInterval(Double($0)))
            },
            confirmations: [PendingConfirmation(id: "c", question: "Proceed?",
                                                createdAt: fixedDate,
                                                expiresAt: fixedDate.addingTimeInterval(600))],
            capturedAt: fixedDate
        )
        let decoded = try WatchMessageCodec.decode(
            try WatchMessageCodec.encode(.snapshot(snapshot))
        )
        guard case .snapshot(let out) = decoded else {
            return XCTFail("expected snapshot envelope")
        }
        XCTAssertEqual(out.agents.map(\.id), ["a"])
        XCTAssertNil(out.nowPlaying?.artworkJPEG)
        XCTAssertEqual(out.notifications.count, 5)
        XCTAssertEqual(out.confirmations.map(\.id), ["c"])
    }

    func testWatchMessageTimeCriticalRoundTrips() throws {
        let cases: [WatchMessage] = [
            .alert("agent-errored"),
            .command(.nextTrack),
            .answer(id: "c1", answer: .confirmed, source: .headNod),
            .answer(id: "c2", answer: .denied, source: .voice),
        ]
        for message in cases {
            XCTAssertTrue(message.isTimeCritical)
            let decoded = try WatchMessageCodec.decode(try WatchMessageCodec.encode(message))
            XCTAssertEqual(decoded, message)
        }
        XCTAssertFalse(WatchMessage.snapshot(ShannonSnapshot()).isTimeCritical)
    }

    func testWatchMessageRejectsMalformedPayload() {
        XCTAssertThrowsError(try WatchMessageCodec.decode(["wrongKey": Data()]))
        XCTAssertThrowsError(try WatchMessageCodec.decode([:]))
    }
}
