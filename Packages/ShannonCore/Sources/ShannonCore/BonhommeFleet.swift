import Foundation

// MARK: - Bonhomme Fleet (FlexAIDdS FleetScheduler + NATURaL ClusterFleet presence)
//
// Pure, testable fleet scheduling and presence for Shannon's multi-device Mac hub.
// Ported mechanics (no docking engine / iCloud Drive I/O):
//   • Device capability + thermal/battery compute weight (FlexAIDdS DeviceCapability)
//   • Proportional work-chunk split; critical thermal excluded (FleetScheduler.splitWork)
//   • iCloud peer presence records (NATURaL FleetPresenceRecord)
//
// CloudKit transport stays behind ShannonSync; this module only decides *who*
// gets *how much* work and who is a live peer.

// MARK: Thermal (shared ladder with HostThermalState)

/// Fleet thermal state (mirrors FlexAIDdS DeviceCapability.ThermalState).
public enum BonhommeFleetThermal: String, Sendable, Codable, Hashable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    public init(host: HostThermalState) {
        switch host {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        }
    }

    /// Multiplier for compute weight (critical → 0 = excluded).
    public var weightMultiplier: Double {
        switch self {
        case .nominal: return 1.0
        case .fair: return 0.75
        case .serious: return 0.4
        case .critical: return 0.0
        }
    }
}

// MARK: Device capability

/// Hardware + health snapshot for one fleet member (Mac / iPhone / iPad / Watch).
public struct BonhommeFleetDevice: Sendable, Codable, Hashable, Identifiable, Equatable {
    public var id: String { deviceID }

    public let deviceID: String
    public let model: String
    public let platform: String
    public let estimatedTFLOPS: Double
    public let availableMemoryGB: Double
    public let thermalState: BonhommeFleetThermal
    /// 0…1, nil for desktops without a battery.
    public let batteryLevel: Double?
    public let isCharging: Bool
    /// 0…1 share weight after thermal × battery (0 = not available).
    public let computeWeight: Double
    public let snapshotAt: Date

    public init(
        deviceID: String,
        model: String,
        platform: String = "unknown",
        estimatedTFLOPS: Double,
        availableMemoryGB: Double = 4,
        thermalState: BonhommeFleetThermal = .nominal,
        batteryLevel: Double? = nil,
        isCharging: Bool = false,
        computeWeight: Double? = nil,
        snapshotAt: Date = Date()
    ) {
        self.deviceID = deviceID
        self.model = model
        self.platform = platform
        self.estimatedTFLOPS = max(0, estimatedTFLOPS)
        self.availableMemoryGB = max(0, availableMemoryGB)
        self.thermalState = thermalState
        self.batteryLevel = batteryLevel.map { min(1, max(0, $0)) }
        self.isCharging = isCharging
        self.snapshotAt = snapshotAt
        if let computeWeight {
            self.computeWeight = min(1, max(0, computeWeight))
        } else {
            self.computeWeight = Self.computeWeight(
                estimatedTFLOPS: self.estimatedTFLOPS,
                thermal: thermalState,
                batteryLevel: self.batteryLevel,
                isCharging: isCharging
            )
        }
    }

    /// Safe to schedule work (not critical thermal, positive weight).
    public var isAvailable: Bool {
        thermalState != .critical && computeWeight > 0
    }

    public var statusSummary: String {
        var parts = [model, platform]
        parts.append(String(format: "%.1f TFLOPS", estimatedTFLOPS))
        parts.append("thermal: \(thermalState.rawValue)")
        if let level = batteryLevel {
            parts.append("battery: \(Int(level * 100))%\(isCharging ? " (charging)" : "")")
        }
        parts.append(String(format: "weight: %.0f%%", computeWeight * 100))
        return parts.joined(separator: ", ")
    }

    /// FlexAIDdS-style weight: TFLOPS/10 × thermal × battery.
    public static func computeWeight(
        estimatedTFLOPS: Double,
        thermal: BonhommeFleetThermal,
        batteryLevel: Double?,
        isCharging: Bool
    ) -> Double {
        let thermalM = thermal.weightMultiplier
        let batteryM: Double = {
            guard let level = batteryLevel else { return 1.0 }
            if isCharging { return 1.0 }
            if level < 0.10 { return 0.0 }
            if level < 0.20 { return 0.25 }
            if level < 0.50 { return 0.6 }
            return 1.0
        }()
        return min(1.0, max(0, estimatedTFLOPS) / 10.0) * thermalM * batteryM
    }

