import Foundation

// MARK: - FlexAIDdS / hub benchmark progress (pure)

/// Latest row from gate `benchmark_state` — shared DatasetRunner progress.
///
/// Pure value for the menubar + pill hub surface. No I/O; fail-closed when
/// absent. Success-rate science stays in FlexAIDdS; we only display what the
/// hub recorded (completed/total, best CF/RMSD, active target).
public struct BenchmarkRunSnapshot: Sendable, Equatable, Identifiable {
    public var id: String { taskId }
    public var taskId: String
    public var completed: Int
    public var total: Int
    public var bestCF: Double?
    public var bestRMSD: Double?
    public var activeTarget: String?
    public var updatedAt: Date

    /// Conventional docking success cutoff (Å) — for badge colour only.
    public static let rmsdSuccessCutoff: Double = 2.0

    public init(
        taskId: String,
        completed: Int = 0,
        total: Int = 0,
        bestCF: Double? = nil,
        bestRMSD: Double? = nil,
        activeTarget: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.taskId = taskId
        self.completed = max(0, completed)
        self.total = max(0, total)
        self.bestCF = bestCF.flatMap { $0.isFinite ? $0 : nil }
        self.bestRMSD = bestRMSD.flatMap { $0.isFinite ? $0 : nil }
        self.activeTarget = activeTarget.flatMap {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        self.updatedAt = updatedAt
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    public var isComplete: Bool { total > 0 && completed >= total }

    /// "34/85"
    public var countLabel: String {
        if total <= 0 { return "\(completed)/?" }
        return "\(completed)/\(total)"
    }

    /// Short hub line: "Astex · 34/85 · 1.42Å" or task_id slug.
    public var shortLabel: String {
        var parts: [String] = [displayName, countLabel]
        if let r = bestRMSD {
            let mark = r <= Self.rmsdSuccessCutoff ? "✓" : "•"
            parts.append("\(mark)\(String(format: "%.2f", r))Å")
        } else if let cf = bestCF {
            parts.append(String(format: "CF %.3f", cf))
        }
        return parts.joined(separator: " · ")
    }

    /// Human label from task_id (e.g. benchmark_v133_astex85 → astex85).
    public var displayName: String {
        let raw = taskId
            .replacingOccurrences(of: "benchmark_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return "Benchmark" }
        if raw.count > 28 { return String(raw.prefix(26)) + "…" }
        return raw
    }

    public var age: TimeInterval { Date().timeIntervalSince(updatedAt) }

    public func isStale(now: Date = Date(), maxAge: TimeInterval = 30 * 60) -> Bool {
        now.timeIntervalSince(updatedAt) > maxAge
    }

    /// Pure parser from gate SQL row fields (unit-tested).
    public static func fromGateRow(
        taskId: String?,
        completed: Int?,
        total: Int?,
        bestCF: Double?,
        bestRMSD: Double?,
        activeTarget: String?,
        updatedAtNs: Int64?
    ) -> BenchmarkRunSnapshot? {
        let tid = (taskId ?? "").trimmingCharacters(in: .whitespaces)
        guard !tid.isEmpty else { return nil }
        let updated: Date
        if let ns = updatedAtNs, ns > 0 {
            // Nanoseconds or seconds?
            let secs = ns > 1_000_000_000_000 ? Double(ns) / 1e9 : Double(ns)
            updated = Date(timeIntervalSince1970: secs)
        } else {
            updated = Date()
        }
        return BenchmarkRunSnapshot(
            taskId: tid,
            completed: completed ?? 0,
            total: total ?? 0,
            bestCF: bestCF,
            bestRMSD: bestRMSD,
            activeTarget: activeTarget,
            updatedAt: updated
        )
    }
}

// MARK: - Pure formatting helpers

public enum BenchmarkRunLogic {
    /// Collapsed-pill / menu-bar title when a run is live.
    public static func collapsedTitle(_ run: BenchmarkRunSnapshot?) -> String? {
        guard let run, !run.isStale() else { return nil }
        if run.isComplete { return "Done \(run.countLabel)" }
        if let t = run.activeTarget {
            return "\(run.countLabel) · \(t)"
        }
        return run.countLabel
    }

    /// Whether the hub surface should show the benchmark card.
    public static func shouldShowCard(_ run: BenchmarkRunSnapshot?, now: Date = Date()) -> Bool {
        guard let run else { return false }
        return !run.isStale(now: now, maxAge: 6 * 3600)
    }
}
