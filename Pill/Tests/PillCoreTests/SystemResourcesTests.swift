import XCTest
@testable import PillCore

final class SystemResourcesTests: XCTestCase {

    func testRamPercentMath() {
        XCTAssertEqual(SystemResourceLogic.ramPercent(used: 8, total: 16)!, 50, accuracy: 1e-9)
        XCTAssertEqual(SystemResourceLogic.ramPercent(used: 16, total: 16)!, 100, accuracy: 1e-9)
        XCTAssertEqual(SystemResourceLogic.ramPercent(used: 0, total: 32)!, 0, accuracy: 1e-9)
        XCTAssertNil(SystemResourceLogic.ramPercent(used: 1, total: 0))
        XCTAssertNil(SystemResourceLogic.ramPercent(used: -1, total: 8))
        XCTAssertNil(SystemResourceLogic.ramPercent(used: .nan, total: 8))
    }

    func testMostConstrainedPicksHighest() {
        let c = SystemResourceLogic.mostConstrained(cpu: 40, gpu: 90, ram: 55)
        XCTAssertEqual(c?.kind, .gpu)
        XCTAssertEqual(c?.percent ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(c?.shortLabel, "GPU 90%")
    }

    func testMostConstrainedIgnoresNil() {
        let c = SystemResourceLogic.mostConstrained(cpu: 70, gpu: nil, ram: 20)
        XCTAssertEqual(c?.kind, .cpu)
        XCTAssertEqual(c?.shortLabel, "CPU 70%")
    }

    func testMostConstrainedAllNil() {
        XCTAssertNil(SystemResourceLogic.mostConstrained(cpu: nil, gpu: nil, ram: nil))
    }

    func testMostConstrainedRamOverCpu() {
        let c = SystemResourceLogic.mostConstrained(cpu: 40, gpu: nil, ram: 95)
        XCTAssertEqual(c?.kind, .ram)
        XCTAssertEqual(c?.percent ?? 0, 95, accuracy: 1e-9)
    }

    func testMostConstrainedDiskAndThermalRanked() {
        let ranked = SystemResourceLogic.constrainedRanked(
            cpu: 30, gpu: 20, ram: 40, disk: 98, thermalPressure: 8
        )
        XCTAssertEqual(ranked.first?.kind, .disk)
        XCTAssertEqual(ranked.map(\.kind).prefix(2).map(\.rawValue), ["disk", "ram"])
    }

    func testThermalCriticalBeatsDiskOnTie() {
        let ranked = SystemResourceLogic.constrainedRanked(
            cpu: 10, gpu: nil, ram: 10, disk: 97, thermalPressure: 97
        )
        XCTAssertEqual(ranked.first?.kind, .thermal)
    }

    func testSnapshotIncludesDiskThermalInMostConstrained() {
        let snap = SystemResourceSnapshot(
            cpuPercent: 40,
            ramPercent: 50,
            diskPercent: 93,
            thermal: .fair
        )
        XCTAssertEqual(snap.mostConstrained?.kind, .disk)
        XCTAssertEqual(snap.constrainedRanked.first?.kind, .disk)
        XCTAssertEqual(snap.hostCapacity.diskPercent!, 93, accuracy: 1e-9)
    }

    func testHistoryTracksDisk() {
        var h = SystemResourceHistory(capacity: 3)
        h.append(SystemResourceSnapshot(diskPercent: 10))
        h.append(SystemResourceSnapshot(diskPercent: 20))
        h.append(SystemResourceSnapshot(diskPercent: 30))
        h.append(SystemResourceSnapshot(diskPercent: 40))
        XCTAssertEqual(h.disk, [20, 30, 40])
    }

    func testBands() {
        XCTAssertEqual(SystemResourceLogic.band(for: 10), .calm)
        XCTAssertEqual(SystemResourceLogic.band(for: 65), .elevated)
        XCTAssertEqual(SystemResourceLogic.band(for: 85), .hot)
        XCTAssertEqual(SystemResourceLogic.band(for: 95), .critical)
    }

    func testSnapshotClamps() {
        let s = SystemResourceSnapshot(cpuPercent: 150, gpuPercent: -5, ramPercent: 50)
        XCTAssertEqual(s.cpuPercent!, 100, accuracy: 1e-9)
        XCTAssertEqual(s.gpuPercent!, 0, accuracy: 1e-9)
        XCTAssertEqual(s.ramPercent!, 50, accuracy: 1e-9)
    }

    func testIsStressed() {
        let calm = SystemResourceSnapshot(cpuPercent: 20, ramPercent: 30)
        XCTAssertFalse(calm.isStressed())
        let hot = SystemResourceSnapshot(cpuPercent: 88)
        XCTAssertTrue(hot.isStressed())
    }

    // MARK: Per-core relative performance

    func testAnnotateCoresRanksAndDeltas() {
        // Core 2 hottest, core 0 coolest. Average = 40.
        let cores = SystemResourceLogic.annotateCores([10, 40, 70])
        XCTAssertEqual(cores.count, 3)
        XCTAssertEqual(cores[0].index, 0)
        XCTAssertEqual(cores[0].percent, 10, accuracy: 1e-9)
        XCTAssertEqual(cores[0].deltaVsAverage, -30, accuracy: 1e-9)
        XCTAssertEqual(cores[0].rank, 3)

        XCTAssertEqual(cores[2].percent, 70, accuracy: 1e-9)
        XCTAssertEqual(cores[2].deltaVsAverage, 30, accuracy: 1e-9)
        XCTAssertEqual(cores[2].rank, 1)
        XCTAssertEqual(cores[2].relativeToAverage!, 70.0 / 40.0, accuracy: 1e-9)
        XCTAssertTrue(cores[2].isBusiest)
        XCTAssertTrue(cores[2].isHotRelative)
        XCTAssertFalse(cores[0].isHotRelative)
    }

    func testAnnotateCoresTieBreakByIndex() {
        let cores = SystemResourceLogic.annotateCores([50, 50, 50])
        // All equal load → rank by lower index first among ties in sort,
        // so index 0 is rank 1, index 1 is 2, index 2 is 3.
        XCTAssertEqual(cores.map(\.rank), [1, 2, 3])
        XCTAssertEqual(cores[0].deltaVsAverage, 0, accuracy: 1e-9)
    }

    func testAnnotateCoresEmpty() {
        XCTAssertTrue(SystemResourceLogic.annotateCores([]).isEmpty)
    }

    func testAverageCPU() {
        XCTAssertEqual(SystemResourceLogic.averageCPU(from: [10, 20, 30])!, 20, accuracy: 1e-9)
        XCTAssertNil(SystemResourceLogic.averageCPU(from: []))
    }

    func testLoadBalance() {
        XCTAssertEqual(SystemResourceLogic.loadBalance(corePercents: [50, 50])!, 1, accuracy: 1e-9)
        // 100 vs 0 → balance 0
        XCTAssertEqual(SystemResourceLogic.loadBalance(corePercents: [100, 0])!, 0, accuracy: 1e-9)
        // All idle → perfect balance
        XCTAssertEqual(SystemResourceLogic.loadBalance(corePercents: [0, 0, 0])!, 1, accuracy: 1e-9)
        XCTAssertNil(SystemResourceLogic.loadBalance(corePercents: [42]))
    }

    func testBusyPercentFromTicks() {
        // 50 busy + 50 idle over interval → 50%
        let pct = SystemResourceLogic.busyPercent(
            user: 100, system: 50, idle: 100, nice: 0,
            prevUser: 50, prevSystem: 50, prevIdle: 50, prevNice: 0
        )
        // dUser=50, dSystem=0, dIdle=50, dNice=0 → busy 50/100 = 50%
        XCTAssertEqual(pct!, 50, accuracy: 1e-9)
    }

    func testBusyPercentNoProgress() {
        XCTAssertNil(SystemResourceLogic.busyPercent(
            user: 10, system: 10, idle: 10, nice: 0,
            prevUser: 10, prevSystem: 10, prevIdle: 10, prevNice: 0
        ))
    }

    func testSnapshotCoreImbalanceAndHottest() {
        let cores = SystemResourceLogic.annotateCores([5, 90, 40, 20])
        let snap = SystemResourceSnapshot(cpuPercent: 38.75, cpuCores: cores)
        XCTAssertEqual(snap.cpuCoreCount, 4)
        XCTAssertEqual(snap.hottestCore?.index, 1)
        XCTAssertEqual(snap.coolestCore?.index, 0)
        XCTAssertEqual(snap.coreImbalance!, 85, accuracy: 1e-9)
    }

    func testHistoryAppendRespectsCapacity() {
        var h = SystemResourceHistory(capacity: 3)
        for i in 0..<5 {
            h.append(SystemResourceSnapshot(cpuPercent: Double(i * 10), ramPercent: 50))
        }
        XCTAssertEqual(h.cpu.count, 3)
        XCTAssertEqual(h.cpu, [20, 30, 40])
        XCTAssertEqual(h.ram.count, 3)
    }

    /// Live sampler must return coherent aggregate + per-core + disk + thermal.
    func testLiveSamplerProducesFiniteCPUAndRAM() {
        _ = SystemResourceSampler.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let snap = SystemResourceSampler.sample()
        if let cpu = snap.cpuPercent {
            XCTAssertTrue(cpu >= 0 && cpu <= 100, "cpu=\(cpu)")
        }
        XCTAssertNotNil(snap.ramPercent, "RAM should always be readable via host_statistics64")
        if let ram = snap.ramPercent {
            XCTAssertTrue(ram >= 0 && ram <= 100, "ram=\(ram)")
        }
        if let used = snap.ramUsedGB, let total = snap.ramTotalGB {
            XCTAssertGreaterThan(total, 0)
            XCTAssertLessThanOrEqual(used, total + 0.5)
        }
        // SSD: FileManager attributes — fail-closed only on exotic sandboxes.
        if let disk = snap.diskPercent {
            XCTAssertTrue(disk >= 0 && disk <= 100, "disk=\(disk)")
        }
        if let total = snap.diskTotalGB {
            XCTAssertGreaterThan(total, 0)
        }
        // Thermal ladder is public ProcessInfo — should always resolve.
        XCTAssertNotNil(snap.thermal, "ProcessInfo.thermalState should map")
        // Per-core should appear after the second sample on Darwin hosts.
        if !snap.cpuCores.isEmpty {
            XCTAssertEqual(snap.cpuCores.count, snap.cpuCoreCount)
            for core in snap.cpuCores {
                XCTAssertTrue(core.percent >= 0 && core.percent <= 100)
                XCTAssertGreaterThanOrEqual(core.rank, 1)
                XCTAssertLessThanOrEqual(core.rank, snap.cpuCores.count)
            }
            // Ranks must be a permutation of 1…n
            XCTAssertEqual(Set(snap.cpuCores.map(\.rank)).count, snap.cpuCores.count)
            // Aggregate ≈ mean of cores
            if let agg = snap.cpuPercent {
                let mean = snap.cpuCores.map(\.percent).reduce(0, +) / Double(snap.cpuCores.count)
                XCTAssertEqual(agg, mean, accuracy: 0.5)
            }
        }
    }

    func testGlyphRendersWithoutCrashing() {
        let cores = SystemResourceLogic.annotateCores([10, 40, 80, 20])
        let img = SystemResourceGlyph.image(cores: cores, aggregate: 37.5, template: false)
        XCTAssertEqual(img.size.width, SystemResourceGlyph.size.width, accuracy: 0.1)
        XCTAssertEqual(img.size.height, SystemResourceGlyph.size.height, accuracy: 0.1)

        let fallback = SystemResourceGlyph.image(cores: [], aggregate: 55, template: true)
        XCTAssertGreaterThan(fallback.size.width, 0)
    }

    /// Publish path ignores wall-clock-only changes (sampledAt thrash fix).
    func testMetricsEqualIgnoresSampledAt() {
        let a = SystemResourceSnapshot(cpuPercent: 40, ramPercent: 50, sampledAt: Date(timeIntervalSince1970: 1))
        let b = SystemResourceSnapshot(cpuPercent: 40, ramPercent: 50, sampledAt: Date(timeIntervalSince1970: 99))
        XCTAssertTrue(SystemResourceLogic.metricsEqual(a, b))
        XCTAssertEqual(a, b) // snapshot == uses metricsEqual
        XCTAssertFalse(SystemResourceLogic.shouldPublishSnapshot(previous: a, next: b))

        let c = SystemResourceSnapshot(cpuPercent: 41, ramPercent: 50, sampledAt: a.sampledAt)
        XCTAssertFalse(SystemResourceLogic.metricsEqual(a, c))
        XCTAssertTrue(SystemResourceLogic.shouldPublishSnapshot(previous: a, next: c))
    }

    func testCoreSignatureBucketFinerForFewCores() {
        XCTAssertEqual(SystemResourceLogic.coreSignatureBucket(coreCount: 4), 1)
        XCTAssertEqual(SystemResourceLogic.coreSignatureBucket(coreCount: 12), 5)
        XCTAssertEqual(SystemResourceLogic.coreSignatureBucket(coreCount: 24), 10)
    }

    func testCalmStatusTitleGlyphFirstWhenCalm() {
        let calm = SystemResourceSnapshot.Constrained(kind: .cpu, percent: 20)
        let title = SystemResourceLogic.calmStatusTitle(
            constrained: calm, hottest: nil, imbalance: nil
        )
        XCTAssertEqual(title, "")

        let hot = SystemResourceSnapshot.Constrained(kind: .cpu, percent: 85)
        let stressed = SystemResourceLogic.calmStatusTitle(
            constrained: hot, hottest: nil, imbalance: nil
        )
        XCTAssertTrue(stressed.contains("CPU"), stressed)

        let peak = CPUCoreLoad(index: 7, percent: 94, rank: 1)
        let peakTitle = SystemResourceLogic.calmStatusTitle(
            constrained: calm,
            hottest: peak,
            imbalance: 40
        )
        XCTAssertTrue(peakTitle.contains("C7"), peakTitle)
    }

    func testLoadChromeTokenNeverWarning() {
        for band in [SystemResourceLogic.Band.calm, .elevated, .hot, .critical] {
            let tok = SystemResourceLogic.loadChromeToken(for: band)
            XCTAssertNotEqual(tok, .warning, "load must not use ask-amber for \(band)")
        }
        XCTAssertEqual(SystemResourceLogic.loadChromeToken(for: .critical), .error)
    }
}
