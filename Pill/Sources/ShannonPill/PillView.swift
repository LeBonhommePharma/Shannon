import SwiftUI
import PillCore
import Routes
import ShannonCore
import ShannonTheme

// `ShannonStatus.isSynthetic` / `.syntheticBackends` and the provenance rules
// built on them now live in PillCore (`EntropyProvenance.swift`), so the
// companion board, the popover and this view cannot drift apart on what counts
// as a measured reading.

/// Hit-test shape: AgentNotch island on hardware so inward wing "bites" stay
/// click-through; capsule on external displays.
private struct PillHitShapeModifier: ViewModifier {
    var physicalNotch: Bool
    var island: NotchIslandShape
    var capsule: RoundedRectangle

    func body(content: Content) -> some View {
        if physicalNotch {
            content.contentShape(island)
        } else {
            content.contentShape(capsule)
        }
    }
}

/// Sizes for the two pill states.
///
/// Collapsed metrics are **physical-notch-first** (MacBook Pro 14"/16"):
/// height fills `safeAreaInsets.top` (~38 pt), width matches the measured cutout
/// (~220 pt at common 14" scales), and the shape is AgentNotch Dynamic Island
/// (inward top wings + outward bottom lip) so software and hardware read as one.
public enum PillMetrics {
    /// Collapsed strip height — matches `ShannonLayout.Pill.collapsedHeight` and
    /// the typical notch band. Prefer `collapsedHeight(notchBand:physicalNotch:)` when geometry is known.
    public static let collapsedHeight: CGFloat = ShannonLayout.Pill.collapsedHeight // 32
    /// Fallback when no physical notch is measured (see `collapsedWidth(...)`).
    public static let collapsedWidth: CGFloat = ShannonLayout.Pill.defaultCollapsedWidth
    public static let idleWidth: CGFloat = ShannonLayout.Pill.defaultIdleWidth
    public static let expandedWidth: CGFloat = 400
    /// FLOOR for the expanded board, not a fixed size.
    public static let expandedHeight: CGFloat = 220
    /// Capsule when collapsed on non-notched displays; expanded uses a softer board radius.
    public static let corner: CGFloat = ShannonLayout.Pill.collapsedRadius

    /// Hard ceiling as a fraction of the screen height.
    public static let maxHeightFraction: CGFloat = 0.6

    /// Height that hugs the physical notch band when known.
    public static func collapsedHeight(notchBand: CGFloat?, physicalNotch: Bool = true) -> CGFloat {
        ShannonLayout.Pill.collapsedHeight(notchBand: notchBand, physicalNotch: physicalNotch)
    }

    /// Capsule radius for a given collapsed height (synthetic / external only).
    public static func collapsedCorner(height: CGFloat) -> CGFloat {
        ShannonLayout.Pill.collapsedCorner(height: height)
    }

    /// Bottom lip radius for the hardware island (legacy lip helper).
    public static func notchBottomRadius(height: CGFloat) -> CGFloat {
        ShannonLayout.Pill.notchBottomRadius(height: height)
    }

    /// AgentNotch closed/open island radii.
    public static func islandRadii(expanded: Bool) -> (top: CGFloat, bottom: CGFloat) {
        ShannonLayout.Pill.islandRadii(expanded: expanded)
    }

    /// Width from measured hardware notch (or defaults).
    /// - Parameter winged: live work / ask / collapse extends past the cutout.
    public static func collapsedWidth(
        notchWidth: CGFloat?,
        recessive: Bool,
        physicalNotch: Bool = false,
        winged: Bool = false
    ) -> CGFloat {
        ShannonLayout.Pill.collapsedWidth(
            notchWidth: notchWidth,
            recessive: recessive,
            physicalNotch: physicalNotch,
            winged: winged
        )
    }
}

/// The pill's laid-out size, published so the hosting window can match it.
///
/// The panel is a borderless top-anchored window: anything the content lays out
/// beyond the window's bounds is drawn past the top of the screen and clipped by
/// the display edge rather than wrapping or scrolling. Measuring the content and
/// resizing the window is what keeps the two in agreement at every display
/// resolution — the notch band is 38 pt tall here but the usable width either
/// side of it ranges from ~117 pt to ~370 pt depending on the mode the user picks.
struct PillContentSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        // Keep the largest reported size; sibling backgrounds can report .zero.
        if next.width * next.height > value.width * value.height { value = next }
    }
}

struct PillView: View {
    @ObservedObject var nowPlaying: NowPlayingModel
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var bridge: ShannonBridge
    // IdleTelemetryPublisher is intentionally NOT @ObservedObject — its 1 Hz
    // breath used to force full pill re-eval while unused in this view.
    @ObservedObject var confirmation: ConfirmationController
    @ObservedObject var ingest: AgentIngestService
    @ObservedObject var activity: AgentActivityMonitor
    @ObservedObject var resources: SystemResourceMonitor
    /// Gate + artifact sessions (project/branch/model/tokens) — same source as menu bar.
    @ObservedObject var parity: ParityPanelModel
    @Binding var isExpanded: Bool
    /// Desktop-pet handoff (E4): highlight this agent row while expanded.
    var focusedAgentId: String? = nil

    /// Drives the pulsing red border shown when entropy collapses (deception alert).
    @State private var collapsePulse  = false
    /// Drives the subtle breathing animation on the idle waveform (no agents busy).
    @State private var idleBreath     = false
    /// Drives the amber pulse shown while the gate is waiting on a human answer.
    @State private var askPulse       = false
    /// Subtle Liquid Glass hover lift on the collapsed island (no expand yet).
    @State private var hoverLift      = false
    /// Last Handrail command dispatched (visible feedback; no invented outcomes).
    @State private var lastHandrailCommand: String? = nil
    /// Matched geometry: glyph / rail / chips morph across expand↔collapse.
    @Namespace private var islandNS
    /// Reduce Motion: never forever-pulse borders (P2.4).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The newest open approval. Source: agent_interactions (status = pending),
    /// which `readPendingAsks` already returns newest-first (ORDER BY
    /// created_at_ns DESC), so index 0 is the one worth answering.
    ///
    /// This must stay `.first`: `.last` picks the OLDEST row, so a stale ask
    /// nobody ever answered outlives every newer one and permanently occupies
    /// the notch. It also made this banner disagree with the menu-bar popover,
    /// which reads `.first` (MenuBarPopoverView.swift) — the same ask surfaced
    /// as two different prompts at once.
    private var pendingAsk: GateDBReader.PendingAsk? { activity.pendingAsks.first }
    private var hasPendingAsk: Bool { pendingAsk != nil }

    private var showExpanded: Bool { isExpanded || confirmation.isAwaitingConfirmation }

    /// Tapping a pulsing pill goes straight to the approval, rather than making
    /// LP open the pill and then hunt for what needs answering.
    private var showAskCard: Bool { showExpanded && hasPendingAsk && !confirmation.isAwaitingConfirmation }

    private var summary: AgentActivitySummary { activity.summary }
    private var primary: AgentActivitySnapshot? { summary.primary }
    private var busy: [AgentActivitySnapshot] { summary.busy }

    /// Fleet-level reading (worst/freshest) for collapse border and collapsed badge.
    private var fleetReading: EntropyReading {
        EntropyProvenance.resolve(
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status,
            gate: activity.agentEntropy,
            gateDBAvailable: activity.gateDBAvailable
        )
    }

    /// Best session per agent (project / branch / model / tokens) — menu-bar parity.
    private var sessionsByAgent: [String: AgentSession] { parity.sessionsByAgent }

    /// Usage map from sessions (fail-closed) — feeds collapsed chip + expanded badges.
    private var usageByAgent: [String: AgentUsageSnapshot] {
        SessionContentPresenter.usageByAgent(from: sessionsByAgent)
    }

    /// Listed board rows with **one** surface resolve per agent (ENH-007 residual).
    ///
    /// Same path as menu-bar `cardsFromAgents`: sessions → usage merge → ranked
    /// surfaces + optional meta line (project · branch · model).
    private var listedAgentSurfaces: [(
        agent: AgentActivitySnapshot,
        surface: AgentLiveSurface,
        metaLine: String?
    )] {
        let limit = busy.isEmpty ? 3 : 4
        let pairs = SessionContentPresenter.listedSurfaces(
            agents: summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity,
            sessionsByAgent: sessionsByAgent,
            usageByAgent: usageByAgent,
            limit: limit
        )
        // Never fall back to raw summary.agents — that re-admits Finder /
        // WindowManager-class spam when ranked admission correctly returns [].
        if !pairs.isEmpty { return pairs }
        let pendingIDs = Set(activity.pendingAsks.map(\.agentId))
        let admitted = LiveRosterAdmission.filterListed(
            agents: Array(busy.isEmpty ? summary.agents.prefix(limit) : busy.prefix(limit)),
            pendingAgentIDs: pendingIDs
        )
        guard !admitted.isEmpty else { return [] }
        let merged = SessionContentPresenter.mergedUsageByAgent(
            usageByAgent: usageByAgent,
            sessionsByAgent: sessionsByAgent
        )
        return admitted.map { a in
            let surface = AgentLiveSurfaceLogic.resolve(
                agent: a,
                pendingAsks: activity.pendingAsks,
                activity: activity.recentActivity,
                usage: merged[a.id]
            )
            let meta = SessionContentPresenter.metaLine(
                agentId: a.id, sessionsByAgent: sessionsByAgent
            )
            return (a, surface, meta)
        }
    }