    /// Build from Shannon MacDeviceState (hub publish path).
    public static func fromMacDevice(
        _ state: MacDeviceState,
        estimatedTFLOPS: Double = 4.0
    ) -> BonhommeFleetDevice {
        let thermal = state.capacity?.thermal.map { BonhommeFleetThermal(host: $0) } ?? .nominal
        let battery = Double(state.batteryPercent) / 100.0
        return BonhommeFleetDevice(
            deviceID: state.recordName,
            model: state.deviceName,
            platform: "macOS",
            estimatedTFLOPS: estimatedTFLOPS,
            availableMemoryGB: 16,
            thermalState: thermal,
            batteryLevel: battery,
            isCharging: state.isCharging,
            snapshotAt: state.updatedAt
        )
    }

    /// Build from DeviceCapacity peer (LoadBalancePolicy surface).
    public static func fromDeviceCapacity(
        _ cap: DeviceCapacity,
        estimatedTFLOPS: Double = 1.5
    ) -> BonhommeFleetDevice {
        let thermal = cap.capacity.thermal.map { BonhommeFleetThermal(host: $0) } ?? .nominal
        return BonhommeFleetDevice(
            deviceID: cap.deviceId,
            model: cap.displayName,
            platform: cap.platform,
            estimatedTFLOPS: estimatedTFLOPS,
            availableMemoryGB: 4,
            thermalState: thermal,
            batteryLevel: nil,
            isCharging: true,
            snapshotAt: cap.capacity.sampledAt
        )
    }
}

// MARK: Work chunks

/// GA-style work parameters for one fleet chunk (FlexAIDdS GAChunkParameters).
public struct BonhommeWorkParams: Sendable, Codable, Equatable {
    public let units: Int
    public let maxIterations: Int
    public let seed: Int
    public let temperature: Double

    public init(units: Int, maxIterations: Int, seed: Int, temperature: Double = 300.0) {
        self.units = max(0, units)
        self.maxIterations = max(0, maxIterations)
        self.seed = seed
        self.temperature = temperature
    }
}

/// One scheduled work unit claimed by a device.
public struct BonhommeWorkChunk: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let jobID: UUID
    public let index: Int
    public let totalChunks: Int
    public let claimedBy: String
    public let params: BonhommeWorkParams
    public let deviceModel: String

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        index: Int,
        totalChunks: Int,
        claimedBy: String,
        params: BonhommeWorkParams,
        deviceModel: String
    ) {
        self.id = id
        self.jobID = jobID
        self.index = index
        self.totalChunks = totalChunks
        self.claimedBy = claimedBy
        self.params = params
        self.deviceModel = deviceModel
    }
}

// MARK: Pure scheduler (FlexAIDdS FleetScheduler.splitWork)

/// Proportional work split across healthy fleet members.
///
/// Critical-thermal and zero-weight devices are excluded. The last active
/// device absorbs rounding so the sum of `params.units` equals `totalUnits`.
public enum BonhommeFleetScheduler: Sendable {

    /// Split `totalUnits` across available devices by compute weight.
    public static func splitWork(
        totalUnits: Int,
        maxIterations: Int = 100,
        temperature: Double = 300.0,
        devices: [BonhommeFleetDevice],
        jobID: UUID = UUID(),
        seedBase: Int = 42
    ) -> [BonhommeWorkChunk] {
        let total = max(0, totalUnits)
        let active = devices.filter(\.isAvailable)
        guard total > 0, !active.isEmpty else { return [] }

        let weights = active.map(\.computeWeight)
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return [] }

        var chunks: [BonhommeWorkChunk] = []
        var allocated = 0

        for (i, device) in active.enumerated() {
            let isLast = i == active.count - 1
            let share = weights[i] / totalWeight
            let units = isLast
                ? total - allocated
                : Int(Double(total) * share)
            guard units > 0 else { continue }

            let params = BonhommeWorkParams(
                units: units,
                maxIterations: maxIterations,
                seed: seedBase &+ i &* 17,
                temperature: temperature
            )
            chunks.append(
                BonhommeWorkChunk(
                    jobID: jobID,
                    index: chunks.count,
                    totalChunks: 0, // filled below
                    claimedBy: device.deviceID,
                    params: params,
                    deviceModel: device.model
                )
            )
            allocated += units
        }

