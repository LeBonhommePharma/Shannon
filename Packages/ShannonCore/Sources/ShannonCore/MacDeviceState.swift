import Foundation

/// Mac battery + host identity, mirrored to the phone and watch.
public struct MacDeviceState: CloudSyncable, Codable, Hashable {
    public var deviceName: String
    public var batteryPercent: Int
    public var isCharging: Bool
    /// Minutes to full when charging, to empty when discharging. Nil while
    /// macOS is still calculating.
    public var minutesRemaining: Int?
    public var updatedAt: Date

    public init(
        deviceName: String,
        batteryPercent: Int,
        isCharging: Bool,
        minutesRemaining: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.deviceName = deviceName
        self.batteryPercent = min(max(batteryPercent, 0), 100)
        self.isCharging = isCharging
        self.minutesRemaining = minutesRemaining
        self.updatedAt = updatedAt
    }

    public var fillFraction: Double { Double(batteryPercent) / 100.0 }

    /// "82% ⚡" / "34%"
    public var batteryLabel: String {
        isCharging ? "\(batteryPercent)% ⚡" : "\(batteryPercent)%"
    }

    /// True when the Mac has stopped publishing — the phone shows a stale
    /// banner rather than pretending a two-hour-old snapshot is live.
    public func isStale(now: Date = Date(), tolerance: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(updatedAt) > tolerance
    }

    // MARK: CloudSyncable

    public static let recordType = "MacDeviceState"
    public var recordName: String { "device-\(deviceName)" }

    enum Field {
        static let batteryPercent = "batteryPercent"
        static let isCharging = "isCharging"
        static let minutesRemaining = "minutesRemaining"
    }

    public var cloudFields: CloudFields {
        var f: CloudFields = [
            CloudKeys.deviceName: .string(deviceName),
            Field.batteryPercent: .int(batteryPercent),
            Field.isCharging: .bool(isCharging),
            CloudKeys.updatedAt: .date(updatedAt),
        ]
        if let minutesRemaining { f[Field.minutesRemaining] = .int(minutesRemaining) }
        return f
    }

    public init(cloudFields f: CloudFields) throws {
        self.init(
            deviceName: try f.string(CloudKeys.deviceName),
            batteryPercent: try f.int(Field.batteryPercent),
            isCharging: try f.bool(Field.isCharging),
            minutesRemaining: try f.optionalInt(Field.minutesRemaining),
            updatedAt: try f.date(CloudKeys.updatedAt)
        )
    }
}

/// One mirrored Mac notification. Bodies are truncated at the source: this
/// crosses iCloud, and a full message body is more than the phone needs to
/// decide whether to walk back to the desk.
public struct NotificationMirror: CloudSyncable, Codable, Identifiable, Hashable {
    public var id: String
    /// App or agent that posted it, e.g. "Messages" or "FlexAID∆S".
    public var sender: String
    public var title: String
    /// Already truncated to `maxBodyLength`.
    public var body: String
    public var postedAt: Date

    public static let maxBodyLength = 140

    public init(
        id: String = UUID().uuidString,
        sender: String,
        title: String,
        body: String,
        postedAt: Date = Date()
    ) {
        self.id = id
        self.sender = sender
        self.title = title
        self.body = Self.truncate(body)
        self.postedAt = postedAt
    }

    public static func truncate(_ text: String, limit: Int = maxBodyLength) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(limit - 1, 1))) + "…"
    }

    // MARK: CloudSyncable

    public static let recordType = "NotificationMirror"
    public var recordName: String { "notification-\(id)" }

    enum Field {
        static let id = "notificationID"
        static let sender = "sender"
        static let title = "title"
        static let body = "body"
        static let postedAt = "postedAt"
    }

    public var cloudFields: CloudFields {
        [
            Field.id: .string(id),
            Field.sender: .string(sender),
            Field.title: .string(title),
            Field.body: .string(body),
            Field.postedAt: .date(postedAt),
            CloudKeys.updatedAt: .date(postedAt),
        ]
    }

    public init(cloudFields f: CloudFields) throws {
        self.init(
            id: try f.string(Field.id),
            sender: try f.string(Field.sender),
            title: try f.string(Field.title),
            body: try f.string(Field.body),
            postedAt: try f.date(Field.postedAt)
        )
    }
}

/// A countdown started on the Mac, synced so it can also ring on the phone
/// and watch. Only the deadline is synced — each device counts down locally
/// rather than the Mac pushing a tick every second.
public struct TimerState: CloudSyncable, Codable, Identifiable, Hashable {
    public var id: String
    public var label: String
    public var fireAt: Date
    public var isPaused: Bool
    /// Remaining seconds frozen at the moment of pausing; ignored while running.
    public var pausedRemaining: Double?
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        label: String,
        fireAt: Date,
        isPaused: Bool = false,
        pausedRemaining: Double? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.fireAt = fireAt
        self.isPaused = isPaused
        self.pausedRemaining = pausedRemaining
        self.updatedAt = updatedAt
    }

    /// Seconds left, never negative. A paused timer reports its frozen value.
    public func remaining(now: Date = Date()) -> Double {
        if isPaused { return max(pausedRemaining ?? 0, 0) }
        return max(fireAt.timeIntervalSince(now), 0)
    }

    public func hasFired(now: Date = Date()) -> Bool {
        !isPaused && now >= fireAt
    }

    /// "12:05" / "1:02:05"
    public func remainingLabel(now: Date = Date()) -> String {
        let total = Int(remaining(now: now).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: CloudSyncable

    public static let recordType = "TimerState"
    public var recordName: String { "timer-\(id)" }

    enum Field {
        static let id = "timerID"
        static let label = "label"
        static let fireAt = "fireAt"
        static let isPaused = "isPaused"
        static let pausedRemaining = "pausedRemaining"
    }

    public var cloudFields: CloudFields {
        var f: CloudFields = [
            Field.id: .string(id),
            Field.label: .string(label),
            Field.fireAt: .date(fireAt),
            Field.isPaused: .bool(isPaused),
            CloudKeys.updatedAt: .date(updatedAt),
        ]
        if let pausedRemaining { f[Field.pausedRemaining] = .double(pausedRemaining) }
        return f
    }

    public init(cloudFields f: CloudFields) throws {
        self.init(
            id: try f.string(Field.id),
            label: try f.string(Field.label),
            fireAt: try f.date(Field.fireAt),
            isPaused: try f.bool(Field.isPaused),
            pausedRemaining: try f.optionalDouble(Field.pausedRemaining),
            updatedAt: try f.date(CloudKeys.updatedAt)
        )
    }
}