    /// Agents currently listed on the board — needs-you → working → finished → idle.
    private var listedAgents: [AgentActivitySnapshot] {
        listedAgentSurfaces.map(\.agent)
    }

    /// Independent per-agent readings for every listed agent id.
    private var agentReadings: [String: EntropyReading] {
        let listed = listedAgents
        // Sole-live fleet bridge only among **admitted** live rows (not every
        // sticky Cursor host still open in the full summary).
        let liveIds = Set(listed.filter { $0.presence == .live }.map(\.id))
        return EntropyProvenance.resolveAll(
            agentIds: listed.map(\.id),
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status,
            gate: activity.agentEntropy,
            gateDBAvailable: activity.gateDBAvailable,
            liveAgentIds: liveIds
        )
    }

    /// Per-agent companion deltas (measured only) — admitted live set only.
    private var agentCompanionDeltas: [String: Double] {
        let pendingIDs = Set(activity.pendingAsks.map(\.agentId))
        let admitted = LiveRosterAdmission.filterListed(
            agents: summary.agents,
            pendingAgentIDs: pendingIDs
        )
        let liveIds = Set(admitted.filter { $0.presence == .live }.map(\.id))
        return EntropyProvenance.companionDeltas(
            agentIds: admitted.map(\.id),
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status,
            gate: activity.agentEntropy,
            gateDBAvailable: activity.gateDBAvailable,
            liveAgentIds: liveIds
        )
    }

    /// True when a real track is loaded *and* no agent is busy — never show
    /// media chrome for an empty/unavailable session (P2.3 / UX half-dead chrome).
    private var showMedia: Bool {
        PillChromePolicy.shouldShowMedia(hasTrack: nowPlaying.hasTrack, busyCount: busy.count)
    }

    /// Hover-dwell task: expand only after intentional dwell (not twitchy).
    @State private var hoverExpandTask: Task<Void, Never>?

    /// Live work the **expanded** board may glow for. Collapsed notch chrome
    /// never uses this — bridge.connected alone must not light the island.
    private var boardActive: Bool { !busy.isEmpty || bridge.connected }

    /// Status dots / expanded accents (includes hub connected).
    private var agentActive: Bool { boardActive }

    /// Collapsed island "working" signal: real human-visible activity only.
    /// Excludes mere hub connectivity so the notch stays black hairline chrome.
    private var islandWorking: Bool {
        !busy.isEmpty || hasPendingAsk || collapseAlarm || confirmation.isAwaitingConfirmation
    }

    /// No agent has been seen for over 30 s. Source: max(updatedAt) across the
    /// agent snapshots, i.e. the newest gate/pet timestamp. The breathing idle
    /// animation is bound to this and nothing else — previously it ran whenever
    /// no agent was *busy*, which included the very-much-alive moment just after
    /// a task finished.
    private var isQuiet: Bool {
        guard let newest = summary.agents.map(\.updatedAt).max() else { return true }
        return Date().timeIntervalSince(newest) > 30
    }

    /// Live notch geometry for the preferred screen (width + band height).
    private var notchGeometry: NotchGeometry {
        NotchGeometry(screen: NotchGeometry.preferredScreen())
    }

    /// Physical camera cutout on the preferred screen (MBP 14"/16").
    private var isPhysicalNotch: Bool { notchGeometry.hasNotch }

    /// Expanded board radius (non-island paths). Island uses ``islandRadii``.
    private var corner: CGFloat {
        if showExpanded { return ShannonRadius.xl }
        if isPhysicalNotch {
            return DynamicIslandGeometry.closedBottomRadius
        }
        return PillMetrics.collapsedCorner(height: liveCollapsedHeight)
    }

    /// AgentNotch closed/open radii for the Dynamic Island path.
    private var islandRadii: (top: CGFloat, bottom: CGFloat) {
        PillMetrics.islandRadii(expanded: showExpanded)
    }

    /// True when live work / ask / collapse should grow left/right wings.
    private var islandWings: Bool {
        DynamicIslandGeometry.shouldWing(
            liveWork: islandWorking,
            hasPendingAsk: hasPendingAsk,
            collapseAlarm: collapseAlarm
        )
    }

    /// AgentNotch Dynamic Island outline (physical notch only).
    private var notchOutline: NotchIslandShape {
        NotchIslandShape(
            topCornerRadius: islandRadii.top,
            bottomCornerRadius: islandRadii.bottom
        )
    }

