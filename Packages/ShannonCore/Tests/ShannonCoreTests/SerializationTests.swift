import XCTest
@testable import ShannonCore

/// Round-trip coverage for every synced record type. A field that encodes but
/// does not decode shows up on the phone as a missing card, not a crash, so
/// these tests are the only place that mismatch is caught.
final class SerializationTests: XCTestCase {
    /// CloudKit truncates sub-millisecond precision; comparing dates built
    /// from a whole number of seconds keeps round-trips exact.
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testAgentStateRoundTrips() throws {
        let agent = AgentState(
            id: "local_9c754fdc",
            name: "FlexAID∆S",
            activity: .running,
            taskTitle: "Dock 1of6",
            turnCount: 12,
            lastAction: "Wrote pose ensemble",
            entropyBits: 8.42,
            entropyDelta: -3.4,
            isCollapsed: true,
            updatedAt: fixedDate
        )
        XCTAssertEqual(try agent.reencoded(), agent)
    }

    func testAgentStateRoundTripsWithoutOptionalEntropy() throws {
        let agent = AgentState(id: "a1", name: "Pet memory", activity: .idle, updatedAt: fixedDate)
        let decoded = try agent.reencoded()
        XCTAssertEqual(decoded, agent)
        XCTAssertNil(decoded.entropyBits)
        XCTAssertNil(decoded.entropyDelta)
    }

    func testDockingProgressRoundTrips() throws {
        let progress = DockingProgress(
            id: "astex-diverse",
            benchmarkName: "Astex Diverse",
            targetsComplete: 34,
            targetsTotal: 85,
            currentTarget: "1of6",
            bestRMSD: 1.42,
            successRate: 0.72,
            etaSeconds: 4380,
            isRunning: true,
            updatedAt: fixedDate
        )
        XCTAssertEqual(try progress.reencoded(), progress)
    }

    func testNowPlayingRoundTripsIncludingArtwork() throws {
        let media = NowPlayingSnapshot(
            title: "Blue in Green",
            artist: "Miles Davis",
            album: "Kind of Blue",
            duration: 337,
            elapsed: 120,
            isPlaying: true,
            artworkJPEG: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            sourceBundleID: "com.apple.Music",
            updatedAt: fixedDate
        )
        let decoded = try media.reencoded()
        XCTAssertEqual(decoded, media)
        XCTAssertEqual(decoded.artworkJPEG, Data([0xFF, 0xD8, 0xFF, 0xE0]))
    }

    func testMacDeviceStateRoundTrips() throws {
        let device = MacDeviceState(
            deviceName: "LP-MacBook-Pro",
            batteryPercent: 82,
            isCharging: true,
            minutesRemaining: 44,
            updatedAt: fixedDate
        )
        XCTAssertEqual(try device.reencoded(), device)
    }

    /// Capacity gauges are published for multi-device load preference — round-trip
    /// must preserve them (fail-closed when absent on older peers).
    func testMacDeviceStateCapacityRoundTrips() throws {
        let device = MacDeviceState(
            deviceName: "LP-MacBook-Pro",
            batteryPercent: 70,
            isCharging: false,
            minutesRemaining: 90,
            capacity: HostCapacitySnapshot(
                cpuPercent: 88, ramPercent: 62, diskPercent: 40, sampledAt: fixedDate
            ),
            updatedAt: fixedDate
        )
        let round = try device.reencoded()
        XCTAssertEqual(round.capacity?.cpuPercent, 88)
        XCTAssertEqual(round.capacity?.ramPercent, 62)
        XCTAssertEqual(round.capacity?.diskPercent, 40)
        XCTAssertEqual(round, device)
    }

    func testNotificationMirrorRoundTrips() throws {
        let note = NotificationMirror(
            id: "n1",
            sender: "Messages",
            title: "Anne",
            body: "Docking run finished",
            postedAt: fixedDate
        )
        XCTAssertEqual(try note.reencoded(), note)
    }