        // Fix totalChunks now that we know the count.
        let n = chunks.count
        return chunks.enumerated().map { idx, c in
            BonhommeWorkChunk(
                id: c.id,
                jobID: c.jobID,
                index: idx,
                totalChunks: n,
                claimedBy: c.claimedBy,
                params: c.params,
                deviceModel: c.deviceModel
            )
        }
    }

    /// Membership: available devices only (excludes critical thermal / zero weight).
    public static func availableMembership(
        devices: [BonhommeFleetDevice]
    ) -> [BonhommeFleetDevice] {
        devices.filter(\.isAvailable)
    }

    /// Sum of scheduled units (should equal totalUnits when split succeeds).
    public static func totalScheduledUnits(_ chunks: [BonhommeWorkChunk]) -> Int {
        chunks.reduce(0) { $0 + $1.params.units }
    }
}

// MARK: Presence (NATURaL ClusterFleetPresence)

/// OS family for iCloud peer presence.
public enum BonhommeFleetPlatform: String, Sendable, Codable, CaseIterable, Equatable {
    case iOS
    case iPadOS
    case macOS
    case watchOS
    case tvOS
    case visionOS
    case unknown

    public var displayLabel: String { rawValue }
}

/// Heartbeat published per Apple device on the same iCloud account.
public struct BonhommeFleetPresence: Sendable, Codable, Equatable, Identifiable {
    public var id: String { deviceId }

    public var deviceId: String
    public var displayName: String
    public var platform: BonhommeFleetPlatform
    public var isActive: Bool
    public var updatedAt: Date
    public var schemaVersion: Int

    public static let currentSchemaVersion = 1
    /// Peers older than this are inactive (5 minutes) — NATURaL default.
    public static let defaultStaleInterval: TimeInterval = 300
    public static let kvsKeyPrefix = "shannon.fleet.presence."

    public init(
        deviceId: String,
        displayName: String,
        platform: BonhommeFleetPlatform,
        isActive: Bool = true,
        updatedAt: Date = Date(),
        schemaVersion: Int = BonhommeFleetPresence.currentSchemaVersion
    ) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.platform = platform
        self.isActive = isActive
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public func isStale(
        now: Date = Date(),
        interval: TimeInterval = BonhommeFleetPresence.defaultStaleInterval
    ) -> Bool {
        now.timeIntervalSince(updatedAt) > interval
    }

    public static func kvsKey(for deviceId: String) -> String {
        kvsKeyPrefix + deviceId
    }

    public static func deviceId(fromKVSKey key: String) -> String? {
        guard key.hasPrefix(kvsKeyPrefix) else { return nil }
        let id = String(key.dropFirst(kvsKeyPrefix.count))
        return id.isEmpty ? nil : id
    }
}

public enum BonhommeFleetPresenceCodec: Sendable {
    public static func encode(_ record: BonhommeFleetPresence) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(record)
    }

    public static func decode(_ data: Data) throws -> BonhommeFleetPresence {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(BonhommeFleetPresence.self, from: data)
    }

    public static func decodeAll(from keyValues: [String: Data]) -> [BonhommeFleetPresence] {
        var out: [BonhommeFleetPresence] = []
        for (key, data) in keyValues {
            guard key.hasPrefix(BonhommeFleetPresence.kvsKeyPrefix) else { continue }
            if let record = try? decode(data) { out.append(record) }
        }
        return out
    }

    /// Active, non-stale peers only.
    public static func activePeers(
        from records: [BonhommeFleetPresence],
        now: Date = Date(),
        staleInterval: TimeInterval = BonhommeFleetPresence.defaultStaleInterval
    ) -> [BonhommeFleetPresence] {
        records.filter { $0.isActive && !$0.isStale(now: now, interval: staleInterval) }
    }
}

public enum BonhommeFleetLocalIdentity: Sendable {
    public static let userDefaultsKey = "shannon.bonhommeFleet.deviceId"

    public static func stableDeviceId(stored: String?, persist: (String) -> Void) -> String {
        if let stored, !stored.isEmpty { return stored }
        let id = UUID().uuidString
        persist(id)
        return id
    }

    public static func defaultDisplayName(
        platform: BonhommeFleetPlatform,
        systemName: String?
    ) -> String {
        if let systemName, !systemName.isEmpty { return systemName }
        switch platform {
        case .iOS: return "iPhone"
        case .iPadOS: return "iPad"
        case .macOS: return "Mac"
        case .watchOS: return "Apple Watch"
        case .tvOS: return "Apple TV"
        case .visionOS: return "Vision"
        case .unknown: return "Apple Device"
        }
    }
}