    /// Capsule outline for non-notch / external displays.
    private var capsuleOutline: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }

    @ViewBuilder
    private func strokePillOutline(color: Color, lineWidth: CGFloat) -> some View {
        if isPhysicalNotch {
            notchOutline.stroke(color, lineWidth: lineWidth)
        } else {
            capsuleOutline.stroke(color, lineWidth: lineWidth)
        }
    }

    /// Notch-band height when the hosting screen is known; falls back to layout default.
    private var liveCollapsedHeight: CGFloat {
        PillMetrics.collapsedHeight(
            notchBand: notchGeometry.bandHeight,
            physicalNotch: isPhysicalNotch
        )
    }

    /// Does the pill have anything worth occupying screen real estate for?
    ///
    /// Anything a human would want to act on or be told about counts: a busy
    /// agent, a gate waiting on an answer, an entropy collapse, a fresh capture,
    /// or media transport controls the user can actually press.
    private var hasSomethingToSay: Bool {
        !busy.isEmpty
            || hasPendingAsk
            || collapseAlarm
            || confirmation.isAwaitingConfirmation
            || ingest.isHighlighting
            || showMedia
    }

    /// Collapsed, silent, and nothing has happened for a while — present the
    /// smallest and most transparent form the pill has. It stays fully
    /// interactive: hovering or clicking still opens the full board.
    private var isRecessive: Bool { !showExpanded && !hasSomethingToSay && isQuiet }

    /// Width from measured hardware notch when present; defaults otherwise.
    /// On a physical cutout fills the cutout; live work grows AgentNotch wings.
    private var collapsedWidth: CGFloat {
        let measured: CGFloat? = isPhysicalNotch ? notchGeometry.notchRect.width : nil
        return PillMetrics.collapsedWidth(
            notchWidth: measured,
            recessive: isRecessive,
            physicalNotch: isPhysicalNotch,
            winged: islandWings
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            if showExpanded {
                if confirmation.isAwaitingConfirmation {
                    ConfirmationPromptView(confirmation: confirmation)
                } else if let ask = pendingAsk {
                    GateAskCard(
                        ask: ask,
                        isResolving: activity.resolving.contains(ask.interactionId),
                        errorText: activity.lastResolveError,
                        gateAvailable: activity.gateAvailable
                    ) { approved in
                        resolve(ask, approved: approved)
                    }
                } else {
                    expanded
                }
            } else {
                collapsed
            }
        }
        // Width is fixed per state; the EXPANDED height follows its content.
        //
        // A hard `height: expandedHeight` did not clip the overflow, it centred
        // it: SwiftUI does not clip to a frame by default, so once the board
        // grew past 220 pt (header 44 + agent rows + footer + entropy strip) the
        // surplus spilled equally above and below. The pill window's top edge
        // sits exactly on the top of the display, so everything that spilled
        // upward was cut off by the physical screen edge — which is why the
        // header icon and the battery ring appeared sliced in half. Letting the
        // height be intrinsic (with expandedHeight as a floor, not a ceiling)
        // means the content always has the room it asked for.
        .frame(
            width: showExpanded ? PillMetrics.expandedWidth : collapsedWidth,
            height: showExpanded ? nil : liveCollapsedHeight
        )
        .frame(minHeight: showExpanded ? PillMetrics.expandedHeight : nil)
        // Take the IDEAL height when expanded, not the proposed one.
        //
        // `.frame(height: nil)` above only declines to impose a height — the view
        // still accepts whatever its parent proposes, and PillHost proposes its
        // own fixed height. Without this the board silently agreed to 220 pt,
        // reported 220 pt through PillContentSizeKey, and overflowed exactly as
        // before while the window had no idea it needed to grow.
        .fixedSize(horizontal: false, vertical: showExpanded)
        // Report the laid-out size so PillWindowController can size the panel to
        // match. Without this the window stays 400x220 and the extra content,
        // though now correctly laid out, would still land outside the window.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PillContentSizeKey.self, value: proxy.size)
            }
        )
        .shannonPill(
            // Expanded: glow when board is active. Collapsed: only true work
            // (busy/ask/collapse) — never bridge.connected alone (notch halo).
            isActive: showExpanded ? boardActive : islandWorking,
            isQuiet: isRecessive,
            isCollapsed: !showExpanded,
            // Hardware: AgentNotch Dynamic Island (inward top + outward bottom).
            notchIsland: isPhysicalNotch,
            cornerRadius: corner,
            topCornerRadius: isPhysicalNotch ? islandRadii.top : nil,
            bottomCornerRadius: isPhysicalNotch ? islandRadii.bottom : nil
        )
        .overlay(islandWorkingGlow)
        .overlay(flashOverlay)
        // Only the pill island takes hits. Transparent bezel "bites" stay
        // click-through (AgentNotch inward top wings).
        .modifier(PillHitShapeModifier(
            physicalNotch: isPhysicalNotch,
            island: notchOutline,
            capsule: capsuleOutline
        ))
        // Only intentional expand/collapse morphs via withAnimation below.
        // Never attach value-based .animation to recessive/busy text — those
        // flip on live telemetry and made the notch island "pop" on refresh.
        .animation(.shannon(.shannonFloat, reduceMotion: reduceMotion), value: showExpanded)
        .transaction { txn in
            // Kill implicit layout animations from @Published resource/agent ticks.
            // Expand/collapse still runs inside explicit withAnimation scopes.
            if txn.animation == nil {
                txn.disablesAnimations = true
            }
        }
        // Intentional expand: brief hover dwell expands; click toggles dismiss.
        // Instant hover-expand was twitchy (UX audit). Leave does not auto-collapse.
        .onHover { hovering in
            hoverExpandTask?.cancel()
            hoverExpandTask = nil
            if !hovering {
                withAnimation(.shannon(.shannonSnap, reduceMotion: reduceMotion)) {
                    hoverLift = false
                }
                return
            }
            withAnimation(.shannon(.shannonSnap, reduceMotion: reduceMotion)) {
                hoverLift = true
            }
            let dwell = PillChromePolicy.hoverExpandDwell
            hoverExpandTask = Task { @MainActor in
                let ns = UInt64(max(0, dwell) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                guard !Task.isCancelled else { return }
                if PillChromePolicy.shouldExpandOnHover(
                    dwellSeconds: dwell,
                    alreadyExpanded: isExpanded
                ) {
                    withAnimation(.shannon(.shannonFloat, reduceMotion: reduceMotion)) {
                        isExpanded = true
                    }
                }
            }
        }
        .scaleEffect(hoverLift && !showExpanded && !reduceMotion ? 1.015 : 1.0)
        .onTapGesture {
            withAnimation(.shannon(.shannonFloat, reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        }
        // Right-click / long-press. Every item below changes real state.
        .contextMenu {
            Button(activity.isPaused ? "Resume monitoring" : "Pause monitoring") {
                activity.isPaused.toggle()
            }
            if hasPendingAsk, let ask = pendingAsk {
                Divider()
                Button("Approve: \(AgentStyleCatalog.style(for: ask.agentId).displayName)") {
                    resolve(ask, approved: true)
                }
                Button("Deny: \(AgentStyleCatalog.style(for: ask.agentId).displayName)") {
                    resolve(ask, approved: false)
                }
            }
            Divider()
            Button("Refresh now") { activity.refresh() }
        }
        .onChange(of: hasPendingAsk) { pending in
            if pending {
                if PillChromePolicy.allowsForeverPulse(reduceMotion: reduceMotion) {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        askPulse = true
                    }
                } else {
                    // Solid amber border — no forever-pulse under Reduce Motion.
                    askPulse = true
                }
            } else {
                withAnimation(reduceMotion ? nil : .default) { askPulse = false }
                if confirmation.armedInteractionId != nil {
                    confirmation.cancel()
                }
            }
            armGateAskIfNeeded()
        }
        .onChange(of: pendingAsk?.interactionId) { _ in
            armGateAskIfNeeded()
        }
        // Start / stop the entropy-collapse pulse border + auto-expand island.
        .onChange(of: collapseAlarm) { collapsed in
            if collapsed {
                if PillChromePolicy.allowsForeverPulse(reduceMotion: reduceMotion) {
                    withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                        collapsePulse = true
                    }
                } else {
                    // Solid red attention — never forever-pulse under Reduce Motion.
                    collapsePulse = true
                }
                // Measured collapse only (collapseAlarm is provenance-gated).
                ShannonNotifier.notifyCollapse(
                    bits: fleetReading.currentBits,
                    source: fleetReading.measurement?.source.label ?? "bridge"
                )
                // Thermodynamic referee: auto-expand on measured collapse.
                if collapseDecision.shouldAutoExpand {
                    withAnimation(.shannon(.shannonFloat, reduceMotion: reduceMotion)) {
                        isExpanded = true
                    }
                }
            } else {
                withAnimation(reduceMotion ? nil : .default) { collapsePulse = false }
            }
        }
        // Push path: significant bridge events (collapse / ΔH) without 1 Hz lag.
        .onChange(of: bridge.pushGeneration) { _ in
            if collapseDecision.shouldAutoExpand {
                withAnimation(.shannon(.shannonFloat, reduceMotion: reduceMotion)) {
                    isExpanded = true
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(collapsedText)
        .accessibilityHint(PillChromePolicy.expandAccessibilityHint)
        // Kick off the idle breathing animation once the view appears.
        .onAppear {
            idleBreath = !reduceMotion
            ShannonNotifier.requestPermission()
            armGateAskIfNeeded()
            // Same session merge as menu bar (project/branch/tokens for density).
            parity.refresh(gateAgents: summary.agents, force: true)
        }
        .onChange(of: summary.agents.count) { _ in
            parity.refresh(gateAgents: summary.agents)
        }
    }

    private var flashOverlay: some View {
        ZStack {
            // Confirmation flash fill (approve = green, deny = red).
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(confirmation.flash == .confirm ? Color.shannonSuccess : Color.shannonError)
                .opacity(confirmation.flash == nil ? 0 : 0.35)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.25), value: confirmation.flash)

            // Pending-approval border. Amber, and strictly distinct from the red
            // collapse border below: one means "answer me", the other means
            // "this agent may be deceiving you".
            strokePillOutline(
                color: Color.shannonWarning,
                lineWidth: askPulse ? 2.0 : 1.0
            )
            .opacity(hasPendingAsk ? (askPulse ? 0.95 : 0.35) : 0)
            .allowsHitTesting(false)

            // Entropy-collapse deception-alert border: always present,
            // invisible until entropy collapses, then pulses red.
            strokePillOutline(
                color: Color.shannonError,
                lineWidth: (collapseAlarm && collapsePulse) ? 2.0 : 0.5
            )
            .opacity(collapseAlarm ? (collapsePulse ? 0.90 : 0.22) : 0)
            .allowsHitTesting(false)
        }
    }

    // MARK: Collapsed

    /// AgentNotch-class closed header: glyph + glance label + scannable chips.
    /// Dense multi-metric stacks (CPU/H/battery) live on the expanded board.
    private var collapsed: some View {
        HStack(spacing: 7) {
            // Source-aware status indicator (agent tint / activity glyph).
            statusGlyph
                .frame(width: 15, height: 15)
                .matchedGeometryEffect(id: "statusGlyph", in: islandNS)

            // Short activity label; recessive quiet drops filler copy.
            // White primary on pure-black island (AgentNotch contrast).
            if !isRecessive {
                Text(collapsedText)
                    .font(.shannonPillLabel)
                    .foregroundStyle(Color.white.opacity(0.94))
                    .tracking(AgentNotchChrome.islandLabelTracking)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .truncationMode(.tail)
                    .contentTransition(.identity)
            }

            Spacer(minLength: 2)

            // Mini entropy chip morphs into expanded thermodynamic rail.
            if fleetReading.isMeasured, let bits = fleetReading.currentBits {
                Text(String(format: "H %.1f", bits))
                    .font(.shannonPillMono)
                    .foregroundStyle(entropyTint(for: fleetReading))
                    .padding(.horizontal, AgentNotchChrome.badgeHorizontalPadding)
                    .padding(.vertical, AgentNotchChrome.badgeVerticalPadding)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
                    .matchedGeometryEffect(id: "entropyRail", in: islandNS)
                    .help("Measured token entropy")
            }

            // Trailing chips: prefer one fleet/usage metric, not a dense stack.
            if let usage = collapsedUsageChip {
                AgentNotchBadge(text: usage, role: .idle, styleInk: Color.white.opacity(0.75))
                    .matchedGeometryEffect(id: "agentChip", in: islandNS)
                    .help("Usage from local session telemetry")
            } else if collapsedActiveCount > 1 {
                AgentNotchBadge(
                    text: "\(collapsedActiveCount)",
                    role: .working,
                    styleInk: Color.shannonAccent
                )
                .matchedGeometryEffect(id: "agentChip", in: islandNS)
                .help(
                    AgentListSkim.multiAgentAccessibilityLabel(
                        activeCount: collapsedActiveCount
                    ) ?? "\(collapsedActiveCount) \(AgentListSkim.multiAgentGlanceCaption)"
                )
            }

            if hasPendingAsk {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentNotchChrome.ink(for: .needsYou))
                    .help("An agent is waiting for your approval — click to answer")
            }

            if collapseAlarm {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentNotchChrome.ink(for: .collapse))
            }
        }
        // Physical notch: glyphs in the menu-bar band; overhang is black lip.
        .padding(.horizontal, isPhysicalNotch ? (islandWings ? 16 : 12) : 11)
        .padding(.bottom, isPhysicalNotch ? ShannonLayout.Pill.physicalIslandOverhang : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .frame(height: liveCollapsedHeight)
    }

    /// Working-state lip glow (AgentNotch cyan/activity). Reduce Motion: solid
    /// accent stroke, no rotating gradient. Idle island stays quiet.
    @ViewBuilder
    private var islandWorkingGlow: some View {
        let show = !showExpanded && isPhysicalNotch && islandWorking
        if show {
            let shape = NotchIslandShape(
                topCornerRadius: islandRadii.top,
                bottomCornerRadius: islandRadii.bottom
            )
            if reduceMotion {
                shape
                    .stroke(Color.shannonAccent.opacity(0.55), lineWidth: 1.5)
                    .allowsHitTesting(false)
            } else {
                shape
                    .stroke(Color.shannonAccent.opacity(0.35), lineWidth: 2)
                    .shadow(color: Color.shannonAccent.opacity(0.45), radius: 6)
                    .shadow(color: Color.shannonAccent.opacity(0.2), radius: 12)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Leading indicator in the collapsed pill.
    ///
    /// • 1 active agent  → brand emoji (15 pt) — more distinctive than an SF symbol
    /// • 2-4 active      → micro dot cluster, each dot in the agent's brand colour
    /// • Media / idle    → music note or breathing waveform
    @ViewBuilder
    private var statusGlyph: some View {
        if busy.count == 1, let p = busy.first {
            // Single active agent: prominent emoji communicates identity at a glance.
            Text(style(for: p).emoji)
                .font(.shannonMenuBody)
                .help("\(style(for: p).displayName) · \(p.statusLine) · \(style(for: p).pet)")
        } else if busy.count > 1 {
            // One dot per agent in its own brand colour, ordered by last-seen so
            // the most recently active sits leftmost. Dots stay bare colour — at
            // 7 pt a companion glyph is unreadable, so the companion and the
            // last-seen age ride in the tooltip instead.
            let ordered = Array(busy.sorted { $0.updatedAt > $1.updatedAt }.prefix(3))
            ZStack {
                ForEach(Array(ordered.enumerated()), id: \.offset) { pair in
                    Circle()
                        .fill(color(for: pair.element))
                        .frame(width: 7, height: 7)
                        // Keeps a light brand colour off a light pill.
                        .overlay(Circle().strokeBorder(Color.pillBorder, lineWidth: 0.5))
                        .offset(
                            x: CGFloat(pair.offset - 1) * 5,
                            y: pair.offset % 2 == 0 ? -2 : 2
                        )
                }
            }
            .help(ordered
                .map { "\(style(for: $0).displayName) (\(style(for: $0).pet)) · \($0.relativeAge)" }
                .joined(separator: "\n"))
        } else if showMedia {
            Image(systemName: "music.note")
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonSecondary)
        } else {
            // Quiet: breathing waveform. Bound to `isQuiet` (>30 s since any
            // agent was seen), so the breath means "nothing has happened for a
            // while" rather than merely "nothing is busy this instant".
            WaveformIdleView(
                color: statusDotColor,
                animate: PillChromePolicy.shouldAnimateWaveform(
                    reduceMotion: reduceMotion,
                    isRecessive: isRecessive
                )
            )
                .frame(width: 16, height: 14)
                .scaleEffect(idleBreath && isQuiet && !reduceMotion ? 0.84 : 1.0)
                .opacity(idleBreath && isQuiet && !reduceMotion ? 0.50 : 1.0)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                    value: idleBreath && isQuiet
                )
                .help(isQuiet
                      ? "No agent activity for over 30 s"
                      : "Agents idle but recently active")
        }
    }

    /// A collapse we are willing to raise the deception alarm for.
    ///
    /// Only `.measured` collapse from `EntropyProvenance.resolve` can alarm —
    /// synthetic backends and absent detectors never raise the red border.
    private var collapseAlarm: Bool { fleetReading.collapsed == true }

    /// Pure referee decision (auto-expand + Handrail) — measured collapse only.
    private var collapseDecision: CollapseAttentionDecision {
        CollapseAttentionLogic.decide(
            reading: fleetReading,
            status: bridge.status,
            tokenSnippet: bridge.status?.tokenSnippet
        )
    }

    /// Continuous multi-stop gradient over measured H — not discrete RYG.
    private func entropyTint(for reading: EntropyReading) -> Color {
        if let display = reading.display(at: Date()) {
            return Self.color(from: display.gaugeColorRGB())
        }
        return .shannonNeutral
    }

    private static func color(from rgb: EntropyColorRGB) -> Color {
        Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private var statusDotColor: Color {
        // Collapse is red; amber is ask-only (PillChromePolicy.statusLegend).
        if collapseAlarm { return .shannonError }
        if hasPendingAsk { return .shannonWarning }
        if bridge.connected { return .shannonSuccess }
        if !busy.isEmpty { return .shannonAccent }
        return .shannonTertiary
    }

    /// Priority: live agent focus (needs-you / tool activity) → busy roster →
    /// ingest → media → host load → quiet. Fail-closed when no live signal.
    private var collapsedText: String {
        // AgentNotch-class focus: needs-you and live tool lines first.
        if let focus = AgentLiveSurfaceLogic.primaryFocus(
            agents: summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity,
            usageByAgent: usageByAgent
        ) {
            return focus
        }
        if !busy.isEmpty { return summary.collapsedText }
        if ingest.isHighlighting, let last = ingest.lastResult {
            // `pillLabel` is "⊘ not an agent" for a refused capture — the pill
            // must never announce "+Something" for a capture that never ran.
            return last.pillLabel
        }
        if let bench = BenchmarkRunLogic.collapsedTitle(activity.benchmark) {
            return bench
        }
        if let label = nowPlaying.collapsedLabel { return label }
        if let recent = primary, !recent.lastTask.isEmpty,
           Date().timeIntervalSince(recent.updatedAt) < 600 {
            return recent.collapsedLine
        }
        if let c = resources.snapshot.mostConstrained, c.percent >= 60 {
            return c.shortLabel
        }
        return SessionContentPresenter.collapsedStatusLine(
            agents: summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity,
            usageByAgent: usageByAgent
        )
    }

    /// Multi-agent glance count (needs-you + working), not only gate busy status.
    private var collapsedActiveCount: Int {
        SessionContentPresenter.collapsedActiveCount(
            agents: summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity
        )
    }

    /// Compact usage chip when a real source provided metrics for the focus agent.
    ///
    /// Passes `usageByAgent` from session merge so artifact tokens surface
    /// (AgentNotch/AgentPeek density) — never invents numbers.
    private var collapsedUsageChip: String? {
        SessionContentPresenter.collapsedUsageChip(
            agents: summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity,
            usageByAgent: usageByAgent
        )
    }

    /// Compact host-resource chip for the collapsed pill when stressed, or
    /// always in the expanded footer. Most-constrained only (by design).
    @ViewBuilder
    private var constrainedResourceChip: some View {
        if let c = resources.snapshot.mostConstrained {
            // Continuous scarcity ink — red only at critical emergency levels.
            let s = ResourceScarcityTint.sRGB(percent: c.percent)
            let tint = Color(red: s.r, green: s.g, blue: s.b).opacity(s.a)
            Text(c.shortLabel)
                .font(.shannonPillMono)
                .foregroundStyle(tint)
                .help(resourceHelpLine)
                .accessibilityLabel(resourceHelpLine)
        }
    }

    private var resourceHelpLine: String {
        let s = resources.snapshot
        var parts: [String] = []
        if let c = s.cpuPercent {
            var cpu = String(format: "CPU %.0f%%", c)
            if s.cpuCoreCount > 0 {
                cpu += " (\(s.cpuCoreCount) cores"
                if let hot = s.hottestCore {
                    cpu += String(format: ", peak C%d %.0f%%", hot.index, hot.percent)
                }
                cpu += ")"
            }
            parts.append(cpu)
        }
        if let g = s.gpuPercent { parts.append(String(format: "GPU %.0f%%", g)) }
        if let r = s.ramPercent {
            if let u = s.ramUsedGB, let t = s.ramTotalGB {
                parts.append(String(format: "RAM %.0f%% (%.1f/%.0f GB)", r, u, t))
            } else {
                parts.append(String(format: "RAM %.0f%%", r))
            }
        }
        return parts.isEmpty ? "Host resources unavailable" : parts.joined(separator: " · ")
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            // Legend graduates after first-run (not permanent debug chrome).
            if PillChromePolicy.shouldShowStatusLegend(
                firstRunPending: FirstRunCoach.shouldShow()
            ) {
                Text(PillChromePolicy.statusLegend)
                    .font(.shannonMenuSection)
                    .foregroundStyle(Color.shannonTertiary)
                    .accessibilityLabel(PillChromePolicy.statusLegend)
            }

            // Live thermodynamic surface — first-class H / ΔH / z rail.
            thermodynamicRefereeSurface
                .matchedGeometryEffect(id: "entropyRail", in: islandNS)

            // Measured collapse island: agent + metrics + Handrail one-taps.
            if collapseDecision.state == .alarm {
                collapseHandrailIsland
            }

            if showMedia {
                mediaBlock
            } else if !busy.isEmpty || primary != nil {
                agentBoard
            } else {
                emptyBoard
            }

            // FlexAIDdS DatasetRunner progress from gate `benchmark_state`.
            // Fail-closed: only when the hub has a non-stale row — no invented S.
            if BenchmarkRunLogic.shouldShowCard(activity.benchmark) {
                expandedBenchmarkCard
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(12)
    }

    /// Sliding-window H + ΔH (+ z when present) with cool→warm→red lock-in map.
    /// Synthetic bridge (`demo`) never paints measured-looking H (fail-closed).
    @ViewBuilder
    private var thermodynamicRefereeSurface: some View {
        let now = Date()
        let measuredLabel = EntropyStripPresentation.summaryLabel(
            reading: fleetReading,
            bridgeStatus: bridge.status,
            now: now
        )
        let watermark = EntropyStripPresentation.syntheticWatermark(
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status
        )
        let showRail = EntropyStripPresentation.showsRail(reading: fleetReading, now: now)
        let series = bridge.hHistory
        let points = showRail
            ? EntropyRailLogic.points(hSeries: series, isCurrent: fleetReading.isMeasured)
            : []
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("ENTROPY")
                    .font(.shannonMenuSection)
                    .foregroundStyle(Color.shannonTertiary)
                    .tracking(0.5)
                Spacer(minLength: 4)
                if let measuredLabel {
                    Text(measuredLabel)
                        .font(.shannonPillMono)
                        .foregroundStyle(entropyTint(for: fleetReading))
                        .contentTransition(.identity)
                        .accessibilityLabel(measuredLabel)
                } else if let watermark {
                    Text(watermark)
                        .font(.shannonMenuSection)
                        .foregroundStyle(Color.shannonNeutral)
                        .accessibilityLabel(watermark)
                } else {
                    Text("no detector")
                        .font(.shannonPillMono)
                        .foregroundStyle(Color.shannonNeutral)
                }
            }
            if showRail {
                if points.count >= 2 {
                    ThermodynamicSparkline(points: points)
                        .frame(height: 28)
                        .accessibilityLabel("Entropy history rail")
                } else if let display = fleetReading.display(at: now) {
                    FluidEntropyRail(
                        display: display,
                        agentAttached: hasAttachedAgent || bridge.connected,
                        reduceMotion: reduceMotion
                    )
                    .frame(height: 8)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.shannonSurfaceSunken.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    collapseAlarm
                        ? Color.shannonError.opacity(0.55)
                        : Color.shannonSeparator,
                    lineWidth: 1
                )
        )
    }

    /// Dedicated collapse island: identity, metrics, Handrail (measured only).
    @ViewBuilder
    private var collapseHandrailIsland: some View {
        let d = collapseDecision
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.shannonError)
                    .matchedGeometryEffect(id: "statusGlyph", in: islandNS)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Measured collapse")
                        .font(.shannonMenuBody)
                        .foregroundStyle(Color.shannonError)
                    if let agent = d.agentLabel, !agent.isEmpty {
                        Text(agent)
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonPrimary)
                            .lineLimit(1)
                    }
                    if let snippet = d.tokenSnippet {
                        Text(snippet)
                            .font(.shannonPillMono)
                            .foregroundStyle(Color.shannonSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if let label = EntropyRailLogic.summaryLabel(
                    h: d.entropy, deltaH: d.deltaH, zScore: d.zScore
                ) {
                    Text(label)
                        .font(.shannonPillMono)
                        .foregroundStyle(Color.shannonError)
                }
            }
            // Handrail one-taps — only when pure logic says measured alarm.
            HStack(spacing: 6) {
                ForEach(d.handrailActions) { action in
                    Button {
                        dispatchHandrail(action)
                    } label: {
                        Label(action.rawValue, systemImage: action.systemImage)
                            .font(.shannonMenuSection)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(action == .kill ? Color.shannonError : Color.shannonAccent)
                    .accessibilityLabel(action.accessibilityLabel)
                }
            }
            if let cmd = lastHandrailCommand {
                Text(cmd)
                    .font(.shannonMenuMono)
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.shannonError.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.shannonError.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Entropy collapse handrail")
    }

    private func dispatchHandrail(_ action: HandrailAction) {
        let d = collapseDecision
        guard HandrailDispatch.isAllowed(action: action, decision: d) else { return }
        let cmd = HandrailDispatch.command(
            action: action,
            agentId: d.agentLabel,
            entropy: d.entropy,
            deltaH: d.deltaH
        )
        lastHandrailCommand = cmd
        // ALERT reuses the local notifier (measured path only).
        if action == .alert {
            ShannonNotifier.notifyCollapse(bits: d.entropy, source: d.agentLabel ?? "handrail")
        }
        // LOG / THROTTLE / KILL / WEBHOOK are command strings for hub consumers;
        // posting a notification keeps the action observable without inventing
        // process control when the gate is offline.
        if action != .alert {
            ShannonNotifier.notifyCollapse(
                bits: d.entropy,
                source: "handrail.\(action.rawValue.lowercased())"
            )
        }
    }

    /// Honest FlexAIDdS hub surface on the expanded notch board.
    @ViewBuilder
    private var expandedBenchmarkCard: some View {
        if let run = activity.benchmark, BenchmarkRunLogic.shouldShowCard(run) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FLEXAIDDS BENCHMARK")
                    .font(.shannonMenuSection)
                    .foregroundStyle(Color.shannonTertiary)
                    .tracking(0.6)
                HStack(spacing: 10) {
                    Image(systemName: run.isComplete ? "checkmark.seal.fill" : "chart.bar.doc.horizontal")
                        .font(.shannonMenuBody)
                        .foregroundStyle(run.isComplete ? Color.shannonSuccess : Color.shannonAccent)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.displayName)
                            .font(.shannonMenuBody)
                            .foregroundStyle(Color.shannonPrimary)
                            .lineLimit(1)
                        Text(run.shortLabel)
                            .font(.shannonPillMono)
                            .foregroundStyle(Color.shannonSecondary)
                            .lineLimit(1)
                            .contentTransition(.identity)
                        if let t = run.activeTarget, !run.isComplete {
                            Text("Active · \(t)")
                                .font(.shannonMenuFootnote)
                                .foregroundStyle(Color.shannonTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    ZStack {
                        Circle()
                            .stroke(Color.shannonNeutral.opacity(0.25), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: CGFloat(run.fraction))
                            .stroke(Color.shannonAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(run.countLabel)
                            .font(.shannonPillMono)
                            .foregroundStyle(Color.shannonPrimary)
                            .minimumScaleFactor(0.65)
                    }
                    .frame(width: 42, height: 42)
                    .accessibilityLabel("Progress \(run.countLabel)")
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.shannonSurfaceElevated.opacity(0.55))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("FlexAIDdS benchmark \(run.shortLabel)")
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.shannonSurfaceElevated)
                // Subtle accent glow on the icon background when active
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(headerIconColor.opacity(agentActive ? 0.18 : 0.08))
                Image(systemName: headerIcon)
                    .font(.shannonMenuTitle)
                    .foregroundStyle(headerIconColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.shannonMenuTitle)
                    .foregroundStyle(Color.shannonPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    // Keep "Shannon" fully readable — never collapse to "Sha…".
                    .layoutPriority(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headerSubtitle)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(2)
                    .layoutPriority(1)
            }

            Spacer(minLength: 4)

            if let snap = battery.snapshot {
                VStack(spacing: 2) {
                    BatteryRing(snapshot: snap, diameter: 28)
                    // Calm label when hub is idle — avoid stuck "Calculating…"
                    // that reads as agent progress (BatteryChromePolicy).
                    Text(
                        BatteryChromePolicy.timeLabel(
                            snapshot: snap,
                            busyCount: busy.count
                        )
                    )
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var headerIcon: String {
        if collapseAlarm { return "exclamationmark.triangle.fill" }
        if let p = busy.first { return iconName(for: p) }
        if showMedia { return "music.note" }
        return "waveform.path.ecg"
    }

    private var headerIconColor: Color {
        // Collapse chrome is red (error); amber only for pending ask.
        if collapseAlarm { return .shannonError }
        if hasPendingAsk { return .shannonWarning }
        if let p = busy.first { return ink(for: p) }
        if bridge.connected { return .shannonSuccess }
        return .shannonAccent
    }

    private var headerTitle: String {
        if collapseAlarm { return "Entropy collapse" }
        if let p = busy.first {
            return busy.count == 1 ? p.displayName : "\(busy.count) agents active"
        }
        // Hide half-dead media chrome when there is no track (P2.3).
        if showMedia, let title = nowPlaying.state.info?.title, !title.isEmpty {
            return title
        }
        // UX-024: same quiet short token as complications / watch face family.
        return CompanionFocusCopy.quietShort
    }

    private var headerSubtitle: String {
        // Media artist only when media chrome is intentionally shown.
        if showMedia, busy.isEmpty, !collapseAlarm {
            if let artist = nowPlaying.state.info?.artist, !artist.isEmpty {
                return artist
            }
        }
        // Shared founder-scan priority with the menubar popover (collapse → busy
        // → FlexAIDdS progress → hub state). Never invents H or success rates.
        let taskHint: String? = {
            guard let p = busy.first else { return busy.first.map(\.statusLine) }
            let task = AgentActivitySnapshot.shorten(p.lastTask, max: 52)
            return task.isEmpty ? p.statusLine : task
        }()
        return HubScanLine.resolve(
            collapseBits: collapseAlarm ? fleetReading.measurement?.bits : nil,
            collapseDelta: collapseAlarm ? fleetReading.measurement?.deltaH : nil,
            busyNames: busy.map(\.displayName),
            busyStatus: taskHint,
            benchmarkTitle: BenchmarkRunLogic.collapsedTitle(activity.benchmark),
            // Gate socket only — same as menubar badge (not bridge alone).
            hubReady: HubScanLine.isHubReady(
                gateSocketUp: activity.gateAvailable,
                bridgeConnected: bridge.connected
            )
        )
    }

    // MARK: Agent board

    private var agentBoard: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Each agent gets its companion alongside its row. The companion
            // restates status more softly; it is never the only place a state
            // appears, so losing the artwork never loses information.
            //
            // entropyDelta goes through the SAME provenance test as the header,
            // the border and the `~H` badge (`EntropyProvenance`). A companion
            // must not look alarmed about a number the rest of the pill is, at
            // that same instant, labelling "simulated" — and connectivity alone
            // does not establish provenance: `--demo` opens a real socket.
            let companionVisible: Bool = {
                if #available(macOS 14, *) { return true }
                return false
            }()
            if #available(macOS 14, *) {
                // Same density as listedAgentSurfaces / agentRow (meta + usage).
                CompanionBoardView(
                    summary: summary,
                    entropyDeltas: agentCompanionDeltas,
                    pendingAsks: activity.pendingAsks,
                    activity: activity.recentActivity,
                    maxRows: busy.isEmpty ? 3 : 4,
                    focusedAgentId: focusedAgentId,
                    densityByAgent: SessionContentPresenter.companionBoardDensity(
                        from: listedAgentSurfaces
                    ),
                    cwdByAgent: Dictionary(
                        uniqueKeysWithValues: sessionsByAgent.compactMap { id, s in
                            guard let cwd = s.cwd, !cwd.isEmpty else { return nil }
                            return (id, cwd)
                        }
                    )
                )
            } else {
                ForEach(listedAgentSurfaces, id: \.agent.id) { pair in
                    agentRow(pair.agent, surface: pair.surface, metaLine: pair.metaLine)
                }
            }
            // Per-agent entropy rails only when they add measured H — not a
            // second "no H" clone of the companion roster (AgentNotch density).
            if ExpandedBoardDensity.showPerAgentEntropyStrip(
                companionBoardVisible: companionVisible,
                anyListedAgentHasMeasuredH: ExpandedBoardDensity.anyDisplayableH(
                    readings: agentReadings
                )
            ) {
                entropyStrip
            }
        }
    }

    private func agentRow(
        _ a: AgentActivitySnapshot,
        surface: AgentLiveSurface,
        metaLine: String? = nil
    ) -> some View {
        let reading = agentReadings[a.id]
            ?? EntropyProvenance.resolveForAgent(
                agentId: a.id,
                bridgeConnected: bridge.connected,
                bridgeStatus: bridge.status,
                gate: activity.agentEntropy,
                gateDBAvailable: activity.gateDBAvailable
            )
        return HStack(spacing: 8) {
            // Status dot: 8 pt in dark mode for better visibility
            Circle()
                .fill(color(for: a))
                .frame(width: 8, height: 8)
                .shadow(color: color(for: a).opacity(0.6), radius: 3)
            Image(systemName: iconName(for: a))
                .font(.shannonPillLabel)
                .foregroundStyle(color(for: a))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(style(for: a).emoji) \(style(for: a).displayName)")
                        .font(.shannonMenuBody)
                        .foregroundStyle(ink(for: a))
                    Text(liveBadge(for: a, surface: surface))
                        .font(.shannonMenuSection)
                        .foregroundStyle(liveAttentionColor(for: a, surface: surface))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(style(for: a).palette.wash))
                        .overlay(Capsule().strokeBorder(style(for: a).palette.edge, lineWidth: 1))
                    if let usage = surface.usage?.shortLabel {
                        Text(usage)
                            .font(.shannonPillMono)
                            .foregroundStyle(Color.shannonTertiary)
                    }
                    Spacer(minLength: 0)
                    agentEntropyBadge(reading)
                    Text(a.relativeAge)
                        .font(.shannonPillMono)
                        .foregroundStyle(Color.shannonSecondary)
                }
                // Live tool line (read/edit/shell) when present; else last task.
                let detail = liveDetailLine(for: a, surface: surface)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Project · branch · model — only when a session source reported them.
                if let meta = metaLine, !meta.isEmpty {
                    Text(meta)
                        .font(.shannonPillMono)
                        .foregroundStyle(Color.shannonTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    DesktopCompanionHandoff.isFocusedRow(
                        rowAgentId: a.id,
                        focusedAgentId: focusedAgentId
                    )
                        ? Color.shannonAccent.opacity(0.14)
                        : surface.needsYou
                        ? Color.shannonWarning.opacity(0.10)
                        : Color.shannonSurfaceElevated.opacity(0.6)
                )
        )
        // ENH-028 / ENH-029: jump host or open terminal workspace when evidence exists.
        .contextMenu {
            let action = jumpAction(for: a)
            if action.isAvailable {
                Button(action.affordanceLabel) {
                    _ = HostTerminalJumpExecutor.perform(action)
                }
            }
            let term = openTerminalAction(for: a)
            if term.isAvailable {
                Button(term.affordanceLabel) {
                    _ = OpenTerminalHereExecutor.perform(term)
                }
            }
        }
    }

    /// ENH-028 pure policy for a board row (attach + session meta/cwd).
    private func jumpAction(for agent: AgentActivitySnapshot) -> HostTerminalJumpAction {
        HostTerminalJumpPolicy.decide(
            agent: agent,
            session: sessionsByAgent[agent.id],
            runningBundleIDs: HostTerminalJumpExecutor.runningBundleIDs()
        )
    }

    /// ENH-029 pure policy — fail-closed when session cwd unknown / missing on disk.
    private func openTerminalAction(for agent: AgentActivitySnapshot) -> OpenTerminalHereAction {
        OpenTerminalHerePolicy.decide(
            attachBundle: agent.attachBundle,
            session: sessionsByAgent[agent.id]
        )
    }

    @ViewBuilder
    private func agentEntropyBadge(_ reading: EntropyReading) -> some View {
        if let display = reading.display(at: Date()) {
            Text(display.shortLabel)
                .font(.shannonPillMono)
                .foregroundStyle(entropyTint(for: reading))
                .help(reading.explain(at: Date()))
        } else {
            Text("—")
                .font(.shannonPillMono)
                .foregroundStyle(Color.shannonNeutral)
                .help(reading.explain(at: Date()))
        }
    }

    private var emptyBoard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // UX-015: same idle empty token as phone/pad/watch (not dual hard-code).
            Text(CompanionEmptyStateCopy.idleTitle)
                .font(.shannonMenuTitle)
                .foregroundStyle(Color.shannonPrimary)
            Text(PillChromePolicy.emptyRosterCopy)
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if FirstRunCoach.shouldShow() {
                Text(PillChromePolicy.statusLegend)
                    .font(.shannonMenuSection)
                    .foregroundStyle(Color.shannonTertiary)
            }
            HStack(spacing: 8) {
                hintChip("⌘D", "attach")
                if let display = fleetReading.display(at: Date()) {
                    hintChip(display.shortLabel, "live")
                }
            }
        }
    }

    private func hintChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.shannonPillMono)
                .foregroundStyle(Color.shannonAccent)
            Text(label)
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.shannonAccentSubtle))
        .overlay(Capsule().strokeBorder(Color.shannonAccent.opacity(0.35), lineWidth: 1))
    }

    /// Per-agent entropy rails. Each listed agent gets its own label + fill;
    /// when the board is empty, a single fleet-level honest readout remains.
    private var entropyStrip: some View {
        let pairs = listedAgentSurfaces
        return VStack(alignment: .leading, spacing: 6) {
            if pairs.isEmpty {
                fleetEntropyRow(fleetReading)
            } else {
                ForEach(pairs, id: \.agent.id) { pair in
                    let reading = agentReadings[pair.agent.id]
                        ?? EntropyProvenance.resolveForAgent(
                            agentId: pair.agent.id,
                            bridgeConnected: bridge.connected,
                            bridgeStatus: bridge.status,
                            gate: activity.agentEntropy,
                            gateDBAvailable: activity.gateDBAvailable
                        )
                    agentEntropyRow(agent: pair.agent, reading: reading, surface: pair.surface)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.shannonSurfaceSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.shannonSeparator, lineWidth: 1)
        )
        .padding(.top, 2)
    }

    /// True when at least one process/agent is attached (roster or busy).
    private var hasAttachedAgent: Bool {
        !summary.agents.isEmpty || !busy.isEmpty || summary.connected.count > 0
    }

    private func agentEntropyRow(
        agent: AgentActivitySnapshot,
        reading: EntropyReading,
        surface: AgentLiveSurface
    ) -> some View {
        let style = style(for: agent)
        // Prefer measured sole-live/alias bridge resolve over stale gate memory
        // that would blank the strip under enforce ("no H" despite attach H).
        let memReading: EntropyReading? = activity.entropyMemory.latest(for: agent.id) != nil
            ? activity.entropyMemory.reading(
                for: agent.id,
                gateDBAvailable: activity.gateDBAvailable
            )
            : nil
        let preferred = EntropyProvenance.preferredRowReading(
            live: reading,
            memory: memReading
        )
        let display = preferred.display(at: Date())
        let attached = agent.presence == .live
            || AgentEntropyMemory.shouldKeepTracking(
                presence: agent.presence,
                latest: activity.entropyMemory.latest(for: agent.id)?.measurement
            )
        let current = preferred.isMeasured
            && (agent.presence == .live || activity.entropyMemory.isCurrent(agentId: agent.id))
        let series = activity.entropyMemory.series(for: agent.id).bitSeries
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(style.displayName)
                    .font(.shannonMenuBody)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let display, current || preferred.isStale {
                    Text(display.shortLabel)
                        .font(.shannonPillMono)
                        .foregroundStyle(Self.color(from: display.gaugeColorRGB()))
                        .contentTransition(.identity)
                        .opacity(current ? 1 : 0.55)
                } else {
                    Text(preferred.isStale ? "stale" : "no H")
                        .font(.shannonPillMono)
                        .foregroundStyle(Color.shannonNeutral)
                }
                Text(display.map { $0.source.label } ?? "—")
                    .font(.shannonMenuMono)
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(1)
            }
            FluidEntropyRail(
                display: current ? display : nil,
                agentAttached: attached,
                reduceMotion: reduceMotion
            )
            .frame(height: 6)
            if series.count >= 2 {
                // Multi-sample memory trail — fixed height, no layout thrash.
                EntropySeriesSparkline(values: series, tint: style.palette.tint)
                    .frame(height: 10)
            }
            if surface.needsYou || surface.attention == .working || surface.attention == .finished {
                Text(surface.collapsedFocus)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(
                        surface.needsYou ? Color.shannonWarning : Color.shannonSecondary
                    )
                    .lineLimit(1)
            }
        }
        .help(preferred.explain(at: Date()))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.displayName) entropy. \(preferred.explain(at: Date())). \(surface.activityLine)")
    }

    private func fleetEntropyRow(_ reading: EntropyReading) -> some View {
        let display = reading.display(at: Date())
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(display.map(\.shortLabel) ?? "no detector")
                    .font(.shannonPillMono)
                    .foregroundStyle(
                        display.map { Self.color(from: $0.gaugeColorRGB()) } ?? Color.shannonNeutral
                    )
                    .contentTransition(.identity)
                Spacer(minLength: 0)
                Text(display.map { $0.source.label } ?? "absent")
                    .font(.shannonPillMono)
                    .foregroundStyle(Color.shannonTertiary)
            }
            FluidEntropyRail(
                display: display,
                agentAttached: hasAttachedAgent,
                reduceMotion: reduceMotion
            )
            .frame(height: 6)
        }
        .help(reading.explain(at: Date()))
    }

    /// Rail / badge tint: continuous gradient over bits when measured.
    private func stripTint(for reading: EntropyReading) -> Color {
        if let display = reading.display(at: Date()) {
            return Self.color(from: display.gaugeColorRGB())
        }
        return .shannonNeutral
    }

    // MARK: Media (secondary)

    private var mediaBlock: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.shannonQuaternary)
                    Capsule()
                        .fill(Color.shannonAccent)
                        .frame(width: geo.size.width * (nowPlaying.state.info?.progress ?? 0))
                }
            }
            .frame(height: 3)
            HStack(spacing: 18) {
                mediaBtn("backward.fill") { nowPlaying.previousTrack() }
                mediaBtn(nowPlaying.state.info?.isPlaying == true ? "pause.fill" : "play.fill") {
                    nowPlaying.togglePlayPause()
                }
                mediaBtn("forward.fill") { nowPlaying.nextTrack() }
                Spacer()
                Text(NowPlayingInfo.formatTime(nowPlaying.state.info?.elapsed ?? 0))
                    .font(.shannonPillMono)
                    .foregroundStyle(Color.shannonTertiary)
            }
        }
    }

    private func mediaBtn(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.shannonMenuBody)
                .foregroundStyle(Color.shannonPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        // Host resources (most constrained) sit next to battery / entropy.
        HStack(spacing: 6) {
            Circle()
                .fill(bridge.connected ? Color.shannonSuccess
                      : (busy.isEmpty ? Color.shannonTertiary : Color.shannonAccent))
                .frame(width: 6, height: 6)
                .shadow(
                    color: (bridge.connected ? Color.shannonSuccess : Color.shannonAccent).opacity(0.5),
                    radius: bridge.connected || !busy.isEmpty ? 3 : 0
                )
            Text(footerText)
                .font(.shannonPillMono)
                .foregroundStyle(Color.shannonSecondary)
                .lineLimit(1)
            Spacer()
            constrainedResourceChip
            if ingest.isHighlighting, let last = ingest.lastResult {
                Text(last.agent.map { "+\($0.id)" } ?? "⊘ not an agent")
                    .font(.shannonPillMono)
                    .foregroundStyle(last.captured ? Color.shannonSuccess : Color.shannonSecondary)
            }
        }
    }

    private var footerText: String {
        if let display = fleetReading.display(at: Date()) {
            return "\(display.shortLabel) · \(display.source.label)"
        }
        if bridge.connected {
            let backend = bridge.status?.backend ?? "bridge"
            return "bridge \(backend) · no measured H"
        }
        if !busy.isEmpty {
            return "\(busy.count) active · disk pets"
        }
        return "ready · ⌘D capture"
    }

    // MARK: Icons / colours — brand per agent (Science amber flask ≠ SuperGrok purple)

    /// Send the approval over the gate socket, then drop the card. The socket
    /// write runs off the main thread inside `activity.resolve`, which also owns
    /// the in-flight (debounce) and error state, so a second tap can't fire a
    /// duplicate resolution and a dead gate surfaces an inline error instead of
    /// freezing the UI. The card only collapses on a clean success.
    private func resolve(_ ask: GateDBReader.PendingAsk, approved: Bool) {
        Task {
            await activity.resolve(ask, approved: approved)
            if activity.lastResolveError == nil {
                if confirmation.armedInteractionId == ask.interactionId {
                    confirmation.cancel()
                }
                isExpanded = false
            }
        }
    }

    /// Arm gestures/voice for the newest open gate ask (P1.2).
    private func armGateAskIfNeeded() {
        guard let ask = pendingAsk else { return }
        guard confirmation.armedInteractionId != ask.interactionId else { return }
        confirmation.armForGateAsk(
            prompt: ask.prompt,
            interactionId: ask.interactionId,
            detail: AgentStyleCatalog.style(for: ask.agentId).displayName
        ) { answer, _ in
            Task {
                await activity.resolve(ask, approved: answer == .confirmed)
            }
        }
    }

    private func style(for a: AgentActivitySnapshot) -> AgentStyle {
        AgentStyleCatalog.style(for: a.id)
    }

    private func iconName(for a: AgentActivitySnapshot) -> String {
        style(for: a).systemImage
    }

    // MARK: Live agent surface (clean-room AgentNotch-class)

    /// Capsule badge: needs you / working / done / live (shared with menu bar).
    private func liveBadge(for a: AgentActivitySnapshot, surface: AgentLiveSurface) -> String {
        AgentLiveChrome.badgeLabel(
            surface: surface,
            fallbackStatusLine: a.statusLine
        )
    }

    private func liveDetailLine(for a: AgentActivitySnapshot, surface: AgentLiveSurface) -> String {
        if surface.attention == .working || surface.attention == .needsYou || surface.attention == .finished {
            return surface.activityLine
        }
        if !a.lastTask.isEmpty { return a.lastTask }
        return surface.activityLine
    }

    private func liveAttentionColor(for a: AgentActivitySnapshot, surface: AgentLiveSurface) -> Color {
        AgentLiveChrome.attentionColor(
            surface: surface,
            styleInk: ink(for: a)
        )
    }

    /// Brand tint for non-text marks — dots, icons, arcs — modulated by status.
    /// Idle agents keep their hue but recede; they must not compete with the
    /// agent that is actually working.
    private func color(for a: AgentActivitySnapshot) -> Color {
        let brand = style(for: a).palette.tint
        switch a.status {
        case .active, .midTask: return brand
        case .blocked: return .shannonWarning
        case .idle, .unknown: return brand.opacity(0.55)
        }
    }

    /// Contrast-corrected colour for agent *text*. Never the raw brand colour —
    /// Science amber on a white pill is about 1.8:1 and disappears outdoors.
    private func ink(for a: AgentActivitySnapshot) -> Color {
        switch a.status {
        case .blocked: return .shannonWarning
        default: return style(for: a).palette.ink
        }
    }

    private func color(for status: AgentRunStatus) -> Color {
        switch status {
        case .active, .midTask: return .shannonSuccess
        case .blocked: return .shannonWarning
        case .idle, .unknown: return .shannonTertiary
        }
    }
}

