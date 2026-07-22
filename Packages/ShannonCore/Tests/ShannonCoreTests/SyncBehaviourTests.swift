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
}
