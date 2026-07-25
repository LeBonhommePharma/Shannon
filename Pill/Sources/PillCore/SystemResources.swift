import Foundation
#if canImport(Darwin)
import Darwin
import MachO
#endif
#if canImport(IOKit)
import IOKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Per-core CPU

/// One logical CPU core's busy % for a sample interval, plus relative rank.
public struct CPUCoreLoad: Sendable, Equatable, Identifiable {
    /// Zero-based core index (logical CPU as reported by the kernel).
    public var index: Int
    /// Busy % (user + system + nice) over the last interval, 0…100.
    public var percent: Double
    /// `percent − average` across cores (positive = hotter than peers).
    public var deltaVsAverage: Double
    /// Fraction of peer average: 1.0 = at average, 1.5 = 50% hotter.
    /// `nil` when average is ~0 (all idle).
    public var relativeToAverage: Double?
    /// 1-based rank by load (1 = busiest). Ties broken by lower index.
    public var rank: Int

    public var id: Int { index }

    public init(
        index: Int,
        percent: Double,
        deltaVsAverage: Double = 0,
        relativeToAverage: Double? = nil,
        rank: Int = 1
    ) {
        self.index = index
        self.percent = SystemResourceLogic.clampPct(percent) ?? 0
        self.deltaVsAverage = deltaVsAverage.isFinite ? deltaVsAverage : 0
        self.relativeToAverage = relativeToAverage.flatMap { $0.isFinite ? $0 : nil }
        self.rank = max(1, rank)
    }

    /// True when this core is meaningfully hotter than the pack (≥ +15 pp or ≥1.4×).
    public var isHotRelative: Bool {
        if deltaVsAverage >= 15 { return true }
        if let r = relativeToAverage, r >= 1.4, percent >= 20 { return true }
        return false
    }

    /// True when this core is the single busiest (rank 1) and above idle noise.
    public var isBusiest: Bool { rank == 1 && percent >= 5 }
}

// MARK: - Snapshot

/// One sample of host CPU / GPU / RAM utilisation, 0…100 percent each.
///
/// Built for the menu-bar HUD (all three + per-core) and the notch pill
/// (most constrained only). Pure value type — no I/O after construction.
public struct SystemResourceSnapshot: Sendable, Equatable {
    /// Overall CPU busy % (user + system + nice), 0…100. `nil` when unreadable.
    public var cpuPercent: Double?
    /// Per-logical-core busy % for the same interval. Empty when unreadable.
    public var cpuCores: [CPUCoreLoad]
    /// GPU device utilisation % when the driver exposes it, else `nil`.
    public var gpuPercent: Double?
    /// RAM used / total as %, 0…100. `nil` when unreadable.
    public var ramPercent: Double?
    public var ramUsedGB: Double?
    public var ramTotalGB: Double?
    /// Wall clock of this sample.
    public var sampledAt: Date

    public init(
        cpuPercent: Double? = nil,
        cpuCores: [CPUCoreLoad] = [],
        gpuPercent: Double? = nil,
        ramPercent: Double? = nil,
        ramUsedGB: Double? = nil,
        ramTotalGB: Double? = nil,
        sampledAt: Date = Date()
    ) {
        self.cpuPercent = SystemResourceLogic.clampPct(cpuPercent)
        self.cpuCores = cpuCores
        self.gpuPercent = SystemResourceLogic.clampPct(gpuPercent)
        self.ramPercent = SystemResourceLogic.clampPct(ramPercent)
        self.ramUsedGB = ramUsedGB.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.ramTotalGB = ramTotalGB.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.sampledAt = sampledAt
    }

    /// Equality for UI publish: **ignores `sampledAt`** so a pure wall-clock
    /// tick does not force SwiftUI / menu-bar invalidation when gauges are flat.
    public static func == (lhs: SystemResourceSnapshot, rhs: SystemResourceSnapshot) -> Bool {
        SystemResourceLogic.metricsEqual(lhs, rhs)
    }

    /// Number of logical cores in this sample (0 if per-core unavailable).
    public var cpuCoreCount: Int { cpuCores.count }

    /// Busiest core, if any.
    public var hottestCore: CPUCoreLoad? {
        cpuCores.max(by: { $0.percent < $1.percent })
    }

