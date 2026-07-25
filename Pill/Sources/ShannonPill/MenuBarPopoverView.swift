import SwiftUI
import PillCore
import ShannonTheme

/// The menu-bar popover: everything LP needs at a glance without opening the
/// notch pill — busy agents, the newest pending gate (answerable inline),
/// a short activity log, hub connectivity, and quick links.
///
/// Data sources are the same live models the pill observes; nothing here is
/// duplicated state. Approvals go through `AgentActivityMonitor.resolve`, the
/// async path that never blocks the main thread and surfaces gate errors.
struct MenuBarPopoverView: View {
    /// Fixed chrome size while the popover is open. Live telemetry must not
    /// resize the window or the footer (Quit) jumps out from under the cursor.
    static let chromeWidth: CGFloat = 320
    static let chromeHeight: CGFloat = 448

    @ObservedObject var activity: AgentActivityMonitor
    @ObservedObject var bridge: ShannonBridge
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var resources: SystemResourceMonitor
    @ObservedObject var keepAwake: KeepAwakeMonitor
    @ObservedObject var focusMode: FocusModeMonitor
    /// Cloud multi-device honesty: `"on"` / `"in-memory"` / `"off"`.
    var multiDeviceStatus: String = "in-memory"

    var onShowAllGates: () -> Void
    var onOpenHubLog: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    /// Fleet-level reading (worst/freshest) for the header collapse line and
    /// footer summary. Per-agent gauges use `agentReadings`.
    private var reading: EntropyReading {
        EntropyProvenance.resolve(
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status,
            gate: activity.agentEntropy,
            gateDBAvailable: activity.gateDBAvailable
        )
    }

    /// Independent H per listed agent — never a single anonymous number.
    private var agentReadings: [String: EntropyReading] {
        EntropyProvenance.resolveAll(
            agentIds: (busy.isEmpty ? summary.agents : busy).map(\.id),
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status,
            gate: activity.agentEntropy,
            gateDBAvailable: activity.gateDBAvailable
        )
    }

    /// Only alarm on a collapse something actually measured. Unknown is not
    /// false, and it is not a collapse either.
    private var collapseAlarm: Bool { reading.collapsed == true }

    private var summary: AgentActivitySummary { activity.summary }
    private var busy: [AgentActivitySnapshot] { summary.busy }
    /// Newest pending approval — the one worth answering inline.
    private var ask: GateDBReader.PendingAsk? { activity.pendingAsks.first }

    /// Gate readiness line for the hub badge / header (P0.3).
    private var gateHealth: GateHealth {
        GateHealthResolver.resolve(
            socketUp: activity.gateAvailable,
            dbAvailable: activity.gateDBAvailable,
            pendingAsks: activity.pendingAsks.count,
            hasMeasuredEntropy: reading.isMeasured
        )
    }

