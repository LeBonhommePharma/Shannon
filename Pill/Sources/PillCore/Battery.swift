import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

/// Keys published by IOKit in each power-source description dictionary.
/// Declared as literals so the parsing logic can be exercised without IOKit.
public enum PowerSourceKey {
    public static let currentCapacity = "Current Capacity"
    public static let maxCapacity = "Max Capacity"
    public static let isCharging = "Is Charging"
    public static let isPresent = "Is Present"
    public static let timeToFull = "Time to Full Charge"
    public static let timeToEmpty = "Time to Empty"
    public static let powerSourceState = "Power Source State"
    public static let name = "Name"
}

/// IOKit reports `-1` for a time estimate it has not settled on yet.
public let kTimeEstimateCalculating = -1

public enum BatteryAlertLevel: String, Sendable, Equatable {
    case normal
    case low       // <= 20%
    case critical  // <= 10%
}

public struct BatterySnapshot: Sendable, Equatable {
    public let name: String
    public let percentage: Int
    public let isCharging: Bool
    public let isPresent: Bool
    /// Minutes until full, or nil when discharging / still calculating.
    public let minutesToFull: Int?
    /// Minutes until empty, or nil when charging / still calculating.
    public let minutesToEmpty: Int?

    public init(
        name: String = "InternalBattery",
        percentage: Int,
        isCharging: Bool,
        isPresent: Bool = true,
        minutesToFull: Int? = nil,
        minutesToEmpty: Int? = nil
    ) {
        self.name = name
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPresent = isPresent
        self.minutesToFull = minutesToFull
        self.minutesToEmpty = minutesToEmpty
    }

    /// Alert level drives the ring pulse. Charging never reads as an alert —
    /// a battery on the cable at 8% is recovering, not in trouble.
    public var alertLevel: BatteryAlertLevel {
        guard isPresent, !isCharging else { return .normal }
        if percentage <= 10 { return .critical }
        if percentage <= 20 { return .low }
        return .normal
    }

    public var isFull: Bool { percentage >= 100 }

    /// 0.0...1.0 fill for the ring.
    public var fillFraction: Double {
        Double(min(max(percentage, 0), 100)) / 100.0
    }

    /// "1:20 to full" / "3:05 left" / "Calculating…" / "Charged".
    public var timeLabel: String {
        if isCharging {
            if isFull { return "Charged" }
            guard let m = minutesToFull else { return "Calculating…" }
            return "\(Self.formatMinutes(m)) to full"
        }
        guard let m = minutesToEmpty else { return "Calculating…" }
        return "\(Self.formatMinutes(m)) left"
    }

    public static func formatMinutes(_ total: Int) -> String {
        let clamped = max(total, 0)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    /// Parse one IOKit power-source description. Returns nil when the
    /// dictionary is missing the capacity fields entirely.
    public init?(powerSourceDescription d: [String: Any]) {
        guard let current = d[PowerSourceKey.currentCapacity] as? Int,
              let maxCap = d[PowerSourceKey.maxCapacity] as? Int,
              maxCap > 0
        else { return nil }

        let charging = (d[PowerSourceKey.isCharging] as? Bool)
            ?? (d[PowerSourceKey.powerSourceState] as? String == "AC Power")

        // Capacity is reported in device units, not always percent.
        let pct = Int((Double(current) / Double(maxCap) * 100.0).rounded())

        func estimate(_ key: String) -> Int? {
            guard let v = d[key] as? Int, v != kTimeEstimateCalculating, v > 0 else { return nil }
            return v
        }

        self.init(
            name: (d[PowerSourceKey.name] as? String) ?? "Battery",
            percentage: min(max(pct, 0), 100),
            isCharging: charging,
            isPresent: (d[PowerSourceKey.isPresent] as? Bool) ?? true,
            minutesToFull: charging ? estimate(PowerSourceKey.timeToFull) : nil,
            minutesToEmpty: charging ? nil : estimate(PowerSourceKey.timeToEmpty)
        )
    }
}

/// Tracks snapshots over time and decides when a one-shot alert should fire.
/// Kept separate from the IOKit polling so the edge-triggering is testable.
public struct BatteryAlertTracker: Sendable {
    private var lastLevel: BatteryAlertLevel = .normal
    private var announcedFull = false

    public init() {}

    public enum Alert: Equatable, Sendable {
        case reachedFull(String)
        case enteredLow(Int)
        case enteredCritical(Int)
    }

    /// Feed each snapshot; returns an alert only on the transition edge,
    /// so a battery sitting at 15% does not re-alert on every poll.
    public mutating func consume(_ s: BatterySnapshot) -> Alert? {
        guard s.isPresent else { return nil }

        if s.isFull && s.isCharging {
            if !announcedFull {
                announcedFull = true
                lastLevel = s.alertLevel
                return .reachedFull(s.name)
            }
        } else if s.percentage < 95 {
            // Re-arm once it has meaningfully drained.
            announcedFull = false
        }

        let level = s.alertLevel
        defer { lastLevel = level }
        guard level != lastLevel else { return nil }
        switch level {
        case .critical: return .enteredCritical(s.percentage)
        case .low:      return lastLevel == .critical ? nil : .enteredLow(s.percentage)
        case .normal:   return nil
        }
    }
}

public protocol BatteryProviding: AnyObject {
    func currentSnapshots() -> [BatterySnapshot]
}

#if canImport(IOKit)
/// Live IOKit-backed provider (IOPSCopyPowerSourcesInfo).
public final class IOKitBatteryProvider: BatteryProviding {
    public init() {}

    public func currentSnapshots() -> [BatterySnapshot] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }

        return sources.compactMap { src in
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?
                .takeUnretainedValue() as? [String: Any] else { return nil }
            return BatterySnapshot(powerSourceDescription: desc)
        }
    }
}
#endif

/// Polls a provider on an interval and publishes the internal battery.
@MainActor
public final class BatteryMonitor: ObservableObject {
    @Published public private(set) var snapshot: BatterySnapshot?
    @Published public private(set) var lastAlert: BatteryAlertTracker.Alert?

    private let provider: BatteryProviding
    private var tracker = BatteryAlertTracker()
    private var timer: Timer?
    private let interval: TimeInterval

    public init(provider: BatteryProviding, interval: TimeInterval = 15) {
        self.provider = provider
        self.interval = interval
    }

    public func start() {
        poll()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func poll() {
        let all = provider.currentSnapshots()
        guard let internalBattery = all.first(where: { $0.isPresent }) ?? all.first else {
            snapshot = nil
            return
        }
        snapshot = internalBattery
        if let alert = tracker.consume(internalBattery) {
            lastAlert = alert
        }
    }
}