    /// Coolest core, if any.
    public var coolestCore: CPUCoreLoad? {
        cpuCores.min(by: { $0.percent < $1.percent })
    }

    /// Max − min core busy % (load imbalance). `nil` with fewer than 2 cores.
    public var coreImbalance: Double? {
        guard cpuCores.count >= 2,
              let hi = hottestCore?.percent,
              let lo = coolestCore?.percent
        else { return nil }
        return hi - lo
    }

    /// Which gauge is under the most pressure right now.
    public enum Kind: String, Sendable, CaseIterable {
        case cpu
        case gpu
        case ram

        public var shortLabel: String {
            switch self {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .ram: return "RAM"
            }
        }

        public var systemImage: String {
            switch self {
            case .cpu: return "cpu"
            case .gpu: return "memorychip"
            case .ram: return "memorychip"
            }
        }
    }

    public struct Constrained: Sendable, Equatable {
        public var kind: Kind
        public var percent: Double
        public init(kind: Kind, percent: Double) {
            self.kind = kind
            self.percent = percent
        }

        /// Compact pill / menu-bar label: `CPU 87%`.
        public var shortLabel: String {
            String(format: "%@ %.0f%%", kind.shortLabel, percent)
        }
    }

    /// Highest of the available gauges. `nil` when nothing was measured.
    public var mostConstrained: Constrained? {
        var best: Constrained?
        func consider(_ kind: Kind, _ pct: Double?) {
            guard let pct else { return }
            if best == nil || pct > best!.percent {
                best = Constrained(kind: kind, percent: pct)
            }
        }
        consider(.cpu, cpuPercent)
        consider(.gpu, gpuPercent)
        consider(.ram, ramPercent)
        return best
    }

    /// True when any gauge is in the "pay attention" band (≥ warn threshold).
    public func isStressed(warnAt: Double = 80) -> Bool {
        guard let c = mostConstrained else { return false }
        return c.percent >= warnAt
    }

    public var age: TimeInterval { Date().timeIntervalSince(sampledAt) }
}

// MARK: - History (sparklines)

/// Rolling window of recent aggregate samples for iStat-style sparklines.
public struct SystemResourceHistory: Sendable, Equatable {
    public var cpu: [Double]
    public var gpu: [Double]
    public var ram: [Double]
    public var capacity: Int

    public init(capacity: Int = 48) {
        self.cpu = []
        self.gpu = []
        self.ram = []
        self.capacity = max(2, capacity)
    }

    public mutating func append(_ snap: SystemResourceSnapshot) {
        let cap = capacity
        if let v = snap.cpuPercent {
            cpu.append(v)
            if cpu.count > cap { cpu.removeFirst(cpu.count - cap) }
        }
        if let v = snap.gpuPercent {
            gpu.append(v)
            if gpu.count > cap { gpu.removeFirst(gpu.count - cap) }
        }
        if let v = snap.ramPercent {
            ram.append(v)
            if ram.count > cap { ram.removeFirst(ram.count - cap) }
        }
    }
}

// MARK: - Pure helpers (unit-tested)

public enum SystemResourceLogic {
    public static func clampPct(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return min(100, max(0, v))
    }

    /// RAM utilisation from used/total bytes (or GB — units cancel).
    public static func ramPercent(used: Double, total: Double) -> Double? {
        guard used.isFinite, total.isFinite, total > 0, used >= 0 else { return nil }
        return min(100, max(0, (used / total) * 100))
    }

    /// Pick the most constrained resource from optional gauges.
    public static func mostConstrained(
        cpu: Double?,
        gpu: Double?,
        ram: Double?
    ) -> SystemResourceSnapshot.Constrained? {
        SystemResourceSnapshot(
            cpuPercent: cpu, gpuPercent: gpu, ramPercent: ram
        ).mostConstrained
    }

    /// Tint band for a utilisation gauge.
    public enum Band: String, Sendable {
        case calm      // < 60
        case elevated  // 60…80
        case hot       // 80…92
        case critical  // ≥ 92
    }

    public static func band(for percent: Double) -> Band {
        if percent >= 92 { return .critical }
        if percent >= 80 { return .hot }
        if percent >= 60 { return .elevated }
        return .calm
    }