    func testTimerStateRoundTrips() throws {
        let timer = TimerState(
            id: "t1",
            label: "Tea",
            fireAt: fixedDate.addingTimeInterval(300),
            isPaused: true,
            pausedRemaining: 120,
            updatedAt: fixedDate
        )
        XCTAssertEqual(try timer.reencoded(), timer)
    }

    func testRemoteCommandRoundTrips() throws {
        let command = RemoteCommand(
            id: "c1",
            command: .nextTrack,
            origin: "watch",
            issuedAt: fixedDate
        )
        XCTAssertEqual(try command.reencoded(), command)
    }

    // MARK: Decode failures

    func testMissingRequiredFieldThrows() {
        var fields = AgentState(id: "a", name: "n", activity: .idle).cloudFields
        fields.removeValue(forKey: AgentState.Field.turnCount)
        XCTAssertThrowsError(try AgentState(cloudFields: fields)) { error in
            XCTAssertEqual(
                error as? CloudDecodeError,
                .missingField(AgentState.Field.turnCount)
            )
        }
    }

    func testUnknownActivityThrowsRatherThanDefaulting() {
        var fields = AgentState(id: "a", name: "n", activity: .idle).cloudFields
        fields[AgentState.Field.activity] = .string("teleporting")
        XCTAssertThrowsError(try AgentState(cloudFields: fields)) { error in
            XCTAssertEqual(
                error as? CloudDecodeError,
                .unknownEnumValue(field: AgentState.Field.activity, value: "teleporting")
            )
        }
    }

    /// CloudKit hands every number back as NSNumber, so an Int field can
    /// arrive typed as a Double. The readers must widen rather than throw.
    func testNumericWideningOnDecode() throws {
        var fields = DockingProgress(
            id: "b", benchmarkName: "B", targetsComplete: 34, targetsTotal: 85
        ).cloudFields
        fields[DockingProgress.Field.targetsComplete] = .double(34.0)
        fields[DockingProgress.Field.etaSeconds] = .int(60)

        let decoded = try DockingProgress(cloudFields: fields)
        XCTAssertEqual(decoded.targetsComplete, 34)
        XCTAssertEqual(decoded.etaSeconds, 60)
    }

    /// Bools go over the wire as 0/1 integers.
    func testBoolDecodesFromInteger() throws {
        var fields = AgentState(id: "a", name: "n", activity: .idle).cloudFields
        fields[AgentState.Field.isCollapsed] = .int(1)
        XCTAssertTrue(try AgentState(cloudFields: fields).isCollapsed)
    }

    // MARK: ShannonSnapshot JSON codec

