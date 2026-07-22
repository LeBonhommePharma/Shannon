import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Container and zone identity, shared by the Mac publisher and the
/// phone/watch consumers.
public enum ShannonSyncConfig {
    /// Must match the iCloud container in Signing & Capabilities on every target.
    public static let containerID = "iCloud.com.lebonhommepharma.shannon"
    /// All Shannon state lives in the private database — none of it is shared.
    public static let zoneName = "ShannonState"
    /// Subscription id for push-driven refresh.
    public static let subscriptionID = "shannon-state-changes"

    public static let allRecordTypes = [
        AgentState.recordType,
        DockingProgress.recordType,
        NowPlayingSnapshot.recordType,
        MacDeviceState.recordType,
        NotificationMirror.recordType,
        TimerState.recordType,
        RemoteCommand.recordType,
    ]
}

public enum SyncError: Error {
    case notAvailable(String)
    case underlying(Error)
}

/// Storage abstraction so the store, the views and the tests can run without
/// an entitled CloudKit container. `InMemorySyncBackend` backs previews and
/// unit tests; `CloudKitSyncBackend` backs the shipping apps.
public protocol ShannonSyncBackend: AnyObject, Sendable {
    func save(recordType: String, recordName: String, fields: CloudFields) async throws
    func delete(recordType: String, recordName: String) async throws
    func fetchAll(recordType: String) async throws -> [(recordName: String, fields: CloudFields)]
}

public extension ShannonSyncBackend {
    func save<T: CloudSyncable>(_ value: T) async throws {
        try await save(
            recordType: T.recordType,
            recordName: value.recordName,
            fields: value.cloudFields
        )
    }

    func delete<T: CloudSyncable>(_ value: T) async throws {
        try await delete(recordType: T.recordType, recordName: value.recordName)
    }

    /// Fetch and decode. Records that fail to decode are skipped rather than
    /// failing the whole fetch — one malformed record from an older build of
    /// the Mac app should not blank the phone's screen.
    func fetch<T: CloudSyncable>(_ type: T.Type) async throws -> [T] {
        try await fetchAll(recordType: T.recordType).compactMap { try? T(cloudFields: $0.fields) }
    }
}

/// Deterministic backend for tests and SwiftUI previews.
public final class InMemorySyncBackend: ShannonSyncBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [String: CloudFields]] = [:]
    /// Every save/delete, in order — lets tests assert publish behaviour.
    public private(set) var writeLog: [String] = []

    public init() {}

    /// Synchronous so the lock is never held across a suspension point —
    /// NSLock is unavailable from async contexts under Swift 6.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func save(recordType: String, recordName: String, fields: CloudFields) async throws {
        withLock {
            storage[recordType, default: [:]][recordName] = fields
            writeLog.append("save:\(recordType):\(recordName)")
        }
    }

    public func delete(recordType: String, recordName: String) async throws {
        withLock {
            storage[recordType]?.removeValue(forKey: recordName)
            writeLog.append("delete:\(recordType):\(recordName)")
        }
    }

    public func fetchAll(
        recordType: String
    ) async throws -> [(recordName: String, fields: CloudFields)] {
        withLock {
            (storage[recordType] ?? [:])
                .map { (recordName: $0.key, fields: $0.value) }
                .sorted { $0.recordName < $1.recordName }
        }
    }

    public func recordCount(_ recordType: String) -> Int {
        withLock { storage[recordType]?.count ?? 0 }
    }
}

#if canImport(CloudKit)

/// CloudValue ↔ CKRecord translation. Split out from the backend so the
/// mapping itself is exercised by tests on any platform with CloudKit headers.
public enum CKRecordCodec {
    public static func apply(_ fields: CloudFields, to record: CKRecord) {
        for (key, value) in fields {
            switch value {
            case .string(let v):     record[key] = v as CKRecordValue
            case .double(let v):     record[key] = v as CKRecordValue
            case .int(let v):        record[key] = v as CKRecordValue
            case .bool(let v):       record[key] = (v ? 1 : 0) as CKRecordValue
            case .date(let v):       record[key] = v as CKRecordValue
            case .data(let v):       record[key] = v as CKRecordValue
            case .stringList(let v): record[key] = v as CKRecordValue
            }
        }
    }

