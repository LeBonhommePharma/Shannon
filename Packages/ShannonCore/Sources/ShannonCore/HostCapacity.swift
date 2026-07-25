import Foundation

// MARK: - Host capacity (shared Mac + iOS + iPad + watchOS)
//
// Pure models for multi-gauge host load: CPU / GPU / RAM / SSD / thermal.
// Ranking and multi-device load preference live here so companions and the
// Mac pill cannot drift. Samplers stay platform-specific.

/// Resource kinds Shannon ranks for "most constrained first".
public enum HostResourceKind: String, Sendable, Codable, CaseIterable, Comparable, Hashable {
    case cpu
    case gpu
    case ram
    case disk   // SSD / free space pressure (used %)
    case thermal

    public var shortLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ram: return "RAM"
        case .disk: return "SSD"
        case .thermal: return "Temp"
        }
    }

    public var systemImage: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "memorychip"
        case .ram: return "memorychip"
        case .disk: return "internaldrive"
        case .thermal: return "thermometer.medium"
        }
    }

    /// Tie-break when utilisation % is equal: thermal/disk before CPU.
    /// Higher = more severe class.
    public var severityRank: Int {
        switch self {
        case .thermal: return 5
        case .disk: return 4
        case .ram: return 3
        case .gpu: return 2
        case .cpu: return 1
        }
    }

    public static func < (lhs: HostResourceKind, rhs: HostResourceKind) -> Bool {
        lhs.severityRank < rhs.severityRank
    }
}

/// OS thermal pressure ladder (ProcessInfo.ThermalState raw values 0…3).
public enum HostThermalState: Int, Sendable, Codable, CaseIterable, Comparable, Hashable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }

    /// Map thermal ladder → utilisation-like pressure for ranking (0…100).
    /// Nominal contributes little so CPU/RAM still win when the machine is cool.
    public var pressurePercent: Double {
        switch self {
        case .nominal: return 8
        case .fair: return 45
        case .serious: return 78
        case .critical: return 97
        }
    }

    public static func < (lhs: HostThermalState, rhs: HostThermalState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func from(raw: Int?) -> HostThermalState? {
        guard let raw, let s = HostThermalState(rawValue: raw) else { return nil }
        return s
    }

    /// From ProcessInfo.ThermalState without importing UIKit/AppKit here.
    public static func fromProcessInfoRawValue(_ value: Int) -> HostThermalState {
        HostThermalState(rawValue: min(3, max(0, value))) ?? .nominal
    }
}

/// One constrained gauge row for HUD ordering.
public struct HostConstrainedResource: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var kind: HostResourceKind
    public var percent: Double

    public var id: String { kind.rawValue }

    public init(kind: HostResourceKind, percent: Double) {
        self.kind = kind
        self.percent = HostCapacityLogic.clampPct(percent) ?? 0
    }

    /// Compact label: `SSD 92%` / `Temp 97%`.
    public var shortLabel: String {
        if kind == .thermal {
            return String(format: "%@ %.0f%%", kind.shortLabel, percent)
        }
        return String(format: "%@ %.0f%%", kind.shortLabel, percent)
    }
}

/// Cross-platform host capacity snapshot (gauges only — no per-core arrays).
public struct HostCapacitySnapshot: Sendable, Equatable, Hashable, Codable {
    public var cpuPercent: Double?
    public var gpuPercent: Double?
    public var ramPercent: Double?
    /// Disk **used** percent (0…100). Free space = 100 − used when known.
    public var diskPercent: Double?
    public var diskUsedGB: Double?
    public var diskTotalGB: Double?
    public var diskFreeGB: Double?
    public var thermal: HostThermalState?
    /// Best-effort °C when a sensor is exposed; usually nil on public APIs.
    public var temperatureCelsius: Double?
    public var sampledAt: Date

    public init(
        cpuPercent: Double? = nil,
        gpuPercent: Double? = nil,
        ramPercent: Double? = nil,
        diskPercent: Double? = nil,
        diskUsedGB: Double? = nil,
        diskTotalGB: Double? = nil,
        diskFreeGB: Double? = nil,
        thermal: HostThermalState? = nil,
        temperatureCelsius: Double? = nil,
        sampledAt: Date = Date()
    ) {
        self.cpuPercent = HostCapacityLogic.clampPct(cpuPercent)
        self.gpuPercent = HostCapacityLogic.clampPct(gpuPercent)
        self.ramPercent = HostCapacityLogic.clampPct(ramPercent)
        self.diskPercent = HostCapacityLogic.clampPct(diskPercent)
        self.diskUsedGB = diskUsedGB.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.diskTotalGB = diskTotalGB.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.diskFreeGB = diskFreeGB.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.thermal = thermal
        self.temperatureCelsius = temperatureCelsius.flatMap {
            $0.isFinite && $0 > -50 && $0 < 150 ? $0 : nil
        }
        self.sampledAt = sampledAt
    }

    /// Pressure % used for thermal in ranking (nil when unknown).
    public var thermalPressurePercent: Double? {
        thermal.map(\.pressurePercent)
    }

    /// Most constrained first (highest pressure %, then severity rank).
    public var constrainedRanked: [HostConstrainedResource] {
        HostCapacityLogic.constrainedRanked(
            cpu: cpuPercent,
            gpu: gpuPercent,
            ram: ramPercent,
            disk: diskPercent,
            thermalPressure: thermalPressurePercent
        )
    }

