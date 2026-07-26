import SwiftUI
import PillCore

// MARK: - Menu-bar popover resources HUD (extracted from MenuBarPopoverView)

/// System resources block (CPU/GPU/RAM/SSD/thermal + per-core strip).
///
/// Extracted so `MenuBarPopoverView` stays under the god-file LOC budget.
/// Fixed row heights and stable ordering preserve thrash-safe popover chrome.
struct MenuBarResourcesSection: View {
    @ObservedObject var resources: SystemResourceMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPerCoreDetail = false

    var body: some View {
        let snap = resources.snapshot
        let hist = resources.history
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("SYSTEM")
                    .font(.shannonMenuSection)
                    .foregroundStyle(Color.shannonSecondary)
                    .tracking(0.8)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let top = snap.mostConstrained {
                    Text("peak \(top.shortLabel)")
                        .font(.shannonMenuMono)
                        .foregroundStyle(resourceTint(percent: top.percent))
                } else if let hot = snap.hottestCore, snap.cpuCoreCount > 1 {
                    Text(String(format: "C%d · %.0f%%", hot.index, hot.percent))
                        .font(.shannonMenuMono)
                        .foregroundStyle(resourceTint(percent: hot.percent))
                }
            }

            ForEach(Self.resourceRowsOrdered(snap: snap, hist: hist), id: \.kind) { row in
                resourceRow(
                    kind: row.kind,
                    percent: row.percent,
                    detail: row.detail,
                    history: row.history
                )
            }

            if !snap.cpuCores.isEmpty {
                perCoreStrip(snap.cpuCores, imbalance: snap.coreImbalance)
                if showPerCoreDetail {
                    perCoreDetailTable(snap.cpuCores)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.resourcesAccessibilityLabel(snap))
    }

    // MARK: Models

    struct ResourceRowModel {
        var kind: SystemResourceSnapshot.Kind
        var percent: Double?
        var detail: String?
        var history: [Double]
    }

    /// Stable row order (CPU → GPU → RAM → SSD → Temp). Most-constrained is
    /// called out in the header — re-sorting rows every sample made the popover jump.
    static func resourceRowsOrdered(
        snap: SystemResourceSnapshot,
        hist: SystemResourceHistory
    ) -> [ResourceRowModel] {
        [
            ResourceRowModel(kind: .cpu, percent: snap.cpuPercent, detail: cpuAggregateDetail(snap), history: hist.cpu),
            ResourceRowModel(kind: .gpu, percent: snap.gpuPercent, detail: snap.gpuPercent == nil ? "n/a" : nil, history: hist.gpu),
            ResourceRowModel(kind: .ram, percent: snap.ramPercent, detail: ramDetail(snap), history: hist.ram),
            ResourceRowModel(kind: .disk, percent: snap.diskPercent, detail: diskDetail(snap), history: hist.disk),
            ResourceRowModel(kind: .thermal, percent: snap.thermal.map(\.pressurePercent), detail: thermalDetail(snap), history: []),
        ]
    }

    static func cpuAggregateDetail(_ snap: SystemResourceSnapshot) -> String? {
        guard snap.cpuCoreCount > 0 else { return nil }
        if let imb = snap.coreImbalance, imb >= 20 {
            return String(format: "%d-core · Δ%.0f", snap.cpuCoreCount, imb)
        }
        return "\(snap.cpuCoreCount)-core"
    }

    static func ramDetail(_ snap: SystemResourceSnapshot) -> String? {
        guard let u = snap.ramUsedGB, let t = snap.ramTotalGB, t > 0 else { return nil }
        return String(format: "%.1f / %.0f GB", u, t)
    }

    static func diskDetail(_ snap: SystemResourceSnapshot) -> String? {
        if let free = snap.diskFreeGB, let total = snap.diskTotalGB, total > 0 {
            return String(format: "%.0f GB free", free)
        }
        if let u = snap.diskUsedGB, let t = snap.diskTotalGB, t > 0 {
            return String(format: "%.0f / %.0f GB", u, t)
        }
        return snap.diskPercent == nil ? "n/a" : nil
    }

    static func thermalDetail(_ snap: SystemResourceSnapshot) -> String? {
        if let t = snap.temperatureCelsius {
            return String(format: "%.0f°C · %@", t, snap.thermal?.label ?? "?")
        }
        return snap.thermal?.label ?? "n/a"
    }

