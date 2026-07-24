import SwiftUI
import PillCore
import ShannonTheme

extension ShannonStatus {
    /// Backends that FABRICATE their numbers rather than measuring anything.
    ///
    /// - `demo`  — `python -m shannon.pill_bridge --demo`. `_DemoDetector`
    ///   (python/shannon/pill_bridge.py:219) returns `8.0 + 2.0*sin(n/12)`, and
    ///   `--demo` is the only standalone mode the bridge supports (:250).
    /// - `idle`  — `IdleTelemetry`, the local placeholder sine used when no
    ///   bridge is connected at all.
    /// - `unknown` — the bridge's fallback when a detector exposes no `backend`
    ///   attribute (:91). Provenance cannot be established, so it is not
    ///   trusted. A deception monitor must fail closed.
    static let syntheticBackends: Set<String> = ["demo", "idle", "unknown", ""]

    /// True when this reading is a placeholder, not a measurement.
    var isSynthetic: Bool {
        Self.syntheticBackends.contains(
            backend.trimmingCharacters(in: .whitespaces).lowercased()
        )
    }
}

/// Sizes for the two pill states.
public enum PillMetrics {
    public static let collapsedHeight: CGFloat = 34    // +2 for better text breathing room
    public static let collapsedWidth: CGFloat = 270    // +10 to fit the larger H= readout
    /// Footprint when there is genuinely nothing to report: glyph + entropy +
    /// battery, no filler copy. The pill should occupy the notch in proportion
    /// to what it has to say, and when it has nothing it says nothing.
    public static let idleWidth: CGFloat = 132
    public static let expandedWidth: CGFloat = 400
    /// FLOOR for the expanded board, not a fixed size. The board grows past this
    /// whenever it has more to show (more agents, a longer task line), and the
    /// window follows via `PillContentSizeKey`. Treating it as a fixed height is
    /// what pushed content off the top of the display.
    public static let expandedHeight: CGFloat = 220
    public static let corner: CGFloat = 16

    /// Hard ceiling as a fraction of the screen height, so a pathological agent
    /// list can never grow the panel past the display it lives on.
    public static let maxHeightFraction: CGFloat = 0.6
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
    @ObservedObject var idle: IdleTelemetryPublisher
    @ObservedObject var confirmation: ConfirmationController
    @ObservedObject var ingest: AgentIngestService
    @ObservedObject var activity: AgentActivityMonitor
    @Binding var isExpanded: Bool

    /// Drives the pulsing red border shown when entropy collapses (deception alert).
    @State private var collapsePulse  = false
    /// Drives the subtle breathing animation on the idle waveform (no agents busy).
    @State private var idleBreath     = false
    /// Drives the amber pulse shown while the gate is waiting on a human answer.
    @State private var askPulse       = false

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

    private var entropy: ShannonStatus { bridge.status ?? idle.status }
    private var summary: AgentActivitySummary { activity.summary }
    private var primary: AgentActivitySnapshot? { summary.primary }
    private var busy: [AgentActivitySnapshot] { summary.busy }

    /// True when media is playing *and* no agent is busy — media never hides agent work.
    private var showMedia: Bool {
        nowPlaying.state.info != nil && busy.isEmpty
    }

    private var agentActive: Bool { !busy.isEmpty || bridge.connected }

    /// No agent has been seen for over 30 s. Source: max(updatedAt) across the
    /// agent snapshots, i.e. the newest gate/pet timestamp. The breathing idle
    /// animation is bound to this and nothing else — previously it ran whenever
    /// no agent was *busy*, which included the very-much-alive moment just after
    /// a task finished.
    private var isQuiet: Bool {
        guard let newest = summary.agents.map(\.updatedAt).max() else { return true }
        return Date().timeIntervalSince(newest) > 30
    }

