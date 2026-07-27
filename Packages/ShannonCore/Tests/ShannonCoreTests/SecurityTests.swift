import XCTest
@testable import ShannonCore

/// Guards the two properties LP asked for explicitly: secrets never leave the
/// Keychain, and cached agent data is written encrypted at rest.
final class SecurityTests: XCTestCase {

    /// Nothing Shannon syncs may carry a credential. This asserts on the field
    /// names themselves, so a future record type that adds a `token` field
    /// fails here rather than silently shipping it to iCloud.
    func testNoSyncedRecordCarriesCredentialFields() {
        let forbidden = ["token", "password", "secret", "credential", "apikey", "key", "auth"]

        var allFields: [String] = []
        allFields += AgentState(id: "a", name: "n", activity: .idle).cloudFields.keys
        allFields += DockingProgress(id: "b", benchmarkName: "B", targetsComplete: 0,
                                     targetsTotal: 1).cloudFields.keys
        allFields += NowPlayingSnapshot(title: "t").cloudFields.keys
        allFields += MacDeviceState(deviceName: "d", batteryPercent: 1,
                                    isCharging: false).cloudFields.keys
        allFields += NotificationMirror(sender: "s", title: "t", body: "b").cloudFields.keys
        allFields += TimerState(label: "l", fireAt: Date()).cloudFields.keys
        allFields += RemoteCommand(command: .nextTrack, origin: "o").cloudFields.keys
        allFields += PendingConfirmation(question: "q").cloudFields.keys
        allFields += ConfirmationResponse(id: "c", answer: .confirmed, source: .tap,
                                          origin: "o").cloudFields.keys

        for field in allFields {
            let lowered = field.lowercased()
            for word in forbidden {
                XCTAssertFalse(
                    lowered.contains(word),
                    "synced field '\(field)' looks like a credential; secrets belong in SecureStore"
                )
            }
        }
    }

    /// The container is fixed and private. A test rather than a comment,
    /// because switching to `publicCloudDatabase` would be a one-word change
    /// that leaks every agent task title.
    ///
    /// Reads the **shipped** `ShannonSync.swift` so this fails if the backend
    /// body changes (a hard-coded prose string in the test cannot).
    func testSyncTargetsPrivateContainerOnly() throws {
        XCTAssertEqual(ShannonSyncConfig.containerID, "iCloud.com.lebonhommepharma.shannon")
        XCTAssertEqual(ShannonSyncConfig.zoneName, "ShannonState")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ShannonCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ShannonCore
            .appendingPathComponent("Sources/ShannonCore/ShannonSync.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        XCTAssertTrue(
            source.contains("privateCloudDatabase"),
            "CloudKitSyncBackend must use privateCloudDatabase"
        )
        XCTAssertFalse(
            source.contains("publicCloudDatabase"),
            "CloudKitSyncBackend must not use publicCloudDatabase"
        )
    }

    func testAllRecordTypesAreRegisteredForSchemaDeploy() {
        // Every CloudSyncable type must appear, or its schema is never
        // deployed and the phone silently sees nothing for it.
        XCTAssertEqual(Set(ShannonSyncConfig.allRecordTypes).count,
                       ShannonSyncConfig.allRecordTypes.count)
        for expected in [
            AgentState.recordType, DockingProgress.recordType, NowPlayingSnapshot.recordType,
            MacDeviceState.recordType, NotificationMirror.recordType, TimerState.recordType,
            RemoteCommand.recordType, PendingConfirmation.recordType,
            ConfirmationResponse.recordType,
        ] {
            XCTAssertTrue(ShannonSyncConfig.allRecordTypes.contains(expected), expected)
        }
    }

    /// Pet state is local-only (ENH-021). Accidental registration would mirror
    /// pet XP/name into the private CloudKit zone across Mac/phone without a
    /// hub publish path — keep it out of the schema deploy list.
    func testPetCloudRecordIsNotMirroredInSyncSchema() {
        XCTAssertFalse(
            ShannonSyncConfig.allRecordTypes.contains(PetCloudRecord.recordType),
            "PetCloudRecord must stay local-only (not Mac-hub mirrored)"
        )
    }