    static func resourcesAccessibilityLabel(_ snap: SystemResourceSnapshot) -> String {
        var parts: [String] = []
        if let top = snap.mostConstrained {
            parts.append("Most constrained \(top.shortLabel)")
        }
        for row in snap.constrainedRanked {
            parts.append("\(row.kind.shortLabel) \(Int(row.percent)) percent")
        }
        if let free = snap.diskFreeGB {
            parts.append(String(format: "%.0f gigabytes free", free))
        }
        if let t = snap.thermal {
            parts.append("Thermal \(t.label)")
        }
        if parts.isEmpty { return "System resources unavailable" }
        return parts.joined(separator: ", ")
    }

    // MARK: Rows

    private func resourceRow(
        kind: SystemResourceSnapshot.Kind,
        percent: Double?,
        detail: String?,
        history: [Double]
    ) -> some View {
        let pct = percent ?? 0
        let tint = resourceTint(percent: percent)
        let label = percent.map { String(format: "%.0f%%", $0) } ?? (detail == "n/a" ? "—" : "…")
        return HStack(spacing: 6) {
            Image(systemName: kind == .gpu ? "cube" : kind.systemImage)
                .font(.shannonMenuBody)
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(kind.shortLabel)
                .font(.shannonMenuMono)
                .foregroundStyle(Color.shannonSecondary)
                .frame(width: 36, alignment: .leading)
            MenuBarSmoothLoadBar(
                percent: pct,
                tint: tint,
                isPlaceholder: percent == nil,
                reduceMotion: reduceMotion
            )
            .frame(height: 7)
            Group {
                if history.count >= 2 {
                    MenuBarSparklineView(values: history, tint: tint)
                } else {
                    Color.clear
                }
            }
            .frame(width: 36, height: 14)
            Text(label)
                .font(.shannonMenuMono)
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .trailing)
                .contentTransition(.identity)
            Text(detail == "n/a" ? "" : (detail ?? ""))
                .font(.shannonMenuMono)
                .foregroundStyle(Color.shannonTertiary)
                .lineLimit(1)
                .frame(minWidth: 52, alignment: .leading)
                .opacity((detail == nil || detail == "n/a") ? 0 : 1)
        }
        .frame(height: 16)
    }

    private func perCoreStrip(_ cores: [CPUCoreLoad], imbalance: Double?) -> some View {
        let tall: CGFloat = 26
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("CORES")
                    .font(.shannonMenuSection)
                    .foregroundStyle(Color.shannonTertiary)
                    .tracking(0.6)
                if let imb = imbalance {
                    Text(String(format: "spread %.0fpp", imb))
                        .font(.shannonMenuMono)
                        .foregroundStyle(imb >= 25 ? Color.shannonWarning : Color.shannonTertiary)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(reduceMotion ? nil : .shannonEase) {
                        showPerCoreDetail.toggle()
                    }
                } label: {
                    Text(showPerCoreDetail ? "hide" : "vs peers")
                        .font(.shannonMenuSection)
                        .foregroundStyle(Color.shannonAccent)
                }
                .buttonStyle(.plain)
                .help(showPerCoreDetail
                      ? "Hide per-core comparison table"
                      : "Show each core vs average load")
            }
            GeometryReader { geo in
                let n = cores.count
                let gap: CGFloat = n > 16 ? 1 : (n > 8 ? 1.5 : 2)
                let barW = max(2, (geo.size.width - gap * CGFloat(max(0, n - 1))) / CGFloat(n))
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(cores) { core in
                        let tint = resourceTint(percent: core.percent)
                        MenuBarSmoothCoreBar(
                            percent: core.percent,
                            tint: tint,
                            hot: core.isHotRelative,
                            busiest: core.isBusiest && core.percent >= 15,
                            width: barW,
                            maxHeight: geo.size.height,
                            reduceMotion: reduceMotion
                        )
                        .help(coreHelp(core))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: tall)
            .compositingGroup()
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.shannonNeutral.opacity(0.12))
            )
        }
    }

    private func perCoreDetailTable(_ cores: [CPUCoreLoad]) -> some View {
        let sorted = cores.sorted { a, b in
            if a.percent != b.percent { return a.percent > b.percent }
            return a.index < b.index
        }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Core").frame(width: 36, alignment: .leading)
                Text("Load").frame(width: 40, alignment: .trailing)
                Text("vs avg").frame(width: 48, alignment: .trailing)
                Text("Rel").frame(width: 36, alignment: .trailing)
                Spacer(minLength: 0)
                Text("Rank").frame(width: 28, alignment: .trailing)
            }
            .font(.shannonMenuMono)
            .foregroundStyle(Color.shannonTertiary)

            ForEach(sorted.prefix(12)) { core in
                let tint = resourceTint(percent: core.percent)
                HStack(spacing: 4) {
                    Text(String(format: "C%02d", core.index))
                        .frame(width: 36, alignment: .leading)
                        .foregroundStyle(core.isHotRelative ? tint : Color.shannonSecondary)
                    Text(String(format: "%.0f%%", core.percent))
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(tint)
                    Text(String(format: "%+.0fpp", core.deltaVsAverage))
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(core.deltaVsAverage >= 10
                                         ? Color.shannonWarning
                                         : Color.shannonTertiary)
                    Text(core.relativeToAverage.map { String(format: "%.2f×", $0) } ?? "—")
                        .frame(width: 36, alignment: .trailing)
                        .foregroundStyle(Color.shannonSecondary)
                    Spacer(minLength: 0)
                    Text("#\(core.rank)")
                        .frame(width: 28, alignment: .trailing)
                        .foregroundStyle(core.rank == 1 ? Color.shannonAccent : Color.shannonTertiary)
                }
                .font(.shannonMenuMono)
            }
            if cores.count > 12 {
                Text("… \(cores.count - 12) more cores")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonTertiary)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.shannonNeutral.opacity(0.08))
        )
    }

    private func coreHelp(_ core: CPUCoreLoad) -> String {
        var s = String(format: "Core %d: %.0f%% busy", core.index, core.percent)
        s += String(format: ", %+.0f pp vs average", core.deltaVsAverage)
        if let r = core.relativeToAverage {
            s += String(format: " (%.2f×)", r)
        }
        s += ", rank #\(core.rank)"
        return s
    }

    private func resourceTint(percent: Double?) -> Color {
        let c = ResourceScarcityTint.sRGB(percent: percent)
        return Color(red: c.r, green: c.g, blue: c.b).opacity(c.a)
    }
}