    /// CloudKit erases Swift types to NSNumber/NSString, so bools and ints
    /// come back indistinguishable. The decode side of each snapshot accepts
    /// numeric widening, which is what makes that safe.
    public static func fields(from record: CKRecord) -> CloudFields {
        var out: CloudFields = [:]
        for key in record.allKeys() {
            switch record[key] {
            case let v as String:   out[key] = .string(v)
            case let v as Date:     out[key] = .date(v)
            case let v as Data:     out[key] = .data(v)
            case let v as [String]: out[key] = .stringList(v)
            case let v as NSNumber:
                // Integral values decode as .int; the readers widen to Double
                // where a Double is expected.
                if v.doubleValue == v.doubleValue.rounded(),
                   abs(v.doubleValue) < Double(Int.max) {
                    out[key] = .int(v.intValue)
                } else {
                    out[key] = .double(v.doubleValue)
                }
            default:
                continue
            }
        }
        return out
    }
}

/// Private-database CloudKit backend against a custom zone.
///
/// Requires the iCloud capability with `ShannonSyncConfig.containerID` on the
/// target — see docs/MULTI_DEVICE.md for the exact Xcode configuration.
public final class CloudKitSyncBackend: ShannonSyncBackend, @unchecked Sendable {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let zoneReady = ZoneGate()

    public init(containerID: String = ShannonSyncConfig.containerID) {
        let container = CKContainer(identifier: containerID)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: ShannonSyncConfig.zoneName,
                                      ownerName: CKCurrentUserDefaultName)
    }

    /// Serializes the one-time custom-zone creation. Concurrent publishers
    /// racing to create the same zone is the classic first-launch CloudKit bug.
    private actor ZoneGate {
        private var created = false
        func ensure(_ work: () async throws -> Void) async throws {
            guard !created else { return }
            try await work()
            created = true
        }
    }

    private func ensureZone() async throws {
        try await zoneReady.ensure {
            let zone = CKRecordZone(zoneID: zoneID)
            do {
                _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
            } catch let error as CKError where error.code == .serverRecordChanged {
                // Already exists — that is the success case on later launches.
            }
        }
    }

    public func save(recordType: String, recordName: String, fields: CloudFields) async throws {
        try await ensureZone()
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        // Fetch-then-modify keeps the change tag, so republishing the same
        // record updates in place instead of failing with serverRecordChanged.
        let record: CKRecord
        if let existing = try? await database.record(for: id) {
            record = existing
        } else {
            record = CKRecord(recordType: recordType, recordID: id)
        }
        CKRecordCodec.apply(fields, to: record)
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [],
                                                 savePolicy: .changedKeys)
        } catch {
            throw SyncError.underlying(error)
        }
    }

    public func delete(recordType: String, recordName: String) async throws {
        try await ensureZone()
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            _ = try await database.modifyRecords(saving: [], deleting: [id])
        } catch let error as CKError where error.code == .unknownItem {
            // Already gone.
        } catch {
            throw SyncError.underlying(error)
        }
    }

    public func fetchAll(
        recordType: String
    ) async throws -> [(recordName: String, fields: CloudFields)] {
        try await ensureZone()
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        do {
            let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
            return results.compactMap { id, result in
                guard let record = try? result.get() else { return nil }
                return (recordName: id.recordName, fields: CKRecordCodec.fields(from: record))
            }
        } catch let error as CKError where error.code == .unknownItem {
            // Record type has never been written — empty, not an error.
            return []
        } catch {
            throw SyncError.underlying(error)
        }
    }

    /// Registers a silent-push subscription so the phone refreshes when the
    /// Mac publishes, instead of polling. Safe to call on every launch.
    public func ensureSubscriptions() async throws {
        try await ensureZone()
        let subscription = CKRecordZoneSubscription(
            zoneID: zoneID,
            subscriptionID: ShannonSyncConfig.subscriptionID
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Subscription already registered.
        } catch {
            throw SyncError.underlying(error)
        }
    }
}

