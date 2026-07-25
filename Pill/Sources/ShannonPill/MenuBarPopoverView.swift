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
        VStack(alignment: .leading, spacing: 10) {
            header
            if showFirstRun && summary.agents.isEmpty {
                firstRunTips
                    .shannonGlassSection(emphasized: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            resourcesSection
                .shannonGlassSection()
            keepAwakeSection
                .shannonGlassSection()
            agentSection
                .shannonGlassSection()
            staleAskNotice
            recentSection
            footer
                .padding(.top, 2)
        }
        .animation(.shannon(reduceMotion ? .linear(duration: 0) : .shannonEase, reduceMotion: reduceMotion),
                   value: activity.pendingAsks.count)
        .animation(.shannon(.shannonEase, reduceMotion: reduceMotion), value: summary.busyCount)
        .onChange(of: activity.summary.busyCount) { count in
            keepAwake.syncWithAgents(busyCount: count)
        }
        .padding(14)
        // Fixed width + intrinsic height so the popover does not stretch or
        // shift when agent/footer content wraps.
        .frame(width: 308, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: true)
        // Liquid Glass stack for macOS 27: `.popover` material (matches system
        // menus) + light indigo tint + top specular so it reads as refractive
        // glass rather than a flat dark slab.
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
        // Keep the popover locked to dark mode regardless of system appearance.
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: collapseAlarm ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(collapseAlarm ? Color.shannonError : Color.shannonAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Shannon")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.shannonPrimary)
                Text(headerSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
            }
            Spacer()
            hubStatusBadge
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shannon. \(headerSubtitle). \(hubStatusText)")
    }

    private var headerSubtitle: String {
        // `collapseAlarm` is only true for `.measured`, so `measurement` is
        // non-nil here; the `if let` is belt-and-braces rather than an excuse to
        // print a number from a reading that has none.
        if collapseAlarm, let m = reading.measurement {
            let delta = m.deltaH.map { String(format: ", ΔH %+.1f", $0) } ?? ""
            return String(format: "Entropy collapse — H %.1f%@", m.bits, delta)
        }
        if busy.isEmpty { return "No agents busy" }
        if busy.count == 1, let p = busy.first { return "\(p.displayName) · \(p.statusLine)" }
        return "\(busy.count) agents active"
    }

    /// Hub = gate socket + bridge. The socket is what approvals travel over,
    /// so its presence is the honest "can I actually answer gates" signal.
    private var hubConnected: Bool { activity.gateAvailable || bridge.connected }

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
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.shannonPrimary)
            ForEach(FirstRunCoach.steps, id: \.rawValue) { step in
                Text("• \(FirstRunCoach.tip(for: step))")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.shannonSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Got it") {
                FirstRunCoach.markDone()
                showFirstRun = false
            }
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.shannonAccent)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.shannonAccent.opacity(0.08)))
    }

    // MARK: Keep awake (native caffeinate-class — no Amphetamine required)

    /// Primary: IOPMAssertion / `caffeinate -dims` style idle+display hold.
    private var keepAwakeSection: some View {
        let s = keepAwake.session
        return VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Keep awake")
            HStack(spacing: 8) {
                Image(systemName: s.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(s.isActive ? Color.shannonWarning : Color.shannonTertiary)
                    .frame(width: 14)
                Text(s.shortLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
                    .help(s.detail ?? "Prevents system idle sleep (and display sleep) like caffeinate -dims while agents run.")
                Spacer(minLength: 4)
                if s.isActive {
                    Button("End") { keepAwake.endSession() }
                        .font(.system(size: 10, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.shannonAccent)
                } else {
                    Button("Start 2h") { keepAwake.startSession(durationHours: 2.0) }
                        .font(.system(size: 10, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.shannonAccent)
                }
            }
            .frame(height: 16)
            Toggle(isOn: $keepAwake.autoKeepAwakeWithAgents) {
                Text("Auto while agents busy")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.shannonTertiary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            Text("Native: no idle/display sleep (caffeinate-class). Amphetamine not required.")
                .font(.system(size: 8.5))
                .foregroundStyle(Color.shannonTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(resourceTint(SystemResourceLogic.band(for: top.percent)))
                } else if let hot = snap.hottestCore, snap.cpuCoreCount > 1 {
                    Text(String(format: "C%d · %.0f%%", hot.index, hot.percent))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(resourceTint(SystemResourceLogic.band(for: hot.percent)))
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

    /// Build gauge rows sorted by current pressure (most constrained first).
    private func resourceRowsOrdered(
        snap: SystemResourceSnapshot,
        hist: SystemResourceHistory
    ) -> [ResourceRowModel] {
        let specs: [(SystemResourceSnapshot.Kind, Double?, String?, [Double])] = [
            (.cpu, snap.cpuPercent, cpuAggregateDetail(snap), hist.cpu),
            (.gpu, snap.gpuPercent, snap.gpuPercent == nil ? "n/a" : nil, hist.gpu),
            (.ram, snap.ramPercent, ramDetail(snap), hist.ram),
            (.disk, snap.diskPercent, diskDetail(snap), hist.disk),
            (.thermal, snap.thermal.map(\.pressurePercent), thermalDetail(snap), []),
        ]
        // Rank by live pressure; unknowns sink to the bottom (stable kind order).
        let rank = Dictionary(
            uniqueKeysWithValues: snap.constrainedRanked.enumerated().map { ($0.element.kind, $0.offset) }
        )
        return specs
            .map { ResourceRowModel(kind: $0.0, percent: $0.1, detail: $0.2, history: $0.3) }
            .sorted { a, b in
                let ra = rank[a.kind] ?? 1000
                let rb = rank[b.kind] ?? 1000
                if ra != rb { return ra < rb }
                return a.kind.rawValue < b.kind.rawValue
            }
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
        let band = percent.map { SystemResourceLogic.band(for: $0) } ?? .calm
        let tint = resourceTint(band)
        let label = percent.map { String(format: "%.0f%%", $0) } ?? (detail == "n/a" ? "—" : "…")
        return HStack(spacing: 6) {
            Image(systemName: kind == .gpu ? "cube" : kind.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(kind.shortLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.shannonSecondary)
                .frame(width: 36, alignment: .leading)
            // Horizontal load bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.shannonNeutral.opacity(0.22))
                    Capsule()
                        .fill(tint.opacity(percent == nil ? 0.12 : 0.9))
                        .frame(width: max(3, geo.size.width * CGFloat(pct / 100)))
                        .animation(.shannonLiquid, value: pct)
                }
            }
            .frame(height: 7)
            // Mini sparkline (history)
            if history.count >= 2 {
                SparklineView(values: history, tint: tint)
                    .frame(width: 36, height: 14)
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(.shannonLiquid, value: label)
            if let detail, detail != "n/a" {
                Text(detail)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(1)
            }
        }
        .frame(height: 16)
    }

    /// Vertical bars for each logical core — color by absolute load, height by %.
    private func perCoreStrip(_ cores: [CPUCoreLoad], imbalance: Double?) -> some View {
        let tall = cores.count > 10 ? CGFloat(22) : CGFloat(28)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("CORES")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.shannonTertiary)
                    .tracking(0.6)
                if let imb = imbalance {
                    Text(String(format: "spread %.0fpp", imb))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(imb >= 25 ? Color.shannonWarning : Color.shannonTertiary)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.shannonEase) {
                        showPerCoreDetail.toggle()
                    }
                } label: {
                    Text(showPerCoreDetail ? "hide" : "vs peers")
                        .font(.system(size: 8.5, weight: .semibold))
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
                        let band = SystemResourceLogic.band(for: core.percent)
                        let tint = resourceTint(band)
                        let h = max(2, geo.size.height * CGFloat(core.percent / 100))
                        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                            .fill(tint.opacity(core.isHotRelative ? 1.0 : 0.75))
                            .frame(width: barW, height: h)
                            .overlay(alignment: .top) {
                                if core.isBusiest && core.percent >= 15 {
                                    Circle()
                                        .fill(Color.white.opacity(0.7))
                                        .frame(width: 2.5, height: 2.5)
                                        .offset(y: -3)
                                }
                            }
                            .help(coreHelp(core))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: tall)
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
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.shannonTertiary)

            ForEach(sorted.prefix(12)) { core in
                let tint = resourceTint(SystemResourceLogic.band(for: core.percent))
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
                .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            if cores.count > 12 {
                Text("… \(cores.count - 12) more cores")
                    .font(.system(size: 8))
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

    private func resourceTint(_ band: SystemResourceLogic.Band) -> Color {
        // Never use ask-amber (warning) for host load — reserved for approvals.
        switch band {
        case .calm:
            return Color(red: 0.35, green: 0.78, blue: 0.52) // iStat green
        case .elevated:
            return .shannonAccent
        case .hot:
            return Color(red: 0.95, green: 0.72, blue: 0.25) // gold load, not ask amber
        case .critical:
            return .shannonError
        }
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
                Text("Nothing running. Press ⌘D to attach the front app as an agent.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.shannonTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(agentRows) { agent in
                    agentRow(agent)
                }
                let hidden = max(0, (busy.isEmpty ? summary.agents.count : busy.count) - agentRows.count)
                if hidden > 0 {
                    Text("+\(hidden) more")
                        .font(.system(size: 9))
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
            Text(style.emoji).font(.system(size: 12))
            Text(style.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.palette.ink)
            // `statusLine`, not `status.label`: an agent that vanished two days
            // ago used to render the bare word "idle", which reads as "present
            // and waiting". This says "offline · last seen 2d".
            Text(a.statusLine)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(style.palette.ink)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(style.palette.wash))
            Spacer(minLength: 4)
            agentEntropyLabel(agentReading)
            Text(a.relativeAge)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.shannonTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(style.displayName), \(a.statusLine), \(agentReading.explain(at: Date())), \(a.relativeAge)"
        )
    }

    @ViewBuilder
    private func agentEntropyLabel(_ reading: EntropyReading) -> some View {
        if let display = reading.display(at: Date()) {
            Text(display.shortLabel)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(entropyTint(reading))
                .help(reading.explain(at: Date()))
        } else {
            Text("—")
                .font(.system(size: 9, design: .monospaced))
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
                    .font(.system(size: 9))
                    .foregroundStyle(Color.shannonNeutral)
                Text(n == 1
                     ? "1 abandoned approval — requester disconnected"
                     : "\(n) abandoned approvals — requesters disconnected")
                    .font(.system(size: 9.5))
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
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Color.shannonTertiary)
                .frame(width: 34, alignment: .trailing)
            Text("\(style.displayName): \(AgentActivitySnapshot.shorten(e.line, max: 46))")
                .font(.system(size: 10))
                .foregroundStyle(Color.shannonSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(e.relativeAge) ago, \(style.displayName), \(e.line)")
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 9, weight: .heavy, design: .rounded))
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
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(entropyTint(reading))
                .contentTransition(.numericText())
                .animation(.shannonLiquid, value: display.bits)
                .help(reading.explain(at: Date()))
        } else {
            Text("no detector")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
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
        VStack(alignment: .leading, spacing: 6) {
            // Status row: H · battery · focus — fixed single line, no wrap smash.
            HStack(spacing: 6) {
                entropyReadout
                    .layoutPriority(1)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.shannonTertiary)
                if let snap = battery.snapshot {
                    HStack(spacing: 2) {
                        Image(systemName: snap.isCharging ? "battery.100.bolt" : "battery.75")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.shannonTertiary)
                            .symbolRenderingMode(.hierarchical)
                        Text("\(snap.percentage)%")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.shannonTertiary)
                            .contentTransition(.numericText())
                    }
                    .layoutPriority(0)
                }
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.shannonTertiary)
                Text(focusMode.shortLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(focusMode.state == .on ? Color.shannonAccent : Color.shannonTertiary)
                    .lineLimit(1)
                    .help("Best-effort Focus/DND from local Assertions.json (BLOCKED.md §2)")
                Spacer(minLength: 4)
            }
            .frame(height: 14)

            HStack(spacing: 4) {
                Text(multiDeviceFooterLine)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityLabel(multiDeviceFooterLine)
                Spacer(minLength: 4)
                footerButton("doc.text", label: "Open hub log", action: onOpenHubLog)
                footerButton("gearshape", label: "Settings", action: onOpenSettings)
                footerButton("power", label: "Quit Shannon", action: onQuit)
            }
            .frame(height: 22)
        }
        .padding(.top, 6)
        .overlay(alignment: .top) {
            // Hairline separator — glass-friendly (no full Divider slab).
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
        }
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

    private func footerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.shannonSecondary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 26, height: 22)
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

/// Quiet press scale for popover chrome (Liquid Glass micro-interaction).
private struct ShannonQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.shannonSnap, value: configuration.isPressed)
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
                Text(style.emoji).font(.system(size: 13))
                Text(style.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(style.palette.ink)
                Text("needs approval")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.shannonWarning)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.shannonWarning.opacity(0.18)))
                Spacer(minLength: 0)
            }

            Text(ask.prompt)
                .font(.system(size: 11))
                .foregroundStyle(Color.shannonPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.shannonError)
                    .lineLimit(2)
                    .accessibilityLabel("Approval error: \(error)")
            }

            HStack(spacing: 8) {
                if isResolving {
                    ProgressView().controlSize(.small)
                    Text("Sending to gate…")
                        .font(.system(size: 10))
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
                            .font(.system(size: 9, weight: .medium))
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
                    .font(.system(size: 9, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                Text(title).font(.system(size: 10.5, weight: .semibold))
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