    @State private var showFirstRun = FirstRunCoach.shouldShow()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Fixed chrome + scrollable body + pinned footer.
        // Intrinsic height used to reflow every resource tick so the Quit
        // control "escaped" the cursor mid-click. Footer stays docked; only
        // the middle scrolls when sections grow.
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    if showFirstRun && summary.agents.isEmpty {
                        firstRunTips
                            .shannonGlassSection(emphasized: true)
                    }
                    if let ask {
                        GateInlineCard(
                            ask: ask,
                            isResolving: activity.resolving.contains(ask.interactionId),
                            error: activity.lastResolveError,
                            extraPending: max(0, activity.pendingAsks.count - 1),
                            onAnswer: { approved in
                                Task { await activity.resolve(ask, approved: approved) }
                            },
                            onShowAll: onShowAllGates
                        )
                        // Stable id so only ask *identity* changes swap the card.
                        .id(ask.interactionId)
                    }
                    resourcesSection
                        .shannonGlassSection()
                    if BenchmarkRunLogic.shouldShowCard(activity.benchmark) {
                        benchmarkSection
                            .shannonGlassSection(
                                emphasized: activity.benchmark.map { !$0.isComplete } ?? false
                            )
                    }
                    keepAwakeSection
                        .shannonGlassSection()
                    agentSection
                        .shannonGlassSection()
                    staleAskNotice
                    recentSection
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
                // Fill width inside the scroll so gauges do not reflow sideways.
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            // Pinned action bar — never moves with live HUD ticks.
            footer
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    Color.black.opacity(0.22)
                }
        }
        .frame(width: Self.chromeWidth, height: Self.chromeHeight, alignment: .top)
        .transaction { txn in
            // Kill implicit layout animation on telemetry ticks.
            txn.animation = nil
            txn.disablesAnimations = true
        }
        .onChange(of: activity.summary.busyCount) { count in
            keepAwake.syncWithAgents(busyCount: count)
        }
        // Liquid Glass stack for macOS 27: `.popover` material + specular.
        .background {
            ZStack {
                PillMaterial(kind: .popover)
                Color.shannonBackground.opacity(0.22)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.08),
                        Color.white.opacity(0.02),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.35)
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: collapseAlarm ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                .font(.shannonMenuTitle)
                .foregroundStyle(collapseAlarm ? Color.shannonError : Color.shannonAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Shannon")
                    .font(.shannonMenuTitle)
                    .foregroundStyle(Color.shannonPrimary)
                Text(headerSubtitle)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
                    // Fixed height so live subtitle swaps never shove the badge.
                    .frame(height: 14, alignment: .leading)
            }
            Spacer(minLength: 4)
            hubStatusBadge
        }
        .frame(height: 36)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shannon. \(headerSubtitle). \(hubStatusText)")
    }

    /// One-line founder scan: collapse > busy agents > live FlexAIDdS run > hub state.
    private var headerSubtitle: String {
        HubScanLine.resolve(
            collapseBits: collapseAlarm ? reading.measurement?.bits : nil,
            collapseDelta: collapseAlarm ? reading.measurement?.deltaH : nil,
            busyNames: busy.map(\.displayName),
            busyStatus: busy.first.map(\.statusLine),
            benchmarkTitle: BenchmarkRunLogic.collapsedTitle(activity.benchmark),
            // Gate socket only — matches hubStatusBadge / GateHealth.socketUp.
            hubReady: HubScanLine.isHubReady(
                gateSocketUp: activity.gateAvailable,
                bridgeConnected: bridge.connected
            )
        )
    }

    private var hubStatusText: String { gateHealth.label }

    private var hubStatusBadge: some View {
        let ok = gateHealth.socketUp
        return HStack(spacing: 4) {
            Circle()
                .fill(ok ? Color.shannonSuccess : Color.shannonError)
                .frame(width: 6, height: 6)
                .shadow(
                    color: (ok ? Color.shannonSuccess : Color.shannonError).opacity(0.6),
                    radius: 3
                )
            Text(gateHealth.label)
                .font(.shannonMenuMono)
                .foregroundStyle(ok ? Color.shannonSuccess : Color.shannonError)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(
            ok ? Color.shannonSuccess.opacity(0.12) : Color.shannonError.opacity(0.12)
        ))
        .overlay(Capsule().strokeBorder(
            ok ? Color.shannonSuccess.opacity(0.35) : Color.shannonError.opacity(0.35),
            lineWidth: 1
        ))
        .help(ok
              ? "Gate socket reachable — \(gateHealth.label)"
              : "Gate socket missing — start the hub to answer approvals")
        .accessibilityLabel(hubStatusText)
    }

    private var firstRunTips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Getting started")
                .font(.shannonMenuBody)
                .foregroundStyle(Color.shannonPrimary)
            ForEach(FirstRunCoach.steps, id: \.rawValue) { step in
                Text("• \(FirstRunCoach.tip(for: step))")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Got it") {
                FirstRunCoach.markDone()
                showFirstRun = false
            }
            .font(.shannonMenuBody)
            .buttonStyle(.plain)
            .foregroundStyle(Color.shannonAccent)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.shannonAccent.opacity(0.08)))
    }

    // MARK: FlexAIDdS / DatasetRunner benchmark (agentic hub)

    /// Honest hub progress for concurrent FlexAIDdS success-rate work.
    /// Empty when the gate has no `benchmark_state` row (or it is stale).
    @ViewBuilder
    private var benchmarkSection: some View {
        if let run = activity.benchmark, BenchmarkRunLogic.shouldShowCard(run) {
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("FlexAIDdS benchmark")
                HStack(spacing: 8) {
                    Image(systemName: run.isComplete ? "checkmark.seal.fill" : "chart.bar.doc.horizontal")
                        .font(.shannonMenuBody)
                        .foregroundStyle(run.isComplete ? Color.shannonSuccess : Color.shannonAccent)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.displayName)
                            .font(.shannonMenuBody)
                            .foregroundStyle(Color.shannonPrimary)
                            .lineLimit(1)
                        Text(run.shortLabel)
                            .font(.shannonMenuMono)
                            .foregroundStyle(Color.shannonSecondary)
                            .lineLimit(1)
                            .contentTransition(.identity)
                    }
                    Spacer(minLength: 4)
                    // Progress ring fraction (completed/total only — not invented S).
                    ZStack {
                        Circle()
                            .stroke(Color.shannonNeutral.opacity(0.25), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: CGFloat(run.fraction))
                            .stroke(Color.shannonAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(run.countLabel)
                            .font(.shannonMenuMono)
                            .foregroundStyle(Color.shannonPrimary)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: 40, height: 40)
                    .accessibilityLabel("Progress \(run.countLabel)")
                }
                if let t = run.activeTarget, !run.isComplete {
                    Text("Active · \(t)")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Benchmark \(run.shortLabel)")
        }
    }

    // MARK: Keep awake (native caffeinate-class — no Amphetamine required)

    /// Primary: IOPMAssertion / `caffeinate -dims` style idle+display hold.
    private var keepAwakeSection: some View {
        let s = keepAwake.session
        return VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Keep awake")
            HStack(spacing: 8) {
                Image(systemName: s.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.shannonMenuBody)
                    .foregroundStyle(s.isActive ? Color.shannonWarning : Color.shannonTertiary)
                    .frame(width: 14)
                Text(s.shortLabel)
                    .font(.shannonMenuMono)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
                    .help(s.detail ?? "Prevents system idle sleep (and display sleep) like caffeinate -dims while agents run.")
                Spacer(minLength: 4)
                if s.isActive {
                    Button("End") { keepAwake.endSession() }
                        .font(.shannonMenuBody)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.shannonAccent)
                } else {
                    Button("Start 2h") { keepAwake.startSession(durationHours: 2.0) }
                        .font(.shannonMenuBody)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.shannonAccent)
                }
            }
            .frame(height: 16)
            Toggle(isOn: $keepAwake.autoKeepAwakeWithAgents) {
                Text("Auto while agents busy")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonTertiary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            Text("Native caffeinate-class hold · Amphetamine not required.")
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonTertiary)
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.shortLabel)
    }

    // MARK: System resources (CPU / GPU / RAM / SSD / Temp) — iStat-style

    @State private var showPerCoreDetail = false

    /// Color-coded gauges ordered **most constrained first**, plus per-core
    /// bars and sparklines. SSD + thermal join CPU/GPU/RAM.
    private var resourcesSection: some View {
        let snap = resources.snapshot
        let hist = resources.history
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle("System")
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

            // Rows in most-constrained-first order (not fixed CPU→GPU→RAM).
            ForEach(resourceRowsOrdered(snap: snap, hist: hist), id: \.kind) { row in
                resourceRow(
                    kind: row.kind,
                    percent: row.percent,
                    detail: row.detail,
                    history: row.history
                )
            }

            // Per-core bar strip (iStat-style)
            if !snap.cpuCores.isEmpty {
                perCoreStrip(snap.cpuCores, imbalance: snap.coreImbalance)
                if showPerCoreDetail {
                    perCoreDetailTable(snap.cpuCores)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(resourcesAccessibilityLabel(snap))
    }

    private struct ResourceRowModel {
        var kind: SystemResourceSnapshot.Kind
        var percent: Double?
        var detail: String?
        var history: [Double]
    }

    /// Stable row order (CPU → GPU → RAM → SSD → Temp).
    ///
    /// Most-constrained is called out in the section header — re-sorting rows
    /// every 0.75 s sample made the popover jump and "pop" during refresh.
    private func resourceRowsOrdered(
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

    private func cpuAggregateDetail(_ snap: SystemResourceSnapshot) -> String? {
        guard snap.cpuCoreCount > 0 else { return nil }
        if let imb = snap.coreImbalance, imb >= 20 {
            return String(format: "%d-core · Δ%.0f", snap.cpuCoreCount, imb)
        }
        return "\(snap.cpuCoreCount)-core"
    }

    private func ramDetail(_ snap: SystemResourceSnapshot) -> String? {
        guard let u = snap.ramUsedGB, let t = snap.ramTotalGB, t > 0 else { return nil }
        return String(format: "%.1f / %.0f GB", u, t)
    }

    private func diskDetail(_ snap: SystemResourceSnapshot) -> String? {
        if let free = snap.diskFreeGB, let total = snap.diskTotalGB, total > 0 {
            return String(format: "%.0f GB free", free)
        }
        if let u = snap.diskUsedGB, let t = snap.diskTotalGB, t > 0 {
            return String(format: "%.0f / %.0f GB", u, t)
        }
        return snap.diskPercent == nil ? "n/a" : nil
    }

    private func thermalDetail(_ snap: SystemResourceSnapshot) -> String? {
        if let t = snap.temperatureCelsius {
            return String(format: "%.0f°C · %@", t, snap.thermal?.label ?? "?")
        }
        return snap.thermal?.label ?? "n/a"
    }

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
            // Smooth fill only — fixed row height; parent layout stays put.
            SmoothLoadBar(
                percent: pct,
                tint: tint,
                isPlaceholder: percent == nil,
                reduceMotion: reduceMotion
            )
            .frame(height: 7)
            // Always reserve sparkline slot so history growth never shifts rows.
            Group {
                if history.count >= 2 {
                    SparklineView(values: history, tint: tint)
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
            // Fixed detail width so "16-core · Δ25" appearing does not reflow.
            Text(detail == "n/a" ? "" : (detail ?? ""))
                .font(.shannonMenuMono)
                .foregroundStyle(Color.shannonTertiary)
                .lineLimit(1)
                .frame(minWidth: 52, alignment: .leading)
                .opacity((detail == nil || detail == "n/a") ? 0 : 1)
        }
        .frame(height: 16)
    }

    /// Vertical bars for each logical core — color by absolute load, height by %.
    /// Fixed strip height so core-count / load ticks never reflow the footer.
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
                        SmoothCoreBar(
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
            // Flatten core strip into one layer — fewer frame tears on 120 Hz.
            .compositingGroup()
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.shannonNeutral.opacity(0.12))
            )
        }
    }

    /// Table: each core vs average (relative performance).
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

    /// Continuous scarcity ink — intensity scales with percent; red only at critical.
    private func resourceTint(percent: Double?) -> Color {
        let c = ResourceScarcityTint.sRGB(percent: percent)
        return Color(red: c.r, green: c.g, blue: c.b).opacity(c.a)
    }

    private func resourcesAccessibilityLabel(_ snap: SystemResourceSnapshot) -> String {
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

    // MARK: Agents

    /// Roster rows for the popover: busy first, then connected/live, cap at 3
    /// so the menu does not balloon with stale offline host ghosts.
    private var agentRows: [AgentActivitySnapshot] {
        if !busy.isEmpty { return Array(busy.prefix(3)) }
        let live = summary.agents.filter { agent in
            // Prefer process-live / connected over long-offline noise.
            let line = agent.statusLine.lowercased()
            if line.contains("offline") { return false }
            return true
        }
        return Array((live.isEmpty ? summary.agents : live).prefix(3))
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(busy.isEmpty ? "Agents" : "Active now")
            if busy.isEmpty && summary.agents.isEmpty {
                Text("No agents. ⌘D attaches the front app · DatasetRunner fills FlexAIDdS progress.")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(2)
                    .frame(minHeight: 28, alignment: .topLeading)
            } else {
                ForEach(agentRows) { agent in
                    agentRow(agent)
                }
                let hidden = max(0, (busy.isEmpty ? summary.agents.count : busy.count) - agentRows.count)
                if hidden > 0 {
                    Text("+\(hidden) more")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
        }
    }

    private func agentRow(_ a: AgentActivitySnapshot) -> some View {
        let style = AgentStyleCatalog.style(for: a.id)
        let agentReading = agentReadings[a.id]
            ?? EntropyProvenance.resolveForAgent(
                agentId: a.id,
                bridgeConnected: bridge.connected,
                bridgeStatus: bridge.status,
                gate: activity.agentEntropy,
                gateDBAvailable: activity.gateDBAvailable
            )
        return HStack(spacing: 7) {
            Text(style.emoji).font(.shannonMenuBody)
            Text(style.displayName)
                .font(.shannonMenuBody)
                .foregroundStyle(style.palette.ink)
                .lineLimit(1)
            // `statusLine`, not `status.label`: an agent that vanished two days
            // ago used to render the bare word "idle", which reads as "present
            // and waiting". This says "offline · last seen 2d".
            Text(a.statusLine)
                .font(.shannonMenuSection)
                .foregroundStyle(style.palette.ink)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(style.palette.wash))
            Spacer(minLength: 4)
            agentEntropyLabel(agentReading)
            Text(a.relativeAge)
                .font(.shannonMenuMono)
                .foregroundStyle(Color.shannonTertiary)
                .frame(minWidth: 28, alignment: .trailing)
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(style.displayName), \(a.statusLine), \(agentReading.explain(at: Date())), \(a.relativeAge)"
        )
    }

    @ViewBuilder
    private func agentEntropyLabel(_ reading: EntropyReading) -> some View {
        if let display = reading.display(at: Date()) {
            Text(display.shortLabel)
                .font(.shannonMenuMono)
                .foregroundStyle(entropyTint(reading))
                .help(reading.explain(at: Date()))
        } else {
            Text("—")
                .font(.shannonMenuMono)
                .foregroundStyle(Color.shannonNeutral)
                .help(reading.explain(at: Date()))
        }
    }

    // MARK: Abandoned approvals

    /// Asks whose requesting agent disconnected after creating them.
    ///
    /// These look identical to live approvals in the raw table, but answering
    /// one changes nothing — there is no process left listening for the reply.
    /// Saying so is the difference between "you have work to do" and "this queue
    /// is stale"; without it a pile of dead rows reads as urgent.
    @ViewBuilder
    private var staleAskNotice: some View {
        let n = activity.staleAsks.count
        if n > 0 {
            HStack(spacing: 5) {
                Image(systemName: "clock.badge.xmark")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonNeutral)
                Text(n == 1
                     ? "1 abandoned approval — requester disconnected"
                     : "\(n) abandoned approvals — requesters disconnected")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonNeutral)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help("These asks have no process waiting on an answer. Answering them has no effect.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(n) abandoned approvals, requesting agents disconnected")
        }
    }

    // MARK: Recent activity

    /// Real events from the gate's `agent_activity` table, newest first.
    ///
    /// This was previously the *agent roster* re-sorted by `updatedAt` — five
    /// rows that restated who exists rather than what happened, so the same
    /// agent could occupy every line and a burst of real activity was invisible.
    /// `AgentActivityMonitor.recentActivity` reads the actual event rows.
    private var recentEvents: [GateDBReader.ActivityEvent] {
        activity.recentActivity
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recentEvents.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("Recent activity")
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recentEvents) { e in
                            eventRow(e)
                        }
                    }
                }
                .frame(maxHeight: 84)
                .accessibilityLabel("Recent activity, last \(recentEvents.count) events")
            }
        }
    }

    private func eventRow(_ e: GateDBReader.ActivityEvent) -> some View {
        let style = AgentStyleCatalog.style(for: e.agentId)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(e.relativeAge)
                .font(.shannonMenuMono)
                .foregroundStyle(Color.shannonTertiary)
                .frame(width: 34, alignment: .trailing)
            Text("\(style.displayName): \(AgentActivitySnapshot.shorten(e.line, max: 46))")
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(e.relativeAge) ago, \(style.displayName), \(e.line)")
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.shannonMenuSection)
            .foregroundStyle(Color.shannonSecondary)
            .tracking(0.8)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Entropy readout

    /// Renders the reading, never a substitute for one.
    ///
    /// - `.measured` → `H 2.86`, tinted by verdict.
    /// - `.stale` under observe mode → `H⌛ 2.86` in neutral, with the age in
    ///   the tooltip. Under enforce mode it falls through to the absent form.
    /// - `.absent` → the words "no detector", never a digit.
    @ViewBuilder
    private var entropyReadout: some View {
        let reading = self.reading
        if let display = reading.display(at: Date()) {
            Text(String(format: "%@ %.2f", display.badge, display.bits))
                .font(.shannonMenuMono)
                .foregroundStyle(entropyTint(reading))
                .contentTransition(.identity)
                .help(reading.explain(at: Date()))
        } else {
            Text("no detector")
                .font(.shannonMenuMono)
                .foregroundStyle(Color.shannonNeutral)
                .help(reading.explain(at: Date()))
        }
    }

    /// Continuous multi-stop gradient over measured H (not discrete RYG).
    private func entropyTint(_ reading: EntropyReading) -> Color {
        if let display = reading.display(at: Date()) {
            let rgb = display.gaugeColorRGB()
            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
        return .shannonNeutral
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status row: H · battery · focus — fixed single line, no wrap smash.
            HStack(spacing: 6) {
                entropyReadout
                    .layoutPriority(1)
                Text("·")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonTertiary)
                if let snap = battery.snapshot {
                    HStack(spacing: 2) {
                        Image(systemName: snap.isCharging ? "battery.100.bolt" : "battery.75")
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonTertiary)
                            .symbolRenderingMode(.hierarchical)
                        Text("\(snap.percentage)%")
                            .font(.shannonMenuMono)
                            .foregroundStyle(Color.shannonTertiary)
                            .contentTransition(.identity)
                            .frame(minWidth: 28, alignment: .trailing)
                    }
                    .layoutPriority(0)
                }
                Text("·")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonTertiary)
                Text(focusMode.shortLabel)
                    .font(.shannonMenuMono)
                    .foregroundStyle(focusMode.state == .on ? Color.shannonAccent : Color.shannonTertiary)
                    .lineLimit(1)
                    .help("Best-effort Focus/DND from local Assertions.json (BLOCKED.md §2)")
                Spacer(minLength: 4)
            }
            .frame(height: 14)

            HStack(spacing: 6) {
                Text(multiDeviceFooterLine)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityLabel(multiDeviceFooterLine)
                Spacer(minLength: 4)
                footerIconButton("doc.text", label: "Open hub log", action: onOpenHubLog)
                footerIconButton("gearshape", label: "Settings", action: onOpenSettings)
                // Labeled Quit — power-only glyph was easy to miss and sat on a
                // moving footer when content reflowed. Fixed chrome + text keeps
                // it under the cursor and readable.
                quitButton
            }
            .frame(height: 26)
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.12),
                    Color.clear,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.5)
            .offset(y: -8)
        }
    }

    /// Explicit "Quit" control — stable hit target, no icon-only ambiguity.
    private var quitButton: some View {
        Button(action: onQuit) {
            HStack(spacing: 4) {
                Image(systemName: "power")
                    .font(.shannonMenuBody)
                Text("Quit")
                    .font(.shannonMenuBody)
            }
            .foregroundStyle(Color.shannonSecondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(ShannonQuietButtonStyle())
        .help("Quit Shannon")
        .accessibilityLabel("Quit Shannon")
        .accessibilityHint("Quits the Shannon menu bar app")
    }

    /// Honest multi-device path from CloudPublisher (P2.7).
    private var multiDeviceFooterLine: String {
        switch multiDeviceStatus {
        case "on":
            return "Multi-device: on (iCloud)"
        case "off":
            return "Multi-device: off"
        default:
            return "Multi-device: in-memory"
        }
    }

    private func footerIconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.shannonMenuBody)
                .foregroundStyle(Color.shannonSecondary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(ShannonQuietButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Quiet press feedback for popover chrome.
///
/// No scaleEffect — scaling the Quit control made the hit target shrink under
/// the cursor and felt like the button was "escaping" mid-click.
private struct ShannonQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .animation(nil, value: configuration.isPressed)
    }
}

// MARK: - Smooth gauges (local fill motion only)

/// Horizontal load bar whose **width** eases without reflowing the popover.
private struct SmoothLoadBar: View {
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
                    // Scoped liquid ease — parent transaction kills layout morphs.
                    .transaction { txn in
                        txn.animation = reduceMotion ? nil : .shannonLiquid
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One per-core column; height eases independently of popover chrome.
private struct SmoothCoreBar: View {
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

// MARK: - Sparkline

/// Tiny line chart for recent utilisation history (iStat-style).
private struct SparklineView: View {
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

// MARK: - GateInlineCard

/// The newest pending gate approval, answerable without leaving the popover.
/// While the write is in flight the buttons give way to a spinner (no double
/// resolution); a failed write leaves the ask in place with the error inline.
struct GateInlineCard: View {
    let ask: GateDBReader.PendingAsk
    let isResolving: Bool
    let error: String?
    let extraPending: Int
    let onAnswer: (Bool) -> Void
    let onShowAll: () -> Void

    private var style: AgentStyle { AgentStyleCatalog.style(for: ask.agentId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(style.emoji).font(.shannonMenuBody)
                Text(style.displayName)
                    .font(.shannonMenuBody)
                    .foregroundStyle(style.palette.ink)
                Text("needs approval")
                    .font(.shannonMenuSection)
                    .foregroundStyle(Color.shannonWarning)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.shannonWarning.opacity(0.18)))
                Spacer(minLength: 0)
            }

            Text(ask.prompt)
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonError)
                    .lineLimit(2)
                    .accessibilityLabel("Approval error: \(error)")
            }

            HStack(spacing: 8) {
                if isResolving {
                    ProgressView().controlSize(.small)
                    Text("Sending to gate…")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonSecondary)
                } else {
                    answerButton("Approve", systemImage: "checkmark", tint: .shannonSuccess) {
                        onAnswer(true)
                    }
                    answerButton("Deny", systemImage: "xmark", tint: .shannonError) {
                        onAnswer(false)
                    }
                }
                Spacer(minLength: 0)
                if extraPending > 0 {
                    Button(action: onShowAll) {
                        Text("+\(extraPending) more")
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonAccent)
                    }
                    .buttonStyle(.plain)
                    .help("Show all pending gates")
                    .accessibilityLabel("\(extraPending) more pending gates. Show all.")
                }
            }
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.shannonWarning.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.shannonWarning.opacity(0.38), lineWidth: 1)
                }
                .shadow(color: Color.shannonWarning.opacity(0.12), radius: 8, y: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(style.displayName) needs approval: \(ask.prompt)")
    }

    private func answerButton(
        _ title: String, systemImage: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.shannonMenuBody)
                    .symbolRenderingMode(.hierarchical)
                Text(title).font(.shannonMenuBody)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(tint))
            .foregroundStyle(.white)
        }
        .buttonStyle(ShannonQuietButtonStyle())
        .help("\(title) this request")
        .accessibilityLabel("\(title) \(style.displayName)'s request")
    }
}