    /// SnapshotCache / WatchConnectivity both use JSON Codable. A field that
    /// encodes but fails to decode blanks a card on the watch.
    func testShannonSnapshotJSONRoundTrip() throws {
        let snapshot = ShannonSnapshot(
            agents: [
                AgentState(
                    id: "a1", name: "FlexAID∆S", activity: .running,
                    taskTitle: "Dock 1of6", turnCount: 12,
                    entropyBits: 8.42, entropyDelta: -3.4, isCollapsed: true,
                    updatedAt: fixedDate
                ),
            ],
            docking: [
                DockingProgress(
                    id: "astex", benchmarkName: "Astex Diverse",
                    targetsComplete: 34, targetsTotal: 85,
                    bestRMSD: 1.42, updatedAt: fixedDate
                ),
            ],
            nowPlaying: NowPlayingSnapshot(
                title: "Blue in Green", artist: "Miles Davis",
                artworkJPEG: Data([0xFF, 0xD8]), updatedAt: fixedDate
            ),
            device: MacDeviceState(
                deviceName: "Mac", batteryPercent: 80, isCharging: false,
                updatedAt: fixedDate
            ),
            notifications: [
                NotificationMirror(
                    id: "n1", sender: "Messages", title: "Anne", body: "Hi",
                    postedAt: fixedDate
                ),
            ],
            timers: [
                TimerState(
                    id: "t1", label: "Tea",
                    fireAt: fixedDate.addingTimeInterval(300),
                    updatedAt: fixedDate
                ),
            ],
            confirmations: [
                PendingConfirmation(
                    id: "c1", question: "Dock 1a4g?",
                    agentID: "a1", createdAt: fixedDate,
                    expiresAt: fixedDate.addingTimeInterval(900)
                ),
            ],
            capturedAt: fixedDate
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(ShannonSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.agents.first?.entropyBits, 8.42)
        XCTAssertEqual(decoded.agents.first?.entropyDelta, -3.4)
        XCTAssertEqual(decoded.nowPlaying?.artworkJPEG, Data([0xFF, 0xD8]))
        XCTAssertEqual(decoded.confirmations.first?.id, "c1")
    }

    /// Empty / sparse snapshots must round-trip without inventing media,
    /// device state, or entropy numbers.
    func testShannonSnapshotSparseJSONRoundTripDoesNotFabricateOptionals() throws {
        let snapshot = ShannonSnapshot(
            agents: [AgentState(id: "a", name: "A", activity: .idle, updatedAt: fixedDate)],
            capturedAt: fixedDate
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            ShannonSnapshot.self,
            from: try encoder.encode(snapshot)
        )
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNil(decoded.nowPlaying)
        XCTAssertNil(decoded.device)
        XCTAssertNil(decoded.agents.first?.entropyBits)
        XCTAssertNil(decoded.agents.first?.entropyDelta)
        XCTAssertTrue(decoded.notifications.isEmpty)
        XCTAssertTrue(decoded.confirmations.isEmpty)
        XCTAssertTrue(decoded.docking.isEmpty)
        XCTAssertTrue(decoded.timers.isEmpty)
    }

    /// Optional entropy must stay nil when the CloudKit field is absent —
    /// fabricating 0.0 would look like a real collapse reading.
    func testMissingOptionalEntropyFieldsStayNil() throws {
        let fields = AgentState(id: "a", name: "n", activity: .running, updatedAt: fixedDate)
            .cloudFields
        XCTAssertNil(fields[AgentState.Field.entropyBits],
                     "nil optionals must not be written to the wire")
        XCTAssertNil(fields[AgentState.Field.entropyDelta])

        let decoded = try AgentState(cloudFields: fields)
        XCTAssertNil(decoded.entropyBits)
        XCTAssertNil(decoded.entropyDelta)
        XCTAssertFalse(decoded.isCollapsed)
    }

    /// JSON that omits entropy keys must decode as nil, not 0.
    func testJSONOmittingEntropyDoesNotDefaultToZero() throws {
        // Minimal AgentState-shaped JSON without entropy keys.
        let json = """
        {
          "id": "a1",
          "name": "Agent",
          "activity": "running",
          "taskTitle": "",
          "turnCount": 0,
          "lastAction": "",
          "isCollapsed": false,
          "updatedAt": "2023-11-14T22:13:20Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let agent = try decoder.decode(AgentState.self, from: json)
        XCTAssertNil(agent.entropyBits)
        XCTAssertNil(agent.entropyDelta)
    }

    /// Explicit JSON null for optional entropy must also stay nil.
    func testJSONNullEntropyStaysNil() throws {
        let json = """
        {
          "id": "a1",
          "name": "Agent",
          "activity": "idle",
          "taskTitle": "",
          "turnCount": 0,
          "lastAction": "",
          "entropyBits": null,
          "entropyDelta": null,
          "isCollapsed": false,
          "updatedAt": "2023-11-14T22:13:20Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let agent = try decoder.decode(AgentState.self, from: json)
        XCTAssertNil(agent.entropyBits)
        XCTAssertNil(agent.entropyDelta)
    }
}