#endif

/// Everything the phone and watch render, in one value. Also the payload the
/// phone relays to the watch over WatchConnectivity.
public struct ShannonSnapshot: Codable, Equatable, Sendable {
    public var agents: [AgentState]
    public var docking: [DockingProgress]
    public var nowPlaying: NowPlayingSnapshot?
    public var device: MacDeviceState?
    public var notifications: [NotificationMirror]
    public var timers: [TimerState]
    public var capturedAt: Date

    public init(
        agents: [AgentState] = [],
        docking: [DockingProgress] = [],
        nowPlaying: NowPlayingSnapshot? = nil,
        device: MacDeviceState? = nil,
        notifications: [NotificationMirror] = [],
        timers: [TimerState] = [],
        capturedAt: Date = Date()
    ) {
        self.agents = agents
        self.docking = docking
        self.nowPlaying = nowPlaying
        self.device = device
        self.notifications = notifications
        self.timers = timers
        self.capturedAt = capturedAt
    }

    public var isEmpty: Bool {
        agents.isEmpty && docking.isEmpty && nowPlaying == nil
            && device == nil && notifications.isEmpty && timers.isEmpty
    }

    /// The single line a watch complication shows. Docking progress wins when
    /// a benchmark is running (that is what LP is waiting on), then an
    /// alerting agent, then media.
    public func complicationLine() -> String {
        if let run = docking.first(where: { $0.isRunning }) ?? docking.first {
            var line = run.complicationLine()
            if let h = agents.rankedForDisplay().first?.entropyBits {
                line += " H=\(String(format: "%.2f", h))"
            }
            return line
        }
        if let alerting = agents.rankedForDisplay().first(where: { $0.activity.isAlerting }) {
            return alerting.compactLine()
        }
        if let media = nowPlaying?.compactLine() { return media }
        if let agent = agents.rankedForDisplay().first { return agent.compactLine() }
        return "Shannon"
    }

    /// The three cards the watch shows, in order.
    public func watchCards(limit: Int = 3) -> [String] {
        var cards: [String] = []
        if let agent = agents.rankedForDisplay().first { cards.append(agent.compactLine()) }
        if let run = docking.first(where: { $0.isRunning }) ?? docking.first {
            cards.append(run.complicationLine())
        }
        if let media = nowPlaying?.compactLine() { cards.append(media) }
        return Array(cards.prefix(limit))
    }

    /// Strips artwork and older notifications before the phone relays this to
    /// the watch — WatchConnectivity payloads are size-capped, and the watch
    /// renders neither.
    public func trimmedForWatch(maxNotifications: Int = 5) -> ShannonSnapshot {
        var copy = self
        copy.nowPlaying?.artworkJPEG = nil
        copy.notifications = Array(
            notifications.sorted { $0.postedAt > $1.postedAt }.prefix(maxNotifications)
        )
        return copy
    }
}

/// JSON framing for the WatchConnectivity relay. Pure, so the phone↔watch wire
/// format is testable without a paired device.
public enum WatchRelayCodec {
    public static let payloadKey = "shannonSnapshot"

    public static func encode(_ snapshot: ShannonSnapshot) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return [payloadKey: try encoder.encode(snapshot.trimmedForWatch())]
    }

    public static func decode(_ payload: [String: Any]) throws -> ShannonSnapshot {
        guard let data = payload[payloadKey] as? Data else {
            throw CloudDecodeError.missingField(payloadKey)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ShannonSnapshot.self, from: data)
    }
}