    /// Metric equality (no wall clock). Used by snapshot `==` and publish gating.
    public static func metricsEqual(_ a: SystemResourceSnapshot, _ b: SystemResourceSnapshot) -> Bool {
        approxEq(a.cpuPercent, b.cpuPercent)
            && a.cpuCores == b.cpuCores
            && approxEq(a.gpuPercent, b.gpuPercent)
            && approxEq(a.ramPercent, b.ramPercent)
            && approxEq(a.ramUsedGB, b.ramUsedGB)
            && approxEq(a.ramTotalGB, b.ramTotalGB)
    }

    /// Whether UI should publish a new snapshot (metrics moved).
    public static func shouldPublishSnapshot(
        previous: SystemResourceSnapshot,
        next: SystemResourceSnapshot
    ) -> Bool {
        !metricsEqual(previous, next)
    }

    private static func approxEq(_ a: Double?, _ b: Double?, eps: Double = 1e-9) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) <= eps
        default: return false
        }
    }

    /// Core signature bucket size for menu-bar redraw: finer when fewer cores.
    public static func coreSignatureBucket(coreCount: Int) -> Int {
        if coreCount <= 8 { return 1 }   // 1% steps
        if coreCount <= 16 { return 5 }  // 5% steps
        return 10                        // 10% for many cores
    }

    /// Compact signature of per-core load for status-item paint gating.
    public static func coresSignatureKey(cores: [CPUCoreLoad], aggregate: Double?) -> String {
        if cores.isEmpty {
            return aggregate.map { String(format: "a%.0f", $0) } ?? "-"
        }
        let bucket = coreSignatureBucket(coreCount: cores.count)
        var parts = cores.map { String(Int($0.percent) / bucket) }
        if let hot = cores.first(where: { $0.isBusiest }) {
            parts.append("p\(hot.index)")
        }
        return parts.joined()
    }

    /// Quiet menu-bar title density: glyph-only when calm; peak or constrained when stressed.
    public static func calmStatusTitle(
        constrained: SystemResourceSnapshot.Constrained?,
        hottest: CPUCoreLoad?,
        imbalance: Double?,
        calmBelow: Double = 60
    ) -> String {
        // Peak story when one core is far ahead of the pack.
        if let hot = hottest, let imb = imbalance, imb >= 25, hot.percent >= 60 {
            return String(format: " C%d %.0f%%", hot.index, hot.percent)
        }
        guard let c = constrained else { return "" }
        if c.percent < calmBelow { return "" } // glyph-first when calm
        return " \(c.shortLabel)"
    }

    /// Host load tint role — never `.warning` (reserved for approval ask).
    public static func loadChromeToken(for band: Band) -> PillChromePolicy.StatusChromeToken {
        switch band {
        case .calm: return .tertiary
        case .elevated: return .accent
        case .hot: return .accent   // not ask-amber
        case .critical: return .error
        }
    }

    /// Build ranked `CPUCoreLoad` rows from raw per-core busy percents.
    ///
    /// - Parameters:
    ///   - percents: one entry per logical core, 0…100.
    /// - Returns: cores with `deltaVsAverage`, `relativeToAverage`, and ranks.
    public static func annotateCores(_ percents: [Double]) -> [CPUCoreLoad] {
        guard !percents.isEmpty else { return [] }
        let clamped = percents.map { clampPct($0) ?? 0 }
        let avg = clamped.reduce(0, +) / Double(clamped.count)
        // Stable sort for ranking: higher load first, then lower index.
        let order = clamped.enumerated()
            .sorted { a, b in
                if a.element != b.element { return a.element > b.element }
                return a.offset < b.offset
            }
        var rankByIndex = [Int: Int](minimumCapacity: clamped.count)
        for (rankZero, item) in order.enumerated() {
            rankByIndex[item.offset] = rankZero + 1
        }
        return clamped.enumerated().map { i, pct in
            let rel: Double? = avg > 0.5 ? pct / avg : nil
            return CPUCoreLoad(
                index: i,
                percent: pct,
                deltaVsAverage: pct - avg,
                relativeToAverage: rel,
                rank: rankByIndex[i] ?? (i + 1)
            )
        }
    }

    /// Aggregate busy % from per-core values (mean). Matches host_cpu average
    /// when cores are equally weighted logical CPUs.
    public static func averageCPU(from corePercents: [Double]) -> Double? {
        guard !corePercents.isEmpty else { return nil }
        let sum = corePercents.compactMap { clampPct($0) }.reduce(0, +)
        return sum / Double(corePercents.count)
    }

    /// Load balance score 0…1: 1 = perfectly even, 0 = one core maxed, rest idle.
    public static func loadBalance(corePercents: [Double]) -> Double? {
        guard corePercents.count >= 2 else { return nil }
        let vals = corePercents.compactMap { clampPct($0) }
        guard vals.count >= 2 else { return nil }
        let maxV = vals.max() ?? 0
        let minV = vals.min() ?? 0
        // When everything is idle, treat as balanced.
        if maxV < 1 { return 1 }
        return max(0, min(1, 1 - (maxV - minV) / 100))
    }

    /// Busy fraction from tick deltas (user+system+nice) / total.
    public static func busyPercent(
        user: UInt64, system: UInt64, idle: UInt64, nice: UInt64,
        prevUser: UInt64, prevSystem: UInt64, prevIdle: UInt64, prevNice: UInt64
    ) -> Double? {
        let dUser = Double(user &- prevUser)
        let dSystem = Double(system &- prevSystem)
        let dIdle = Double(idle &- prevIdle)
        let dNice = Double(nice &- prevNice)
        let total = dUser + dSystem + dIdle + dNice
        guard total > 0 else { return nil }
        let busy = dUser + dSystem + dNice
        return min(100, max(0, (busy / total) * 100))
    }
}