// MARK: Mac hub snapshot (native Shannon path)

/// Fleet membership + optional schedule for the Mac hub / status surface.
public struct BonhommeFleetSnapshot: Sendable, Codable, Equatable {
    public let jobID: UUID?
    public let devices: [BonhommeFleetDevice]
    public let available: [BonhommeFleetDevice]
    public let chunks: [BonhommeWorkChunk]
    public let totalUnits: Int
    public let scheduledUnits: Int
    public let capturedAt: Date

    public var availableCount: Int { available.count }
    public var excludedCount: Int { devices.count - available.count }

    /// Operator one-liner for menu / CLI.
    public var statusLine: String {
        if devices.isEmpty {
            return "Fleet: no devices"
        }
        if available.isEmpty {
            return "Fleet: \(devices.count) device(s) — all excluded (thermal/battery)"
        }
        if chunks.isEmpty {
            return "Fleet: \(availableCount) available / \(devices.count) total (idle)"
        }
        return "Fleet: \(chunks.count) chunk(s) · \(scheduledUnits) units · \(availableCount)/\(devices.count) devices"
    }

    public init(
        jobID: UUID? = nil,
        devices: [BonhommeFleetDevice],
        chunks: [BonhommeWorkChunk] = [],
        totalUnits: Int = 0,
        capturedAt: Date = Date()
    ) {
        self.jobID = jobID
        self.devices = devices
        self.available = BonhommeFleetScheduler.availableMembership(devices: devices)
        self.chunks = chunks
        self.totalUnits = totalUnits
        self.scheduledUnits = BonhommeFleetScheduler.totalScheduledUnits(chunks)
        self.capturedAt = capturedAt
    }
}

/// Mac-native fleet hub: build membership from Mac + peers and schedule work.
public enum BonhommeFleetHub: Sendable {

    /// Assemble devices from the hub Mac state and optional peer capacities.
    public static func membership(
        local: MacDeviceState?,
        peers: [DeviceCapacity] = [],
        localTFLOPS: Double = 5.0,
        peerTFLOPS: Double = 1.5
    ) -> [BonhommeFleetDevice] {
        var devices: [BonhommeFleetDevice] = []
        if let local {
            devices.append(.fromMacDevice(local, estimatedTFLOPS: localTFLOPS))
        }
        for peer in peers {
            // Avoid double-counting if peer id matches local record name.
            if let local, peer.deviceId == local.recordName { continue }
            devices.append(.fromDeviceCapacity(peer, estimatedTFLOPS: peerTFLOPS))
        }
        return devices
    }

    /// Full snapshot: membership + proportional schedule.
    public static func schedule(
        local: MacDeviceState?,
        peers: [DeviceCapacity] = [],
        totalUnits: Int,
        maxIterations: Int = 100,
        temperature: Double = 300.0,
        localTFLOPS: Double = 5.0,
        peerTFLOPS: Double = 1.5,
        jobID: UUID = UUID(),
        seedBase: Int = 42
    ) -> BonhommeFleetSnapshot {
        let devices = membership(
            local: local,
            peers: peers,
            localTFLOPS: localTFLOPS,
            peerTFLOPS: peerTFLOPS
        )
        let chunks = BonhommeFleetScheduler.splitWork(
            totalUnits: totalUnits,
            maxIterations: maxIterations,
            temperature: temperature,
            devices: devices,
            jobID: jobID,
            seedBase: seedBase
        )
        return BonhommeFleetSnapshot(
            jobID: chunks.first?.jobID,
            devices: devices,
            chunks: chunks,
            totalUnits: totalUnits
        )
    }

    /// Presence → fleet device (default nominal thermal for active peers).
    public static func devices(
        fromPresence records: [BonhommeFleetPresence],
        now: Date = Date(),
        peerTFLOPS: Double = 1.5
    ) -> [BonhommeFleetDevice] {
        BonhommeFleetPresenceCodec.activePeers(from: records, now: now).map { p in
            BonhommeFleetDevice(
                deviceID: p.deviceId,
                model: p.displayName,
                platform: p.platform.rawValue,
                estimatedTFLOPS: peerTFLOPS,
                thermalState: .nominal,
                batteryLevel: nil,
                isCharging: true,
                snapshotAt: p.updatedAt
            )
        }
    }
}