    // MARK: Snapshot cache

    func testCacheRoundTripsThroughDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shannon-cache-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = SnapshotCache(fileURL: url)
        let snapshot = ShannonSnapshot(
            agents: [AgentState(id: "a", name: "Agent", activity: .running)],
            confirmations: [PendingConfirmation(id: "c", question: "Dock?")]
        )
        XCTAssertTrue(cache.save(snapshot))

        let loaded = cache.load()
        XCTAssertEqual(loaded?.agents.map(\.id), ["a"])
        XCTAssertEqual(loaded?.confirmations.map(\.id), ["c"])
        let record = cache.loadRecord()
        XCTAssertEqual(record?.snapshot.agents.map(\.id), ["a"])
        XCTAssertNil(record?.lastError)
        XCTAssertFalse(record?.isOffline == true)
    }

    /// UX-038: offline/lastError persists with the snapshot envelope.
    func testCachePersistsOfflineLastError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shannon-cache-offline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = SnapshotCache(fileURL: url)
        let snapshot = ShannonSnapshot(
            agents: [AgentState(id: "a", name: "Agent", activity: .running)]
        )
        XCTAssertTrue(cache.save(snapshot, lastError: "CKError network unavailable"))

        let record = cache.loadRecord()
        XCTAssertEqual(record?.snapshot.agents.map(\.id), ["a"])
        XCTAssertEqual(record?.lastError, "CKError network unavailable")
        XCTAssertTrue(record?.isOffline == true)
        // load() still returns the snapshot for watch/complication callers.
        XCTAssertEqual(cache.load()?.agents.map(\.id), ["a"])
    }

    /// UX-038: bare pre-envelope ShannonSnapshot files still load (online).
    func testCacheLoadsLegacyBareSnapshotAsOnline() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shannon-cache-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = ShannonSnapshot(
            agents: [AgentState(id: "legacy", name: "L", activity: .idle)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url)

        let record = SnapshotCache(fileURL: url).loadRecord()
        XCTAssertEqual(record?.snapshot.agents.map(\.id), ["legacy"])
        XCTAssertNil(record?.lastError)
        XCTAssertFalse(record?.isOffline == true)
    }

    #if os(iOS) || os(watchOS)
    /// On iOS and watchOS the cache must carry a Data Protection class —
    /// without it, cached agent titles sit unencrypted on disk.
    func testCacheIsWrittenWithFileProtection() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shannon-protection-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(SnapshotCache(fileURL: url).save(ShannonSnapshot()))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        XCTAssertEqual(protection, .completeUnlessOpen)
    }
    #endif

    func testClearRemovesCachedState() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shannon-clear-\(UUID().uuidString).json")
        let cache = SnapshotCache(fileURL: url)
        XCTAssertTrue(cache.save(ShannonSnapshot(agents: [
            AgentState(id: "a", name: "A", activity: .running),
        ])))
        cache.clear()
        XCTAssertNil(cache.load())
    }

    func testCacheWithoutContainerFailsQuietly() {
        // A missing App Group (misconfigured entitlement) must degrade to "no
        // cache", never crash the widget.
        let cache = SnapshotCache(fileURL: nil)
        XCTAssertFalse(cache.save(ShannonSnapshot()))
        XCTAssertNil(cache.load())
    }

    // MARK: Keychain configuration

    func testSecureStoreDefaultsToSharedAccessGroup() {
        let store = SecureStore()
        XCTAssertEqual(store.accessGroup, "com.lebonhommepharma.shannon")
        XCTAssertEqual(store.service, "com.lebonhommepharma.shannon.agent")
        XCTAssertTrue(store.synchronizable, "Mac-provisioned tokens must reach the iPhone")
    }

    func testDeviceBoundStoreOptsOutOfSync() {
        let store = SecureStore(synchronizable: false)
        XCTAssertFalse(store.synchronizable)
    }
}