// MARK: - Sampler

/// Reads live host metrics. Fail-closed: any OS error yields `nil` fields.
public enum SystemResourceSampler {
    /// One sample. Safe to call from a background queue; no main-thread work.
    public static func sample(now: Date = Date()) -> SystemResourceSnapshot {
        #if canImport(Darwin)
        let (cpuAgg, cores) = sampleCPUWithCores()
        let (usedGB, totalGB) = sampleRAM()
        let ramPct = SystemResourceLogic.ramPercent(used: usedGB ?? 0, total: totalGB ?? 0)
        let gpu = sampleGPU()
        return SystemResourceSnapshot(
            cpuPercent: cpuAgg,
            cpuCores: cores,
            gpuPercent: gpu,
            ramPercent: ramPct,
            ramUsedGB: usedGB,
            ramTotalGB: totalGB,
            sampledAt: now
        )
        #else
        return SystemResourceSnapshot(sampledAt: now)
        #endif
    }

    // MARK: CPU (aggregate + per-core)

    #if canImport(Darwin)
    /// Per-core previous tick counters: [core][user, system, idle, nice]
    private static var prevCoreTicks: [[UInt32]]?
    private static let cpuLock = NSLock()

    /// Sample logical CPUs via `host_processor_info` and derive aggregate +
    /// annotated per-core loads. First call after process start returns
    /// `nil` aggregate / empty cores (primes counters).
    private static func sampleCPUWithCores() -> (Double?, [CPUCoreLoad]) {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &infoArray,
            &infoCount
        )
        guard kr == KERN_SUCCESS, let infoArray, cpuCount > 0 else {
            // Fallback to host-level aggregate only.
            return (sampleCPUAggregateOnly(), [])
        }
        defer {
            let byteSize = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray), byteSize)
        }

        let states = Int(CPU_STATE_MAX) // 4
        let n = Int(cpuCount)
        var current: [[UInt32]] = []
        current.reserveCapacity(n)
        for i in 0..<n {
            let base = i * states
            // processor_info_array_t is UnsafeMutablePointer<integer_t>
            let user = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)])
            current.append([user, system, idle, nice])
        }

        cpuLock.lock()
        let prev = prevCoreTicks
        prevCoreTicks = current
        cpuLock.unlock()

        guard let prev, prev.count == current.count else {
            return (nil, [])
        }

        var percents: [Double] = []
        percents.reserveCapacity(n)
        for i in 0..<n {
            let c = current[i]
            let p = prev[i]
            let pct = SystemResourceLogic.busyPercent(
                user: UInt64(c[0]), system: UInt64(c[1]),
                idle: UInt64(c[2]), nice: UInt64(c[3]),
                prevUser: UInt64(p[0]), prevSystem: UInt64(p[1]),
                prevIdle: UInt64(p[2]), prevNice: UInt64(p[3])
            ) ?? 0
            percents.append(pct)
        }

        let cores = SystemResourceLogic.annotateCores(percents)
        let agg = SystemResourceLogic.averageCPU(from: percents)
        return (agg, cores)
    }

    /// Host-level aggregate when per-core fails (rare).
    private static var prevCPU: (user: natural_t, system: natural_t, idle: natural_t, nice: natural_t)?

    private static func sampleCPUAggregateOnly() -> Double? {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = info.cpu_ticks.0
        let system = info.cpu_ticks.1
        let idle = info.cpu_ticks.2
        let nice = info.cpu_ticks.3

        cpuLock.lock()
        defer { cpuLock.unlock() }
        let prev = prevCPU
        prevCPU = (user, system, idle, nice)
        guard let prev else { return nil }
        return SystemResourceLogic.busyPercent(
            user: UInt64(user), system: UInt64(system),
            idle: UInt64(idle), nice: UInt64(nice),
            prevUser: UInt64(prev.user), prevSystem: UInt64(prev.system),
            prevIdle: UInt64(prev.idle), prevNice: UInt64(prev.nice)
        )
    }

    // MARK: RAM

    private static func sampleRAM() -> (usedGB: Double?, totalGB: Double?) {
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        var vmstat = vm_statistics64()
        let kr = withUnsafeMutablePointer(to: &vmstat) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return (nil, nil) }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return (nil, nil)
        }

        // Active + wired + compressed ≈ "used" in Activity Monitor sense.
        let usedPages =
            UInt64(vmstat.active_count)
            + UInt64(vmstat.wire_count)
            + UInt64(vmstat.compressor_page_count)
        let usedBytes = Double(usedPages) * Double(pageSize)

        var memsize: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memsize, &len, nil, 0)
        guard memsize > 0 else { return (nil, nil) }
        let totalBytes = Double(memsize)
        return (usedBytes / 1e9, totalBytes / 1e9)
    }

    // MARK: GPU (IOKit PerformanceStatistics)

    /// Best-effort GPU utilisation via IOAccelerator "Device Utilization %".
    /// Returns `nil` when the driver does not publish the key (common on some
    /// discrete GPUs / VMs). No root / powermetrics required.
    private static func sampleGPU() -> Double? {
        #if canImport(IOKit)
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &props, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any]
            else { continue }

            let stats = dict["PerformanceStatistics"] as? [String: Any] ?? dict
            let keys = [
                "Device Utilization %",
                "GPU Activity(%)",
                "Renderer Utilization %",
                "Tiler Utilization %",
            ]
            for key in keys {
                if let n = stats[key] as? NSNumber {
                    let v = n.doubleValue
                    if v.isFinite, v >= 0 {
                        best = max(best ?? 0, min(100, v))
                    }
                }
            }
        }
        return best
        #else
        return nil
        #endif
    }
    #endif
}