    private var corner: CGFloat {
        showExpanded ? ShannonRadius.xl : ShannonRadius.lg
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

    private var collapsedWidth: CGFloat {
        isRecessive ? PillMetrics.idleWidth : PillMetrics.collapsedWidth
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
            height: showExpanded ? nil : PillMetrics.collapsedHeight
        )
        .frame(minHeight: showExpanded ? PillMetrics.expandedHeight : nil)
        // Report the laid-out size so PillWindowController can size the panel to
        // match. Without this the window stays 400x220 and the extra content,
        // though now correctly laid out, would still land outside the window.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PillContentSizeKey.self, value: proxy.size)
            }
        )
        .shannonPill(isActive: agentActive, isQuiet: isRecessive, cornerRadius: corner)
        .overlay(flashOverlay)
        // Only the pill capsule takes hits. The transparent surround around it
        // must stay click-through — see PillHost in PillWindowController.
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .animation(.shannonFloat, value: showExpanded)
        .animation(.shannonFloat, value: isRecessive)
        .animation(.shannonSnap, value: summary.busyCount)
        // Spring transition when the primary agent switches (e.g. Claude → Codex).
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: summary.primary?.displayName)
        .onHover { hovering in
            if hovering { isExpanded = true }
        }
        .onTapGesture { isExpanded.toggle() }
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
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    askPulse = true
                }
            } else {
                withAnimation(.default) { askPulse = false }
            }
        }
        // Start / stop the entropy-collapse pulse border.
        .onChange(of: collapseAlarm) { collapsed in
            if collapsed {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    collapsePulse = true
                }
            } else {
                withAnimation(.default) { collapsePulse = false }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(collapsedText)
        .accessibilityHint("Click to expand agent status")
        // Kick off the idle breathing animation once the view appears.
        .onAppear { idleBreath = true }
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
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color.shannonWarning, lineWidth: askPulse ? 2.0 : 1.0)
                .opacity(hasPendingAsk ? (askPulse ? 0.95 : 0.35) : 0)
                .allowsHitTesting(false)

            // Entropy-collapse deception-alert border: always present,
            // invisible until entropy collapses, then pulses red.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
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
        HStack(spacing: 8) {
            // Wider frame so 15 pt emoji has breathing room without clipping.
            statusGlyph
                .frame(width: 20, height: 18)

            // The one line read from the corner of the eye. Proportional rather
            // than monospaced (wider apertures, easier word-shape recognition)
            // and a full semibold so it holds up against a bright desktop.
            //
            // Suppressed entirely when recessive: "Shannon · ready" is filler,
            // and filler is exactly what makes an always-on overlay invasive.
            if !isRecessive {
                Text(collapsedText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.shannonPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 2)

            entropyReadout

            if summary.busyCount > 1 {
                Text("\(summary.busyCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.shannonAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.shannonAccentSubtle))
                    .help("\(summary.busyCount) agents currently busy")
            }

            // Pending-approval marker. Source: agent_interactions.
            if hasPendingAsk {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.shannonWarning)
                    .help("An agent is waiting for your approval — click to answer")
            }

            if collapseAlarm {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.shannonWarning)
            }

            if let snap = battery.snapshot {
                BatteryRing(snapshot: snap, diameter: 15)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PillMetrics.collapsedHeight)
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
            WaveformIdleView(color: statusDotColor)
                .frame(width: 16, height: 14)
                .scaleEffect(idleBreath && isQuiet ? 0.84 : 1.0)
                .opacity(idleBreath && isQuiet ? 0.50 : 1.0)
                .animation(
                    .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                    value: idleBreath && isQuiet
                )
                .help(isQuiet
                      ? "No agent activity for over 30 s"
                      : "Agents idle but recently active")
        }
    }

    /// True when the number on screen came from a real detector rather than the
    /// local placeholder waveform.
    ///
    /// `entropy` falls back to `idle.status` whenever the bridge socket is
    /// absent (see the `entropy` property). That fallback is a synthetic sine —
    /// `IdleTelemetry` — with `backend == "idle"`, and it is *always* in the
    /// healthy band and *never* reports `collapsed`. Rendering it identically to
    /// a measured value would mean a dead detector looks exactly like a
    /// perfectly healthy one, which is the worst possible failure mode for a
    /// deception monitor. Everything downstream of this flag exists to keep the
    /// two visually distinct.
    /// Connectivity is NOT provenance. `bridge.connected` alone was the wrong
    /// test: `python -m shannon.pill_bridge --demo` opens a real socket and
    /// serves a real-looking payload whose numbers are `8.0 + 2.0*sin(n/12)`.
    /// That flipped this flag true and rendered a sine wave with the full
    /// measured styling — no `~`, live colour coding, and real collapse alarms.
    private var isMeasured: Bool { bridge.connected && !entropy.isSynthetic }

    /// A collapse we are willing to raise the deception alarm for.
    ///
    /// `entropy.collapsed` is whatever the producer asserts, and a synthetic
    /// producer asserts it constantly: `_DemoDetector.is_collapsed` is
    /// `delta_h < -1.8` over a ±2.0 sine, which is true for **28.8%** of ticks.
    /// Left ungated, `--demo` pulses the red "Entropy collapse" border about a
    /// third of the time it is running. Alarms are only as trustworthy as their
    /// provenance, so the alarm paths key off this and never off
    /// `entropy.collapsed` directly.
    private var collapseAlarm: Bool { entropy.collapsed && isMeasured }

    /// Entropy score, 11 pt so the H value is readable at arm's length.
    ///
    /// Digits interpolate via `.numericText()` rather than hard-swapping: the
    /// producers publish at 1 Hz, so an un-animated label visibly jumps once a
    /// second. The transition carries the eye across the gap.
    @ViewBuilder
    private var entropyReadout: some View {
        if entropy.entropy > 0 {
            Text(entropyBadge)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(entropyTint)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.45), value: entropy.entropy)
                .help(entropyTooltip)
                .accessibilityLabel(entropyTooltip)
        }
    }

    /// `~` marks a simulated value. Unmarked means measured.
    private var entropyBadge: String {
        let h = String(format: "%.1f", entropy.entropy)
        return isMeasured ? "H\(h)" : "~H\(h)"
    }

    /// Simulated readings render in `shannonNeutral` — the token whose whole
    /// job is "no signal / not applicable" — so a placeholder can never be
    /// mistaken for a healthy measurement at a glance.
    private var entropyTint: Color {
        guard isMeasured else { return .shannonNeutral }
        if entropy.collapsed { return .shannonError }
        return entropy.entropy < 5.0 ? .shannonWarning : .shannonSecondary
    }

    /// Spells out the entropy reading against the gate's own thresholds, and
    /// says so in plain language when there is no detector behind the number.
    private var entropyTooltip: String {
        let h = entropy.entropy
        guard isMeasured else {
            return String(
                format: "H \u{2248} %.2f bits \u{2014} SIMULATED, not a measurement. "
                    + "No detector is connected (source: %@), so the pill is showing a local "
                    + "placeholder waveform. Collapse detection is NOT running. "
                    + "Start the Shannon bridge to monitor real token entropy.",
                h, entropy.agent ?? entropy.backend
            )
        }
        let verdict = entropy.collapsed
            ? "collapse detected"
            : (h < 5.0 ? "approaching the block threshold 5.0" : "healthy")
        return String(
            format: "Shannon entropy H=%.2f bits, \u{0394}H %+.2f \u{2014} %@ (source: %@)",
            h, entropy.deltaH, verdict, entropy.agent ?? entropy.backend
        )
    }

    private var statusDotColor: Color {
        if collapseAlarm { return .shannonWarning }
        if bridge.connected { return .shannonSuccess }
        if !busy.isEmpty { return .shannonAccent }
        return .shannonTertiary
    }

    /// Priority: busy agents → fresh ingest → media → quiet.
    private var collapsedText: String {
        if !busy.isEmpty { return summary.collapsedText }
        if ingest.isHighlighting, let last = ingest.lastResult {
            return "+\(last.agent.displayName)"
        }
        if let label = nowPlaying.collapsedLabel { return label }
        if let recent = primary, !recent.lastTask.isEmpty,
           Date().timeIntervalSince(recent.updatedAt) < 600 {
            return recent.collapsedLine
        }
        return "Shannon · ready"
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

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
        if collapseAlarm { return .shannonWarning }
        if let p = busy.first { return ink(for: p) }
        if bridge.connected { return .shannonSuccess }
        return .shannonAccent
    }

    private var headerTitle: String {
        if collapseAlarm { return "Entropy collapse" }
        if let p = busy.first {
            return busy.count == 1 ? p.displayName : "\(busy.count) agents active"
        }
        if showMedia { return nowPlaying.state.info?.title ?? "Now Playing" }
        return "Shannon"
    }

    private var headerSubtitle: String {
        if collapseAlarm {
            return String(format: "H %.1f  ΔH %+.1f · %@", entropy.entropy, entropy.deltaH,
                          entropy.agent ?? entropy.backend)
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
            // entropyDelta is passed only while the bridge is genuinely
            // connected: a companion must not look alarmed because of a
            // simulated reading, and `bridge.status` is nil precisely when the
            // number on screen is the idle placeholder.
            if #available(macOS 14, *) {
                CompanionBoardView(
                    summary: summary,
                    entropyDelta: bridge.connected ? bridge.status?.deltaH : nil,
                    maxRows: busy.isEmpty ? 3 : 4
                )
            } else {
                // The companions are Canvas-drawn and need macOS 14; the package
                // still deploys to 13. Falling back to the plain rows loses only
                // the artwork, never information — the companion restates status,
                // it is not the only place status appears.
                let rows = Array((busy.isEmpty ? summary.agents.prefix(3) : busy.prefix(4)))
                ForEach(rows) { agent in
                    agentRow(agent)
                }
            }
            // Entropy strip is always visible — ambient signal even when bridge is idle.
            entropyStrip
        }
    }

    private func agentRow(_ a: AgentActivitySnapshot) -> some View {
        HStack(spacing: 8) {
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

    private var emptyBoard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No agents running")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.shannonPrimary)
            Text("Switch to Terminal, Claude, ChatGPT, Codex, or a browser and press ⌘D to attach that session as an agent with its own pet.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.shannonSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                hintChip("⌘D", "capture")
                hintChip("agent: id", "clipboard")
                if bridge.connected {
                    hintChip("H \(String(format: "%.1f", entropy.entropy))", "live")
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

    /// Same rule as `entropyTint`, but the strip's healthy state is green
    /// rather than plain secondary text.
    private var stripEntropyTint: Color {
        guard isMeasured else { return .shannonNeutral }
        if entropy.collapsed { return .shannonError }
        return entropy.entropy < 5.0 ? .shannonWarning : .shannonSuccess
    }

    private var entropyStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // H value — prominent, coloured by health (grey when simulated)
                HStack(spacing: 3) {
                    Text(isMeasured ? "H" : "~H")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.shannonTertiary)
                    Text(String(format: "%.2f", entropy.entropy))
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(stripEntropyTint)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.45), value: entropy.entropy)
                }
                // ΔH value — coloured red when large negative delta (collapse risk)
                HStack(spacing: 3) {
                    Text("ΔH")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.shannonTertiary)
                    Text(String(format: "%+.2f", entropy.deltaH))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(
                            !isMeasured ? Color.shannonNeutral
                            : (entropy.deltaH < -1.5 ? Color.shannonError
                               : (entropy.deltaH < -0.5 ? Color.shannonWarning : Color.shannonSecondary))
                        )
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.45), value: entropy.deltaH)
                }
                Spacer(minLength: 0)
                // "simulated", not "idle" — "idle" reads as "the detector is
                // connected and quiet", which is the opposite of the truth.
                Text(isMeasured ? entropy.backend : "simulated")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(isMeasured ? Color.shannonSecondary : Color.shannonNeutral)
                    .help(entropyTooltip)
            }
            // Progress rail — taller and more visible than the old 5 pt bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.shannonQuaternary)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(stripEntropyTint)
                        // Producers publish at 1 Hz; without this the rail
                        // jumps in discrete hops once a second.
                        .frame(width: geo.size.width * CGFloat(min(max(entropy.entropy / 12.0, 0.04), 1)))
                        .animation(.easeInOut(duration: 0.45), value: entropy.entropy)
                }
            }
            .frame(height: 7)
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
            if ingest.isHighlighting, let last = ingest.lastResult {
                Text("+\(last.agent.id)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.shannonSuccess)
            }
        }
    }

    private var footerText: String {
        if bridge.connected {
            let agent = entropy.agent.map { " · \($0)" } ?? ""
            return "bridge \(entropy.backend)\(agent)"
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
                isExpanded = false
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

    /// Redraw interval. Keep this as low as the motion allows — every increase
    /// is paid continuously, forever, by an app that is supposed to be idle.
    private static let tickInterval: Double = 1.0 / 12.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tickInterval)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 2, height: barHeight(i: i, t: t))
                }
            }
            .drawingGroup()
        }
    }

    /// Returns bar height in points (2…12) driven by independent sine oscillators.
    private func barHeight(i: Int, t: Double) -> CGFloat {
        // Phase offsets and frequencies give each bar a distinct rhythm.
        let phases: [Double] = [0.00, 1.26, 2.51, 0.94, 1.88]
        let freqs:  [Double] = [1.10, 0.85, 1.30, 1.00, 1.20]
        let amp = (sin(t * freqs[i] * .pi * 2 + phases[i]) + 1.0) * 0.5   // 0…1
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
