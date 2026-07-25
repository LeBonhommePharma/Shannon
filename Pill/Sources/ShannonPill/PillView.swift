import SwiftUI
import PillCore
import ShannonTheme

// `ShannonStatus.isSynthetic` / `.syntheticBackends` and the provenance rules
// built on them now live in PillCore (`EntropyProvenance.swift`), so the
// companion board, the popover and this view cannot drift apart on what counts
// as a measured reading.

/// Sizes for the two pill states.
///
/// Collapsed metrics are **physical-notch-first** (MacBook Pro 14"/16"):
/// height fills `safeAreaInsets.top` (~38 pt), width matches the measured cutout
/// (~220 pt at common 14" scales), and the shape is flush-top with a bottom lip
/// so the software island and the hardware hole share one silhouette.
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

    /// Bottom lip radius for the hardware island.
    public static func notchBottomRadius(height: CGFloat) -> CGFloat {
        ShannonLayout.Pill.notchBottomRadius(height: height)
    }

    /// Width from measured hardware notch (or defaults).
    public static func collapsedWidth(
        notchWidth: CGFloat?,
        recessive: Bool,
        physicalNotch: Bool = false
    ) -> CGFloat {
        ShannonLayout.Pill.collapsedWidth(
            notchWidth: notchWidth,
            recessive: recessive,
            physicalNotch: physicalNotch
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
    @Binding var isExpanded: Bool

    /// Drives the pulsing red border shown when entropy collapses (deception alert).
    @State private var collapsePulse  = false
    /// Drives the subtle breathing animation on the idle waveform (no agents busy).
    @State private var idleBreath     = false
    /// Drives the amber pulse shown while the gate is waiting on a human answer.
    @State private var askPulse       = false
    /// Subtle Liquid Glass hover lift on the collapsed island (no expand yet).
    @State private var hoverLift      = false
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

    /// Agents currently listed on the board (busy first, else roster sample).
    private var listedAgents: [AgentActivitySnapshot] {
        Array((busy.isEmpty ? summary.agents.prefix(3) : busy.prefix(4)))
    }

    /// Independent per-agent readings for every listed agent id.
    private var agentReadings: [String: EntropyReading] {
        EntropyProvenance.resolveAll(
            agentIds: listedAgents.map(\.id),
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status,
            gate: activity.agentEntropy,
            gateDBAvailable: activity.gateDBAvailable
        )
    }

    /// Per-agent companion deltas (measured only).
    private var agentCompanionDeltas: [String: Double] {
        EntropyProvenance.companionDeltas(
            agentIds: summary.agents.map(\.id),
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status,
            gate: activity.agentEntropy,
            gateDBAvailable: activity.gateDBAvailable
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

    /// Expanded board radius. Collapsed on hardware uses the notch bottom lip;
    /// collapsed on external displays uses a full capsule.
    private var corner: CGFloat {
        if showExpanded { return ShannonRadius.xl }
        if isPhysicalNotch {
            return PillMetrics.notchBottomRadius(height: liveCollapsedHeight)
        }
        return PillMetrics.collapsedCorner(height: liveCollapsedHeight)
    }

    /// Hit-test / overlay shape matching chrome: flush-top island vs capsule.
    private var pillOutline: UnevenRoundedRectangle {
        if !showExpanded && isPhysicalNotch {
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: corner,
                bottomTrailingRadius: corner,
                topTrailingRadius: 0,
                style: .continuous
            )
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: corner,
            bottomLeadingRadius: corner,
            bottomTrailingRadius: corner,
            topTrailingRadius: corner,
            style: .continuous
        )
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
    /// On a physical cutout always fills the full measured width (never recess).
    private var collapsedWidth: CGFloat {
        let measured: CGFloat? = isPhysicalNotch ? notchGeometry.notchRect.width : nil
        return PillMetrics.collapsedWidth(
            notchWidth: measured,
            recessive: isRecessive,
            physicalNotch: isPhysicalNotch
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
            // Hardware cutout: flush top + bottom lip so we paint the black hole.
            notchIsland: !showExpanded && isPhysicalNotch,
            cornerRadius: corner
        )
        .overlay(flashOverlay)
        // Only the pill island takes hits. The transparent surround around it
        // must stay click-through — see PillHost in PillWindowController.
        .contentShape(pillOutline)
        .animation(.shannon(.shannonFloat, reduceMotion: reduceMotion), value: showExpanded)
        .animation(.shannon(.shannonChrome, reduceMotion: reduceMotion), value: isRecessive)
        .animation(.shannon(.shannonSnap, reduceMotion: reduceMotion), value: summary.busyCount)
        // Spring transition when the primary agent switches (e.g. Claude → Codex).
        .animation(
            .shannon(.shannonEase, reduceMotion: reduceMotion),
            value: summary.primary?.displayName
        )
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
        // Start / stop the entropy-collapse pulse border.
        .onChange(of: collapseAlarm) { collapsed in
            if collapsed {
                if PillChromePolicy.allowsForeverPulse(reduceMotion: reduceMotion) {
                    withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                        collapsePulse = true
                    }
                } else {
                    collapsePulse = true
                }
                // Measured collapse only (collapseAlarm is provenance-gated).
                ShannonNotifier.notifyCollapse(
                    bits: fleetReading.currentBits,
                    source: fleetReading.measurement?.source.label ?? "bridge"
                )
            } else {
                withAnimation(reduceMotion ? nil : .default) { collapsePulse = false }
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
            pillOutline
                .stroke(Color.shannonWarning, lineWidth: askPulse ? 2.0 : 1.0)
                .opacity(hasPendingAsk ? (askPulse ? 0.95 : 0.35) : 0)
                .allowsHitTesting(false)

            // Entropy-collapse deception-alert border: always present,
            // invisible until entropy collapses, then pulses red.
            pillOutline
                .stroke(
                    Color.shannonError,
                    lineWidth: (collapseAlarm && collapsePulse) ? 2.0 : 0.5
                )
                .opacity(collapseAlarm ? (collapsePulse ? 0.90 : 0.22) : 0)
                .allowsHitTesting(false)
        }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        HStack(spacing: 6) {
            // Glyph stays compact so labels + metrics fit the notch band.
            statusGlyph
                .frame(width: 16, height: 16)

            // Single eye-line: agent status or most-constrained host metric.
            // Recessive mode drops the filler copy entirely.
            if !isRecessive {
                Text(collapsedText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.shannonPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .animation(.shannon(.shannonSnap, reduceMotion: reduceMotion), value: collapsedText)
            }

            Spacer(minLength: 2)

            // Busy + load: secondary chip only when title is agent text.
            if !busy.isEmpty, resources.snapshot.mostConstrained.map({ $0.percent >= 60 }) == true {
                constrainedResourceChip
            }

            // Entropy only when measured — "no H" is noise in the notch.
            if fleetReading.isMeasured {
                entropyReadout
            }

            if summary.busyCount > 1 {
                Text("\(summary.busyCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.shannonAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.shannonAccentSubtle))
                    .help("\(summary.busyCount) agents currently busy")
            }

            if hasPendingAsk {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.shannonWarning)
                    .help("An agent is waiting for your approval — click to answer")
            }

            if collapseAlarm {
                // Red — matches status legend / MenuBarController collapse glyph.
                // Amber is reserved for pending approval only.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.shannonError)
            }

            if let snap = battery.snapshot {
                BatteryRing(snapshot: snap, diameter: 13)
            }
        }
        // Physical notch (~220×38 band + hang on MBP 14"): keep glyphs in the
        // upper (menu-bar) portion; overhang below is pure black island chrome.
        .padding(.horizontal, isPhysicalNotch ? 14 : 12)
        .padding(.bottom, isPhysicalNotch ? ShannonLayout.Pill.physicalIslandOverhang : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .frame(height: liveCollapsedHeight)
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
                .font(.system(size: 15))
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
                .font(.system(size: 11))
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

    /// Collapsed-pill entropy badge driven by the provenance-bearing reading.
    /// Shows a number only when `display` returns one; otherwise "no H".
    @ViewBuilder
    private var entropyReadout: some View {
        let reading = fleetReading
        if let display = reading.display(at: Date()) {
            Text(display.shortLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(entropyTint(for: reading))
                .contentTransition(.numericText())
                .animation(.shannon(.shannonLiquid, reduceMotion: reduceMotion), value: display.bits)
                .help(reading.explain(at: Date()))
                .accessibilityLabel(reading.explain(at: Date()))
        } else {
            Text("no H")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.shannonNeutral)
                .help(reading.explain(at: Date()))
                .accessibilityLabel(reading.explain(at: Date()))
        }
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

    /// Priority: busy agents → fresh ingest → media → most-constrained host
    /// resource → quiet. When idle, the pill shows only the tightest gauge
    /// (CPU / GPU / RAM) so it stays notch-sized but still informative.
    private var collapsedText: String {
        if !busy.isEmpty { return summary.collapsedText }
        if ingest.isHighlighting, let last = ingest.lastResult {
            // `pillLabel` is "⊘ not an agent" for a refused capture — the pill
            // must never announce "+Something" for a capture that never ran.
            return last.pillLabel
        }
        if let label = nowPlaying.collapsedLabel { return label }
        if let recent = primary, !recent.lastTask.isEmpty,
           Date().timeIntervalSince(recent.updatedAt) < 600 {
            return recent.collapsedLine
        }
        if let c = resources.snapshot.mostConstrained, c.percent >= 60 {
            return c.shortLabel
        }
        return "Shannon · idle"
    }

    /// Compact host-resource chip for the collapsed pill when stressed, or
    /// always in the expanded footer. Most-constrained only (by design).
    @ViewBuilder
    private var constrainedResourceChip: some View {
        if let c = resources.snapshot.mostConstrained {
            let band = SystemResourceLogic.band(for: c.percent)
            // Load tint never uses ask-amber (warning) — reserved for approvals.
            let tint: Color = {
                switch SystemResourceLogic.loadChromeToken(for: band) {
                case .tertiary: return .shannonTertiary
                case .accent: return .shannonAccent
                case .error: return .shannonError
                case .warning: return .shannonAccent // map away from ask
                case .success: return .shannonSuccess
                }
            }()
            Text(c.shortLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
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
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.shannonTertiary)
                    .accessibilityLabel(PillChromePolicy.statusLegend)
            }

            if showMedia {
                mediaBlock
            } else if !busy.isEmpty || primary != nil {
                agentBoard
            } else {
                emptyBoard
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(12)
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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(headerIconColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.shannonPrimary)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if let snap = battery.snapshot {
                VStack(spacing: 2) {
                    BatteryRing(snapshot: snap, diameter: 28)
                    Text(snap.timeLabel)
                        .font(.system(size: 8))
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
        return "Shannon"
    }

    private var headerSubtitle: String {
        if collapseAlarm, let m = fleetReading.measurement {
            let delta = m.deltaH.map { String(format: "  ΔH %+.1f", $0) } ?? ""
            return String(format: "H %.1f%@ · %@", m.bits, delta, m.source.label)
        }
        if let p = busy.first {
            let task = AgentActivitySnapshot.shorten(p.lastTask, max: 52)
            if busy.count == 1 {
                return task.isEmpty ? p.statusLine : task
            }
            return task.isEmpty
                ? busy.map(\.displayName).prefix(3).joined(separator: " · ")
                : task
        }
        if showMedia {
            return nowPlaying.state.info?.artist ?? ""
        }
        return "⌘D capture · pets in ~/.shannon/pets"
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
            if #available(macOS 14, *) {
                CompanionBoardView(
                    summary: summary,
                    entropyDeltas: agentCompanionDeltas,
                    maxRows: busy.isEmpty ? 3 : 4
                )
            } else {
                // The companions are Canvas-drawn and need macOS 14; the package
                // still deploys to 13. Falling back to the plain rows loses only
                // the artwork, never information — the companion restates status,
                // it is not the only place status appears.
                ForEach(listedAgents) { agent in
                    agentRow(agent)
                }
            }
            // Per-agent entropy rails — each listed agent owns its own H.
            entropyStrip
        }
    }

    private func agentRow(_ a: AgentActivitySnapshot) -> some View {
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color(for: a))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(style(for: a).emoji) \(style(for: a).displayName)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ink(for: a))
                    Text(a.statusLine)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink(for: a))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(style(for: a).palette.wash))
                        .overlay(Capsule().strokeBorder(style(for: a).palette.edge, lineWidth: 1))
                    Spacer(minLength: 0)
                    agentEntropyBadge(reading)
                    Text(a.relativeAge)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.shannonSecondary)
                }
                if !a.lastTask.isEmpty {
                    Text(a.lastTask)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.shannonSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.shannonSurfaceElevated.opacity(0.6))
        )
    }

    @ViewBuilder
    private func agentEntropyBadge(_ reading: EntropyReading) -> some View {
        if let display = reading.display(at: Date()) {
            Text(display.shortLabel)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(entropyTint(for: reading))
                .help(reading.explain(at: Date()))
        } else {
            Text("—")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.shannonNeutral)
                .help(reading.explain(at: Date()))
        }
    }

    private var emptyBoard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No agents running")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.shannonPrimary)
            Text(PillChromePolicy.emptyRosterCopy)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.shannonSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if FirstRunCoach.shouldShow() {
                Text(PillChromePolicy.statusLegend)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.shannonAccent)
            Text(label)
                .font(.system(size: 9.5))
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
        let agents = listedAgents
        return VStack(alignment: .leading, spacing: 6) {
            if agents.isEmpty {
                fleetEntropyRow(fleetReading)
            } else {
                ForEach(agents) { agent in
                    let reading = agentReadings[agent.id]
                        ?? EntropyProvenance.resolveForAgent(
                            agentId: agent.id,
                            bridgeConnected: bridge.connected,
                            bridgeStatus: bridge.status,
                            gate: activity.agentEntropy,
                            gateDBAvailable: activity.gateDBAvailable
                        )
                    agentEntropyRow(agent: agent, reading: reading)
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

    private func agentEntropyRow(agent: AgentActivitySnapshot, reading: EntropyReading) -> some View {
        let style = style(for: agent)
        let display = reading.display(at: Date())
        let attached = hasAttachedAgent || agent.presence == .live
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(style.displayName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let display {
                    Text(display.shortLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.color(from: display.gaugeColorRGB()))
                        .contentTransition(.numericText())
                        .animation(.shannonLiquid, value: display.bits)
                } else {
                    Text(reading.isStale ? "stale" : "no H")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.shannonNeutral)
                }
                Text(display.map { $0.source.label } ?? "—")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(1)
            }
            FluidEntropyRail(
                display: display,
                agentAttached: attached,
                reduceMotion: reduceMotion
            )
            .frame(height: 6)
        }
        .help(reading.explain(at: Date()))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.displayName) entropy. \(reading.explain(at: Date()))")
    }

    private func fleetEntropyRow(_ reading: EntropyReading) -> some View {
        let display = reading.display(at: Date())
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(display.map(\.shortLabel) ?? "no detector")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        display.map { Self.color(from: $0.gaugeColorRGB()) } ?? Color.shannonNeutral
                    )
                    .contentTransition(.numericText())
                    .animation(.shannonLiquid, value: display?.bits ?? -1)
                Spacer(minLength: 0)
                Text(display.map { $0.source.label } ?? "absent")
                    .font(.system(size: 9, design: .monospaced))
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
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.shannonTertiary)
            }
        }
    }

    private func mediaBtn(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12))
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
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.shannonSecondary)
                .lineLimit(1)
            Spacer()
            constrainedResourceChip
            if ingest.isHighlighting, let last = ingest.lastResult {
                Text(last.agent.map { "+\($0.id)" } ?? "⊘ not an agent")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.shannonPrimary)
                    .lineLimit(2)
            }
            if let detail = confirmation.prompt?.detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                answerButton("Yes", systemImage: "checkmark", tint: .shannonSuccess) {
                    confirmation.answer(.confirmed)
                }
                answerButton("No", systemImage: "xmark", tint: .shannonError) {
                    confirmation.answer(.denied)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: confirmation.gesturesAvailable
                      ? "airpods.gen3" : "airpods.gen3.slash")
                    .font(.system(size: 9))
                Text(confirmation.gesturesAvailable
                     ? "Nod to confirm · shake to deny"
                     : "Head gestures unavailable — \(confirmation.gestureStatus)")
                    .font(.system(size: 9))
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
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: diameter * 0.4))
                    .foregroundStyle(tint)
            } else if diameter >= 28 {
                Text("\(snapshot.percentage)")
                    .font(.system(size: diameter * 0.32, weight: .medium, design: .rounded))
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

// MARK: - GateAskCard

/// The approval the gate is blocked on, answerable straight from the notch.
///
/// Data source: one `agent_interactions` row with status = 'pending'. Approving
/// or denying writes back over the gate socket via `GateApprovalClient`, using
/// the row's own `interaction_id` — the gate matches on that id and will not
/// clear the row for anything else.
struct GateAskCard: View {
    let ask: GateDBReader.PendingAsk
    /// True while this ask's approval is being written to the gate — buttons are
    /// swapped for a spinner so a second tap can't fire a duplicate resolution.
    var isResolving: Bool = false
    /// Last resolve failure, shown inline so a dead gate is never mistaken for a
    /// successful answer.
    var errorText: String? = nil
    /// Whether the gate socket is present. When false, the buttons would fail, so
    /// we say so up front instead of letting the tap error out.
    var gateAvailable: Bool = true
    let onAnswer: (Bool) -> Void

    private var style: AgentStyle { AgentStyleCatalog.style(for: ask.agentId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(style.emoji).font(.system(size: 14))
                Text(style.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.palette.ink)
                Text("needs approval")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
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

            if let errorText {
                Text(errorText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.shannonError)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !gateAvailable {
                Text("Hub offline — start the gate to approve from here")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.shannonWarning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.shannonSecondary)
                    Spacer(minLength: 0)
                } else {
                    answerButton("Approve", systemImage: "checkmark", tint: .shannonSuccess) {
                        onAnswer(true)
                    }
                    answerButton("Deny", systemImage: "xmark", tint: .shannonError) {
                        onAnswer(false)
                    }
                    Spacer(minLength: 0)
                    Text("right-click for more")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerButton(
        _ title: String, systemImage: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(gateAvailable ? tint : tint.opacity(0.4)))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!gateAvailable)
        .help("\(title) this request — sends interaction_id \(ask.interactionId) to the gate")
        .onHover { h in
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