// MARK: - Smooth gauges (local fill motion only)

/// Horizontal load bar whose **width** eases without reflowing the popover.
struct MenuBarSmoothLoadBar: View {
    var percent: Double
    var tint: Color
    var isPlaceholder: Bool
    var reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            let w = max(3, geo.size.width * CGFloat(min(100, max(0, percent)) / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.shannonNeutral.opacity(0.22))
                Capsule()
                    .fill(tint.opacity(isPlaceholder ? 0.12 : 0.9))
                    .frame(width: w)
                    .transaction { txn in
                        txn.animation = reduceMotion ? nil : .shannonLiquid
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One per-core column; height eases independently of popover chrome.
struct MenuBarSmoothCoreBar: View {
    var percent: Double
    var tint: Color
    var hot: Bool
    var busiest: Bool
    var width: CGFloat
    var maxHeight: CGFloat
    var reduceMotion: Bool

    var body: some View {
        let h = max(2, maxHeight * CGFloat(min(100, max(0, percent)) / 100))
        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
            .fill(tint.opacity(hot ? 1.0 : 0.75))
            .frame(width: width, height: h)
            .overlay(alignment: .top) {
                if busiest {
                    Circle()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 2.5, height: 2.5)
                        .offset(y: -3)
                }
            }
            .transaction { txn in
                txn.animation = reduceMotion ? nil : .shannonLiquid
            }
    }
}

/// Tiny line chart for recent utilisation history (iStat-style).
struct MenuBarSparklineView: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let pts = normalized(values, in: geo.size)
            if pts.count >= 2 {
                Path { path in
                    path.move(to: pts[0])
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
                .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .animation(nil, value: values.count)
            }
        }
        .accessibilityHidden(true)
    }

    private func normalized(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return [] }
        let minV = 0.0
        let maxV = max(values.max() ?? 100, 1)
        let span = max(maxV - minV, 1)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let x = CGFloat(i) * step
            let y = size.height - CGFloat((v - minV) / span) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}