// MARK: - Confirmation (unchanged behaviour)

struct ConfirmationPromptView: View {
    @ObservedObject var confirmation: ConfirmationController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(Color.shannonWarning)
                Text(confirmation.prompt?.question ?? "")
                    .font(.shannonMenuTitle)
                    .foregroundStyle(Color.shannonPrimary)
                    .lineLimit(2)
            }
            if let detail = confirmation.prompt?.detail {
                Text(detail)
                    .font(.shannonPillMono)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // UX-028: Approve/Deny share GateAskActionCopy with gate cards / phone.
            HStack(spacing: 10) {
                answerButton(
                    GateAskActionCopy.approve,
                    systemImage: "checkmark",
                    tint: .shannonSuccess
                ) {
                    confirmation.answer(.confirmed)
                }
                answerButton(
                    GateAskActionCopy.deny,
                    systemImage: "xmark",
                    tint: .shannonError
                ) {
                    confirmation.answer(.denied)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: confirmation.gesturesAvailable
                      ? "airpods.gen3" : "airpods.gen3.slash")
                    .font(.shannonMenuFootnote)
                Text(confirmation.gesturesAvailable
                     ? HeadGestureCopy.availableHint
                     : HeadGestureCopy.unavailableLine(status: confirmation.gestureStatus))
                    .font(.shannonMenuFootnote)
                    .lineLimit(2)
            }
            .foregroundStyle(confirmation.gesturesAvailable ? Color.shannonSecondary : Color.shannonTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerButton(
        _ title: String, systemImage: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.shannonMenuBody)
                Text(title).font(.shannonMenuBody)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.22)))
            .overlay(Capsule().stroke(tint.opacity(0.55), lineWidth: 1))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