// MARK: - Live publisher

/// Polls `SystemResourceSampler` for the menu bar and pill.
///
/// Default interval is ~0.75s — frequent enough for iStat-style motion without
/// thrashing `host_processor_info`. History feeds popover sparklines.
@MainActor
public final class SystemResourceMonitor: ObservableObject {
    @Published public private(set) var snapshot = SystemResourceSnapshot()
    @Published public private(set) var history = SystemResourceHistory()

    private var timer: Timer?
    private let interval: TimeInterval
    private var warmed = false

    /// - Parameter interval: poll period in seconds. Prefer 0.5…1.0 for HUD feel.
    public init(interval: TimeInterval = 0.75, historyCapacity: Int = 48) {
        self.interval = max(0.25, interval)
        self.history = SystemResourceHistory(capacity: historyCapacity)
    }

    public func start() {
        // First sample primes CPU counters (returns nil busy %).
        _ = SystemResourceSampler.sample()
        warmed = true
        // Immediate second sample so the first UI paint has real numbers.
        Task.detached(priority: .utility) {
            // Tiny delay so tick counters advance.
            try? await Task.sleep(nanoseconds: 80_000_000)
            let snap = SystemResourceSampler.sample()
            await MainActor.run { [weak self] in
                self?.applyAndNotify(snap)
            }
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = min(0.15, interval * 0.2)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        Task.detached(priority: .utility) {
            let snap = SystemResourceSampler.sample()
            await MainActor.run { [weak self] in
                self?.applyAndNotify(snap)
            }
        }
    }

    private func apply(_ snap: SystemResourceSnapshot) {
        // Publish only when host metrics move — not on pure `sampledAt` ticks.
        guard SystemResourceLogic.shouldPublishSnapshot(previous: snapshot, next: snap) else {
            return
        }
        if snap.cpuPercent != nil || snap.ramPercent != nil {
            history.append(snap)
        }
        snapshot = snap
    }

    /// Optional sink for menu-bar paint alignment (sample-driven refresh).
    public var onSnapshotPublished: (() -> Void)?

    private func applyAndNotify(_ snap: SystemResourceSnapshot) {
        let before = snapshot
        apply(snap)
        if !SystemResourceLogic.metricsEqual(before, snapshot) {
            onSnapshotPublished?()
        }
    }
}

// MARK: - Menu-bar glyph (AppKit)

#if canImport(AppKit)
/// Draws a compact iStat-style status-item image: vertical per-core bars.
public enum SystemResourceGlyph {
    /// Pixel size of the menu-bar graphic (points @2x internally).
    public static let size = NSSize(width: 22, height: 16)

