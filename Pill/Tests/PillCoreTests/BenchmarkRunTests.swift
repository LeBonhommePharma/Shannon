import XCTest
@testable import PillCore

/// Pure FlexAIDdS / gate `benchmark_state` surface — no invented success rates.
final class BenchmarkRunTests: XCTestCase {

    func testFromGateRowRequiresTaskId() {
        XCTAssertNil(BenchmarkRunSnapshot.fromGateRow(
            taskId: nil, completed: 1, total: 10,
            bestCF: nil, bestRMSD: nil, activeTarget: nil, updatedAtNs: 1
        ))
        XCTAssertNil(BenchmarkRunSnapshot.fromGateRow(
            taskId: "  ", completed: 1, total: 10,
            bestCF: nil, bestRMSD: nil, activeTarget: nil, updatedAtNs: 1
        ))
    }

    func testFromGateRowParsesProgressAndMetrics() {
        let run = BenchmarkRunSnapshot.fromGateRow(
            taskId: "benchmark_v133_astex85",
            completed: 34,
            total: 85,
            bestCF: -42.5,
            bestRMSD: 1.42,
            activeTarget: "1hpv",
            updatedAtNs: 1_700_000_000_000_000_000 // ns epoch-scale
        )
        XCTAssertNotNil(run)
        XCTAssertEqual(run?.completed, 34)
        XCTAssertEqual(run?.total, 85)
        XCTAssertEqual(run?.countLabel, "34/85")
        XCTAssertEqual(run?.fraction ?? 0, 34.0 / 85.0, accuracy: 1e-9)
        XCTAssertEqual(run?.bestRMSD ?? 0, 1.42, accuracy: 1e-9)
        XCTAssertEqual(run?.bestCF ?? 0, -42.5, accuracy: 1e-9)
        XCTAssertEqual(run?.activeTarget, "1hpv")
        XCTAssertFalse(run?.isComplete ?? true)
    }

    func testSecondsEpochAlsoAccepted() {
        let run = BenchmarkRunSnapshot.fromGateRow(
            taskId: "astex",
            completed: 1,
            total: 2,
            bestCF: nil,
            bestRMSD: nil,
            activeTarget: nil,
            updatedAtNs: 1_700_000_000 // seconds-scale
        )
        XCTAssertNotNil(run)
        XCTAssertEqual(run?.updatedAt.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1)
    }

    func testDisplayNameStripsBenchmarkPrefix() {
        let run = BenchmarkRunSnapshot(taskId: "benchmark_v133_astex85", completed: 1, total: 2)
        XCTAssertEqual(run.displayName, "v133 astex85")
    }

    func testShortLabelIncludesRMSDBadge() {
        let good = BenchmarkRunSnapshot(
            taskId: "astex", completed: 10, total: 85, bestRMSD: 1.5
        )
        XCTAssertTrue(good.shortLabel.contains("10/85"))
        XCTAssertTrue(good.shortLabel.contains("✓"))
        XCTAssertTrue(good.shortLabel.contains("1.50Å"))

        let far = BenchmarkRunSnapshot(
            taskId: "astex", completed: 10, total: 85, bestRMSD: 3.2
        )
        XCTAssertTrue(far.shortLabel.contains("•"))
        XCTAssertFalse(far.shortLabel.contains("✓"))
    }

    func testShortLabelFallsBackToCFWhenNoRMSD() {
        let run = BenchmarkRunSnapshot(
            taskId: "hap2", completed: 3, total: 10, bestCF: 12.345
        )
        XCTAssertTrue(run.shortLabel.contains("CF 12.345"))
    }

    func testIsComplete() {
        XCTAssertTrue(BenchmarkRunSnapshot(taskId: "x", completed: 85, total: 85).isComplete)
        XCTAssertFalse(BenchmarkRunSnapshot(taskId: "x", completed: 84, total: 85).isComplete)
        XCTAssertFalse(BenchmarkRunSnapshot(taskId: "x", completed: 5, total: 0).isComplete)
    }

    func testShouldShowCardFailClosed() {
        XCTAssertFalse(BenchmarkRunLogic.shouldShowCard(nil))
        let now = Date()
        let fresh = BenchmarkRunSnapshot(
            taskId: "astex", completed: 1, total: 10, updatedAt: now
        )
        XCTAssertTrue(BenchmarkRunLogic.shouldShowCard(fresh, now: now))
        let stale = BenchmarkRunSnapshot(
            taskId: "astex", completed: 1, total: 10,
            updatedAt: now.addingTimeInterval(-7 * 3600)
        )
        XCTAssertFalse(BenchmarkRunLogic.shouldShowCard(stale, now: now))
    }

    func testCollapsedTitleHonestAndFailClosed() {
        XCTAssertNil(BenchmarkRunLogic.collapsedTitle(nil))
        let now = Date()
        let running = BenchmarkRunSnapshot(
            taskId: "benchmark_astex85",
            completed: 12,
            total: 85,
            activeTarget: "1hpv",
            updatedAt: now
        )
        XCTAssertEqual(BenchmarkRunLogic.collapsedTitle(running), "12/85 · 1hpv")
        let done = BenchmarkRunSnapshot(
            taskId: "astex", completed: 85, total: 85, updatedAt: now
        )
        XCTAssertEqual(BenchmarkRunLogic.collapsedTitle(done), "Done 85/85")
        let stale = BenchmarkRunSnapshot(
            taskId: "astex", completed: 1, total: 10,
            updatedAt: now.addingTimeInterval(-3600)
        )
        // collapsedTitle uses default isStale (30m) — 1h is stale.
        XCTAssertNil(BenchmarkRunLogic.collapsedTitle(stale))
    }

    func testNoInventedSuccessRate() {
        // Surface never synthesizes % success from thin air — only completed/total
        // and optional best RMSD/CF from the gate row.
        let empty = BenchmarkRunSnapshot(taskId: "x", completed: 0, total: 0)
        XCTAssertEqual(empty.countLabel, "0/?")
        XCTAssertEqual(empty.fraction, 0)
        XCTAssertNil(empty.bestRMSD)
        XCTAssertNil(empty.bestCF)
        XCTAssertFalse(empty.shortLabel.contains("%"))
    }

    /// Gate load path must thread benchmark into FullSnapshot (structural binding).
    func testFullSnapshotCarriesBenchmark() {
        let run = BenchmarkRunSnapshot(taskId: "astex", completed: 2, total: 10)
        let full = AgentActivityReader.FullSnapshot(
            summary: AgentActivitySummary(),
            pendingAsks: [],
            staleAsks: [],
            activity: [],
            gateDBAvailable: true,
            agentEntropy: [],
            benchmark: run
        )
        XCTAssertEqual(full.benchmark?.taskId, "astex")
        XCTAssertEqual(full.benchmark?.countLabel, "2/10")
        let sig = full.renderSignature(at: Date())
        XCTAssertTrue(sig.contains("bench|astex|2/10"))
    }
}