struct BatteryRing: View {
    let snapshot: BatterySnapshot
    var diameter: CGFloat = 18
    @State private var pulsing = false

    private var tint: Color {
        switch snapshot.alertLevel {
        case .normal:   return snapshot.isCharging ? .shannonSuccess : .shannonPrimary
        case .low:      return .shannonWarning
        case .critical: return .shannonError
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.shannonQuaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: snapshot.fillFraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if snapshot.isCharging {
                Image(systemName: "bolt.fill")
                    // Proportional SF glyph — system default design (native).
                    .font(.system(size: diameter * 0.4, weight: .semibold, design: .default))
                    .foregroundStyle(tint)
            } else if diameter >= 28 {
                Text("\(snapshot.percentage)")
                    // System monospaced digits for stable ring readout.
                    .font(.system(size: diameter * 0.32, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.shannonPrimary)
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(snapshot.alertLevel == .normal ? 1 : (pulsing ? 0.35 : 1))
        .animation(
            snapshot.alertLevel == .normal
                ? .default
                : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: pulsing
        )
        .onAppear { pulsing = snapshot.alertLevel != .normal }
        .onChange(of: snapshot.alertLevel) { level in
            pulsing = level != .normal
        }
    }
}

// MARK: - Multi-agent entropy series sparkline

/// Compact series trail from `AgentEntropyMemory` — fixed height, no thrash.
private struct EntropySeriesSparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let pts = Self.points(values: values, in: CGSize(width: w, height: h))
            Path { path in
                guard let first = pts.first else { return }
                path.move(to: first)
                for p in pts.dropFirst() { path.addLine(to: p) }
            }
            .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    private static func points(values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let span = max(hi - lo, 1e-6)
        let n = values.count
        return values.enumerated().map { i, v in
            let x = CGFloat(i) / CGFloat(n - 1) * size.width
            let y = size.height - CGFloat((v - lo) / span) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Thermodynamic sparkline (cool → warm → red lock-in)

/// Sliding-window H path colored by the last sample's thermodynamic map.
/// Pure points come from ``EntropyRailLogic`` — no invented series.
private struct ThermodynamicSparkline: View {
    let points: [EntropyRailPoint]

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let values = points.map(\.h)
            let pts = sparkPoints(values: values, in: CGSize(width: w, height: h))
            let tint = points.last.map {
                Color(red: $0.color.r, green: $0.color.g, blue: $0.color.b)
            } ?? Color.shannonNeutral
            ZStack(alignment: .bottomLeading) {
                // Soft fill under the curve
                Path { path in
                    guard let first = pts.first else { return }
                    path.move(to: CGPoint(x: first.x, y: h))
                    path.addLine(to: first)
                    for p in pts.dropFirst() { path.addLine(to: p) }
                    if let last = pts.last {
                        path.addLine(to: CGPoint(x: last.x, y: h))
                    }
                    path.closeSubpath()
                }
                .fill(tint.opacity(0.18))
                Path { path in
                    guard let first = pts.first else { return }
                    path.move(to: first)
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
                .stroke(
                    tint.opacity(0.95),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private func sparkPoints(values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let span = max(hi - lo, 1e-6)
        let n = values.count
        return values.enumerated().map { i, v in
            let x = CGFloat(i) / CGFloat(n - 1) * size.width
            let y = size.height - CGFloat((v - lo) / span) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Fluid entropy rail

/// Live Shannon H rail: fluid undulation when an agent is attached and H is
/// measured current. Static / desaturated otherwise (no fake healthy motion).
private struct FluidEntropyRail: View {
    let display: EntropyDisplay?
    let agentAttached: Bool
    let reduceMotion: Bool

    private static let tick: Double = 1.0 / 20.0

    var body: some View {
        let live = EntropyFluidGauge.shouldAnimate(
            agentAttached: agentAttached,
            isMeasuredCurrent: display?.isCurrent == true,
            bits: display?.bits,
            reduceMotion: reduceMotion
        )
        if live {
            TimelineView(.periodic(from: .now, by: Self.tick)) { tl in
                rail(at: tl.date.timeIntervalSinceReferenceDate)
            }
        } else {
            rail(at: 0)
        }
    }

    private func rail(at phase: TimeInterval) -> some View {
        let sample = EntropyFluidGauge.sample(
            display: display,
            agentAttached: agentAttached,
            phaseSeconds: phase,
            reduceMotion: reduceMotion
        )
        let tint = Color(red: sample.color.r, green: sample.color.g, blue: sample.color.b)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.shannonQuaternary)
                // Primary fill undulates with measured H.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(sample.isLive ? 0.92 : 0.85))
                    .frame(width: max(3, geo.size.width * CGFloat(sample.fill)))
                // Secondary fluid highlight (wave) only when live.
                if sample.isLive {
                    let w = max(4, geo.size.width * 0.12)
                    let x = (geo.size.width - w) * CGFloat((sample.waveOffset + 1) / 2)
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: w, height: max(2, geo.size.height * 0.55))
                        .offset(x: x, y: 0)
                }
            }
        }
    }
}

// MARK: - WaveformIdleView

/// Five-bar animated waveform shown in the collapsed pill when no agent is active.
/// Each bar oscillates at a slightly different frequency to mimic an ECG-style signal.
///
/// Ticks at 12 Hz, not 30 Hz. A `TimelineView` re-evaluates this body — and
/// therefore re-composites the entire enclosing pill, including its
/// `NSVisualEffectView`, border overlay and both shadow passes — once per tick,
/// forever, for as long as the app is idle. Measured with `sample(1)` on an
/// otherwise-idle machine, the 30 Hz version held the process at 52–55% CPU
/// with 1374 of ~3100 main-thread samples inside `CA::Transaction::flush()`.
/// An always-on menu-bar agent burning half a core to draw five 2 pt capsules is
/// the definition of invasive. At 12 Hz the motion is still smooth for bars that
/// complete a cycle in ~1 s, and the compositing load drops by ~60%.
///
/// `.drawingGroup()` flattens the five capsules into one offscreen layer so each
/// tick invalidates a single small texture rather than five sibling layers.
private struct WaveformIdleView: View {
    let color: Color
    /// When false (Reduce Motion / recessive quiet), paint a static silhouette.
    var animate: Bool = true

    /// Redraw interval. Keep this as low as the motion allows — every increase
    /// is paid continuously, forever, by an app that is supposed to be idle.
    private static let tickInterval: Double = 1.0 / 12.0

    var body: some View {
        if animate {
            TimelineView(.periodic(from: .now, by: Self.tickInterval)) { tl in
                bars(t: tl.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(t: 0) // static heights
        }
    }

    private func bars(t: Double) -> some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: barHeight(i: i, t: t))
            }
        }
        .drawingGroup()
    }

    /// Returns bar height in points (2…12) driven by independent sine oscillators.
    private func barHeight(i: Int, t: Double) -> CGFloat {
        if t == 0 {
            // Static “resting” silhouette under Reduce Motion / recessive.
            let rest: [CGFloat] = [4, 8, 11, 7, 5]
            return rest[i]
        }
        let phases: [Double] = [0.00, 1.26, 2.51, 0.94, 1.88]
        let freqs:  [Double] = [1.10, 0.85, 1.30, 1.00, 1.20]
        let amp = (sin(t * freqs[i] * .pi * 2 + phases[i]) + 1.0) * 0.5
        return CGFloat(2 + amp * 10)
    }
}