    /// Single worst gauge, or nil when nothing measured.
    public var mostConstrained: HostConstrainedResource? {
        constrainedRanked.first
    }

    public var loadScore: Double {
        HostCapacityLogic.loadScore(from: constrainedRanked)
    }

    public func isStressed(warnAt: Double = 80) -> Bool {
        guard let c = mostConstrained else { return false }
        return c.percent >= warnAt
    }
}

// MARK: - Multi-device

/// One device's capacity for load-preference decisions.
public struct DeviceCapacity: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var deviceId: String
    public var displayName: String
    public var capacity: HostCapacitySnapshot
    /// Optional platform tag: macOS / iOS / iPadOS / watchOS.
    public var platform: String

    public var id: String { deviceId }

    public init(
        deviceId: String,
        displayName: String,
        capacity: HostCapacitySnapshot,
        platform: String = "macOS"
    ) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.capacity = capacity
        self.platform = platform
    }

    public var loadScore: Double { capacity.loadScore }
}

/// Prefer healthier devices for concurrent benchmarking / heavy work.
public enum LoadBalancePolicy {
    /// Pick the least constrained peer. Returns nil when empty.
    /// Devices at/over `busyThreshold` are skipped when a healthier peer exists;
    /// if all are busy, returns the least bad (caller may still `shouldDefer`).
    public static func preferredDevice(
        among devices: [DeviceCapacity],
        busyThreshold: Double = 85
    ) -> DeviceCapacity? {
        guard !devices.isEmpty else { return nil }
        let sorted = devices.sorted { a, b in
            if a.loadScore != b.loadScore { return a.loadScore < b.loadScore }
            return a.deviceId < b.deviceId
        }
        if let healthy = sorted.first(where: { $0.loadScore < busyThreshold }) {
            return healthy
        }
        return sorted.first
    }

    /// True when this host is too constrained to start more heavy work.
    public static func shouldDeferWork(
        on device: DeviceCapacity,
        threshold: Double = 90
    ) -> Bool {
        device.loadScore >= threshold
    }

    /// Given local + peers, should local start a new heavy arm?
    public static func shouldRunLocally(
        local: DeviceCapacity,
        peers: [DeviceCapacity],
        busyThreshold: Double = 85,
        deferThreshold: Double = 90
    ) -> Bool {
        if shouldDeferWork(on: local, threshold: deferThreshold) {
            // Only run if every peer is as bad or worse.
            let all = peers + [local]
            guard let best = preferredDevice(among: all, busyThreshold: busyThreshold)
            else { return false }
            return best.deviceId == local.deviceId
        }
        if peers.isEmpty { return true }
        guard let best = preferredDevice(
            among: peers + [local],
            busyThreshold: busyThreshold
        ) else { return true }
        return best.deviceId == local.deviceId
    }
}

// MARK: - Pure logic

public enum HostCapacityLogic {
    public static func clampPct(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return min(100, max(0, v))
    }

    /// Disk used % from used/total bytes or GB (units cancel).
    public static func diskUsedPercent(used: Double, total: Double) -> Double? {
        guard used.isFinite, total.isFinite, total > 0, used >= 0 else { return nil }
        return min(100, max(0, (used / total) * 100))
    }

    public static func diskFreeGB(used: Double?, total: Double?) -> Double? {
        guard let used, let total, used.isFinite, total.isFinite, total > 0 else { return nil }
        return max(0, total - used)
    }

    /// Rank gauges: highest pressure first; ties → higher severityRank first.
    public static func constrainedRanked(
        cpu: Double?,
        gpu: Double?,
        ram: Double?,
        disk: Double?,
        thermalPressure: Double?
    ) -> [HostConstrainedResource] {
        var rows: [HostConstrainedResource] = []
        func add(_ kind: HostResourceKind, _ pct: Double?) {
            guard let p = clampPct(pct) else { return }
            rows.append(HostConstrainedResource(kind: kind, percent: p))
        }
        add(.cpu, cpu)
        add(.gpu, gpu)
        add(.ram, ram)
        add(.disk, disk)
        add(.thermal, thermalPressure)
        rows.sort { a, b in
            if a.percent != b.percent { return a.percent > b.percent }
            return a.kind.severityRank > b.kind.severityRank
        }
        return rows
    }

    public static func mostConstrained(
        cpu: Double?,
        gpu: Double?,
        ram: Double?,
        disk: Double? = nil,
        thermalPressure: Double? = nil
    ) -> HostConstrainedResource? {
        constrainedRanked(
            cpu: cpu, gpu: gpu, ram: ram, disk: disk, thermalPressure: thermalPressure
        ).first
    }

    /// Single 0…100 score for multi-device comparison (max pressure among gauges).
    public static func loadScore(from ranked: [HostConstrainedResource]) -> Double {
        ranked.first?.percent ?? 0
    }

    public static func loadScore(
        cpu: Double?,
        gpu: Double?,
        ram: Double?,
        disk: Double?,
        thermalPressure: Double?
    ) -> Double {
        loadScore(from: constrainedRanked(
            cpu: cpu, gpu: gpu, ram: ram, disk: disk, thermalPressure: thermalPressure
        ))
    }

    public enum Band: String, Sendable {
        case calm, elevated, hot, critical
    }

    public static func band(for percent: Double) -> Band {
        if percent >= 92 { return .critical }
        if percent >= 80 { return .hot }
        if percent >= 60 { return .elevated }
        return .calm
    }
}
