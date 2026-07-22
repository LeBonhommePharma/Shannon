import Foundation

/// FlexAID∆S benchmark progress. One record per active benchmark run.
public struct DockingProgress: CloudSyncable, Codable, Identifiable, Hashable {
    /// Benchmark identifier, e.g. "astex-diverse".
    public var id: String
    /// Display name, e.g. "Astex Diverse".
    public var benchmarkName: String
    public var targetsComplete: Int
    public var targetsTotal: Int
    /// Target currently being docked, e.g. "1of6".
    public var currentTarget: String
    /// Best RMSD in Ångström across completed targets. Nil before the first result.
    public var bestRMSD: Double?
    /// Fraction of completed targets under the 2.0 Å success cutoff.
    public var successRate: Double?
    /// Estimated seconds remaining, published by the Mac. Nil while unknown.
    public var etaSeconds: Double?
    public var isRunning: Bool
    public var updatedAt: Date

    /// Conventional docking success cutoff.
    public static let rmsdSuccessCutoff = 2.0

    public init(
        id: String,
        benchmarkName: String,
        targetsComplete: Int,
        targetsTotal: Int,
        currentTarget: String = "",
        bestRMSD: Double? = nil,
        successRate: Double? = nil,
        etaSeconds: Double? = nil,
        isRunning: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.benchmarkName = benchmarkName
        self.targetsComplete = targetsComplete
        self.targetsTotal = targetsTotal
        self.currentTarget = currentTarget
        self.bestRMSD = bestRMSD
        self.successRate = successRate
        self.etaSeconds = etaSeconds
        self.isRunning = isRunning
        self.updatedAt = updatedAt
    }

    /// 0.0...1.0 for the progress ring. A zero total reads as 0, not NaN.
    public var fraction: Double {
        guard targetsTotal > 0 else { return 0 }
        return min(max(Double(targetsComplete) / Double(targetsTotal), 0), 1)
    }

    public var isComplete: Bool { targetsTotal > 0 && targetsComplete >= targetsTotal }

    /// "34/85"
    public var countLabel: String { "\(targetsComplete)/\(targetsTotal)" }

    /// "1h 12m" / "4m" / nil when the Mac has not estimated yet.
    public var etaLabel: String? {
        guard let eta = etaSeconds, eta.isFinite, eta > 0 else { return nil }
        let total = Int(eta.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    /// Complication line: "34/85 ✓ 1.42Å".
    public func complicationLine() -> String {
        var parts = [countLabel]
        if let r = bestRMSD {
            let mark = r <= Self.rmsdSuccessCutoff ? "✓" : "•"
            parts.append("\(mark) \(String(format: "%.2f", r))Å")
        }
        return parts.joined(separator: " ")
    }

    // MARK: CloudSyncable

    public static let recordType = "DockingProgress"
    public var recordName: String { "docking-\(id)" }

    enum Field {
        static let id = "benchmarkID"
        static let benchmarkName = "benchmarkName"
        static let targetsComplete = "targetsComplete"
        static let targetsTotal = "targetsTotal"
        static let currentTarget = "currentTarget"
        static let bestRMSD = "bestRMSD"
        static let successRate = "successRate"
        static let etaSeconds = "etaSeconds"
        static let isRunning = "isRunning"
    }

    public var cloudFields: CloudFields {
        var f: CloudFields = [
            Field.id: .string(id),
            Field.benchmarkName: .string(benchmarkName),
            Field.targetsComplete: .int(targetsComplete),
            Field.targetsTotal: .int(targetsTotal),
            Field.currentTarget: .string(currentTarget),
            Field.isRunning: .bool(isRunning),
            CloudKeys.updatedAt: .date(updatedAt),
        ]
        if let bestRMSD { f[Field.bestRMSD] = .double(bestRMSD) }
        if let successRate { f[Field.successRate] = .double(successRate) }
        if let etaSeconds { f[Field.etaSeconds] = .double(etaSeconds) }
        return f
    }

    public init(cloudFields f: CloudFields) throws {
        self.init(
            id: try f.string(Field.id),
            benchmarkName: try f.string(Field.benchmarkName),
            targetsComplete: try f.int(Field.targetsComplete),
            targetsTotal: try f.int(Field.targetsTotal),
            currentTarget: try f.string(Field.currentTarget),
            bestRMSD: try f.optionalDouble(Field.bestRMSD),
            successRate: try f.optionalDouble(Field.successRate),
            etaSeconds: try f.optionalDouble(Field.etaSeconds),
            isRunning: try f.bool(Field.isRunning),
            updatedAt: try f.date(CloudKeys.updatedAt)
        )
    }
}

/// Edge-triggered alerts for the phone and watch haptics. Kept as a pure
/// reducer so "did a target just finish?" is testable without CloudKit.
public struct DockingAlertTracker: Sendable {
    private var lastComplete: [String: Int] = [:]
    private var announcedFinish: Set<String> = []

    public init() {}

    public enum Alert: Equatable, Sendable {
        case targetCompleted(benchmark: String, completed: Int, total: Int)
        case benchmarkFinished(benchmark: String)
    }

    /// Feed each snapshot; returns at most one alert per transition. A run that
    /// jumps several targets between syncs reports the finish, not each step.
    public mutating func consume(_ p: DockingProgress) -> Alert? {
        defer { lastComplete[p.id] = p.targetsComplete }

        if p.isComplete {
            guard !announcedFinish.contains(p.id) else { return nil }
            announcedFinish.insert(p.id)
            return .benchmarkFinished(benchmark: p.benchmarkName)
        }
        // A restarted benchmark re-arms the finish alert.
        announcedFinish.remove(p.id)

        guard let previous = lastComplete[p.id] else { return nil }
        guard p.targetsComplete > previous else { return nil }
        return .targetCompleted(
            benchmark: p.benchmarkName,
            completed: p.targetsComplete,
            total: p.targetsTotal
        )
    }
}
