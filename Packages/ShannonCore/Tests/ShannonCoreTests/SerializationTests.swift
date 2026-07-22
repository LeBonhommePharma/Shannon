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
}