    /// Render per-core bars. Falls back to a single aggregate bar when cores empty.
    public static func image(
        cores: [CPUCoreLoad],
        aggregate: Double?,
        template: Bool = false
    ) -> NSImage {
        let size = self.size
        let img = NSImage(size: size, flipped: false) { rect in
            let values: [Double]
            if !cores.isEmpty {
                values = cores.map(\.percent)
            } else if let aggregate {
                values = [aggregate]
            } else {
                values = [0]
            }
            let n = values.count
            let gap: CGFloat = n > 12 ? 0.5 : 1.0
            let totalGap = gap * CGFloat(max(0, n - 1))
            let barW = max(1.0, (rect.width - totalGap) / CGFloat(n))
            let maxH = rect.height

            let peakIndex: Int? = {
                guard !cores.isEmpty else { return nil }
                return cores.first(where: \.isBusiest)?.index
            }()
            for (i, pct) in values.enumerated() {
                let fraction = CGFloat(min(100, max(0, pct)) / 100)
                let h = max(1, maxH * max(0.06, fraction))
                let x = CGFloat(i) * (barW + gap)
                let bar = CGRect(x: x, y: 0, width: barW, height: h)
                let color = barColor(for: pct, template: template, isPeak: peakIndex == i)
                color.setFill()
                let path = NSBezierPath(roundedRect: bar, xRadius: 0.8, yRadius: 0.8)
                path.fill()
                // Peak core: thin white cap so busiest core is visible without click.
                if peakIndex == i, pct >= 15, !template {
                    NSColor.white.withAlphaComponent(0.85).setFill()
                    let cap = CGRect(x: x, y: h - 1.5, width: barW, height: 1.5)
                    NSBezierPath(roundedRect: cap, xRadius: 0.5, yRadius: 0.5).fill()
                }
            }
            return true
        }
        img.isTemplate = template
        return img
    }

    private static func barColor(for percent: Double, template: Bool, isPeak: Bool) -> NSColor {
        if template {
            return NSColor.labelColor.withAlphaComponent(0.15 + 0.85 * (percent / 100))
        }
        // Load colors: yellow/blue-green spectrum — avoid pure systemOrange (ask-amber).
        switch SystemResourceLogic.band(for: percent) {
        case .calm:
            let base = NSColor.systemGreen.withAlphaComponent(0.35 + 0.55 * (percent / 60))
            return isPeak ? base.blended(withFraction: 0.25, of: .white) ?? base : base
        case .elevated:
            return NSColor.systemYellow
        case .hot:
            return NSColor.systemYellow.blended(withFraction: 0.35, of: .systemRed) ?? .systemYellow
        case .critical:
            return NSColor.systemRed
        }
    }
}
#endif
