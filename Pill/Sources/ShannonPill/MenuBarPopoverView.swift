import SwiftUI
import AppKit
import PillCore
import DevServers
import Routes

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

    /// Minimum Quit hit target — wide enough for the power glyph + "Quit" label
    /// and never compressed by a long multi-device footer line.
    static let quitMinWidth: CGFloat = 58
    static let quitMinHeight: CGFloat = 26

    /// Footer action row height (icons + Quit). Fixed so status ticks above
    /// cannot reflow the hit targets.
    static let footerActionRowHeight: CGFloat = 26

    /// Shipped popover content size. Controllers must use this instead of
    /// SwiftUI intrinsic size so live body growth never resizes chrome.
    static var fixedContentSize: CGSize {
        CGSize(width: chromeWidth, height: chromeHeight)
    }

    /// Ignore thrash-driven intrinsic proposals — always pin to fixed chrome.
    ///
    /// Called when the hosting controller or popover would otherwise adopt a
    /// content-sized frame after a metric tick. Wild widths/heights (empty
    /// body, huge agent list) must not move the Quit affordance.
    static func clampedContentSize(proposed: CGSize) -> CGSize {
        // Intentional: discard `proposed` — fixed chrome is the product rule.
        _ = proposed
        return fixedContentSize
    }

    @ObservedObject var activity: AgentActivityMonitor
    @ObservedObject var bridge: ShannonBridge
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var resources: SystemResourceMonitor
    @ObservedObject var keepAwake: KeepAwakeMonitor
    @ObservedObject var focusMode: FocusModeMonitor
    /// Cloud multi-device honesty: `"on"` / `"in-memory"` / `"off"`.
    var multiDeviceStatus: String = "in-memory"
    /// Additive AgentPeek-parity surfaces (sessions / servers / routes).
    @ObservedObject var parity: ParityPanelModel

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

    /// Best session per agent id (project / branch / model / tokens when real).
    ///
    /// Built from gate + artifact during parity collect (ENH-003) — not artifact-only.
    private var sessionsByAgentId: [String: AgentSession] {
        parity.sessionsByAgent
    }

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
                            gateAvailable: activity.gateAvailable,
                            extraPending: max(0, activity.pendingAsks.count - 1),
                            onAnswer: { approved in
                                Task { await activity.resolve(ask, approved: approved) }
                            },
                            onShowAll: onShowAllGates
                        )
                        // Stable id so only ask *identity* changes swap the card.
                        .id(ask.interactionId)
                    }
                    MenuBarResourcesSection(resources: resources)
                        .shannonGlassSection()
                    if BenchmarkRunLogic.shouldShowCard(activity.benchmark) {
                        benchmarkSection
                            .shannonGlassSection(
                                emphasized: activity.benchmark.map { !$0.isComplete } ?? false
                            )
                    }
                    keepAwakeSection
                        .shannonGlassSection()
                    MenuBarAgentRoster(
                        activity: activity,
                        bridge: bridge,
                        agentReadings: agentReadings,
                        entropyTint: entropyTint,
                        sessionsByAgent: sessionsByAgentId
                    )
                        .shannonGlassSection()
                    PulledSessionsSection(
                        sessions: parity.sessions,
                        pendingAsks: activity.pendingAsks,
                        activity: activity.recentActivity,
                        liveAgentIds: Set(summary.agents.map(\.id)),
                        onJumpToHost: { input in
                            // ENH-028: pure policy + NSWorkspace activate / open cwd.
                            _ = HostTerminalJumpExecutor.jump(input: input)
                        },
                        onOpenTerminalHere: { input in
                            // ENH-029: pure policy + NSWorkspace open dir with terminal app.
                            _ = OpenTerminalHereExecutor.open(input: input)
                        }
                    )
                        .shannonGlassSection()
                    DevServersSection(
                        servers: parity.servers,
                        onOpen: { s in
                            if let url = DevServerDiscovery.openURL(for: s) {
                                NSWorkspace.shared.open(url)
                            }
                        },
                        onCopy: { s in
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(s.url, forType: .string)
                        },
                        onStop: { s in
                            _ = DevServerDiscovery.stop(s)
                            parity.refresh(gateAgents: summary.agents, force: true)
                        }
                    )
                    .shannonGlassSection()
                    QuickRoutesSection(routes: parity.routes) { route in
                        NSWorkspace.shared.open(URL(fileURLWithPath: route.path))
                    }
                    .shannonGlassSection()
                    FastActionsSection(
                        actions: parity.actions,
                        status: parity.lastActionStatus,
                        error: parity.lastActionError,
                        onRun: { parity.runAction($0) }
                    )
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
        .onAppear {
            // Full Claude/Codex scan on open; visibility drives closed throttle (ENH-008).
            parity.panelVisible = true
            parity.refresh(gateAgents: summary.agents, force: true)
        }
        .onDisappear {
            // Reused popover hosting still receives agent-count onChange when
            // closed — gate-only / 15s path kicks in until next open.
            parity.panelVisible = false
        }
        .onChange(of: activity.summary.agents.count) { _ in
            parity.refresh(gateAgents: summary.agents)
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
                // UX-025: brand title shares Core quietShort (pill/watch parity).
                Text(CompanionFocusCopy.quietShort)
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
        .accessibilityLabel(
            "\(CompanionFocusCopy.quietShort). \(headerSubtitle). \(hubStatusText)"
        )
    }

    /// One-line founder scan: collapse > busy agents > live FlexAIDdS run > hub state.
    private var headerSubtitle: String {
        // Prefer live AgentNotch-class focus (needs-you / tool activity).
        if let focus = AgentLiveSurfaceLogic.primaryFocus(
            agents: summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity
        ) {
            return focus
        }
        return HubScanLine.resolve(
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.shortLabel)
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
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    // Status text yields width first so Quit never clips.
                    .layoutPriority(0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(multiDeviceFooterLine)
                footerIconButton("doc.text", label: "Open hub log", action: onOpenHubLog)
                footerIconButton("gearshape", label: "Settings", action: onOpenSettings)
                // Labeled Quit — power-only glyph was easy to miss and sat on a
                // moving footer when content reflowed. Fixed chrome + text keeps
                // it under the cursor and readable.
                quitButton
            }
            .frame(height: Self.footerActionRowHeight)
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
            .frame(minWidth: Self.quitMinWidth, minHeight: Self.quitMinHeight)
            .frame(height: Self.quitMinHeight)
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
        // Never compress below the labeled minimum — long multi-device lines
        // must truncate, not steal Quit's hit target.
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(10)
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
/// Press must not scale the control — scaling the Quit hit target under the
/// cursor felt like the button was "escaping" mid-click. Opacity-only feedback
/// keeps geometry fixed; `pressedScale` is the shipped invariant (always 1.0).
struct ShannonQuietButtonStyle: ButtonStyle {
    /// Identity scale when pressed. Product rule: must stay 1.0 so Quit's
    /// hit target never shrinks under the pointer.
    static let pressedScale: CGFloat = 1.0
    /// Dim on press without changing layout bounds.
    static let pressedOpacity: Double = 0.72

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? Self.pressedOpacity : 1.0)
            // Explicit scaleEffect(pressedScale): documents the contract and
            // keeps tests/product in lockstep. pressedScale == 1.0 → no shrink.
            .scaleEffect(configuration.isPressed ? Self.pressedScale : 1.0)
            .animation(nil, value: configuration.isPressed)
    }
}
