import SwiftUI
import PillCore
import ShannonTheme

/// Sizes for the two pill states.
public enum PillMetrics {
    public static let collapsedHeight: CGFloat = 32
    public static let collapsedWidth: CGFloat = 260
    public static let expandedWidth: CGFloat = 400
    public static let expandedHeight: CGFloat = 196
    public static let corner: CGFloat = 16
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
    @State private var collapsePulse = false

    private var showExpanded: Bool { isExpanded || confirmation.isAwaitingConfirmation }

    private var entropy: ShannonStatus { bridge.status ?? idle.status }
    private var summary: AgentActivitySummary { activity.summary }
    private var primary: AgentActivitySnapshot? { summary.primary }
    private var busy: [AgentActivitySnapshot] { summary.busy }

    /// True when media is playing *and* no agent is busy — media never hides agent work.
    private var showMedia: Bool {
        nowPlaying.state.info != nil && busy.isEmpty
    }

    private var agentActive: Bool { !busy.isEmpty || bridge.connected }

    private var corner: CGFloat {
        showExpanded ? ShannonRadius.xl : ShannonRadius.lg
    }

    var body: some View {
        ZStack(alignment: .top) {
            if showExpanded {
                if confirmation.isAwaitingConfirmation {
                    ConfirmationPromptView(confirmation: confirmation)
                } else {
                    expanded
                }
            } else {
                collapsed
            }
        }
        .frame(
            width: showExpanded ? PillMetrics.expandedWidth : PillMetrics.collapsedWidth,
            height: showExpanded ? PillMetrics.expandedHeight : PillMetrics.collapsedHeight
        )
        .shannonPill(isActive: agentActive, cornerRadius: corner)
        .overlay(flashOverlay)
        .animation(.shannonFloat, value: showExpanded)
        .animation(.shannonSnap, value: summary.busyCount)
        // Spring transition when the primary agent switches (e.g. Claude → Codex).
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: summary.primary?.displayName)
        .onHover { hovering in
            if hovering { isExpanded = true }
        }
        .onTapGesture { isExpanded.toggle() }
        // Start / stop the entropy-collapse pulse border.
        .onChange(of: entropy.collapsed) { collapsed in
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
    }

    private var flashOverlay: some View {
        ZStack {
            // Confirmation flash fill (approve = green, deny = red).
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(confirmation.flash == .confirm ? Color.shannonSuccess : Color.shannonError)
                .opacity(confirmation.flash == nil ? 0 : 0.35)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.25), value: confirmation.flash)

            // Entropy-collapse deception-alert border: always present,
            // invisible until entropy collapses, then pulses red.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(
                    Color.shannonError,
                    lineWidth: (entropy.collapsed && collapsePulse) ? 2.0 : 0.5
                )
                .opacity(entropy.collapsed ? (collapsePulse ? 0.90 : 0.22) : 0)
                .allowsHitTesting(false)
        }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        HStack(spacing: 8) {
            statusGlyph
                .frame(width: 16, height: 16)

            Text(collapsedText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.shannonPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            if summary.busyCount > 1 {
                Text("\(summary.busyCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.shannonAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.shannonAccentSubtle))
            }

            if entropy.collapsed {
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

    @ViewBuilder
    private var statusGlyph: some View {
        if let p = busy.first {
            Image(systemName: iconName(for: p))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color(for: p))
                .help("\(style(for: p).emoji) \(style(for: p).displayName)")
        } else if showMedia {
            Image(systemName: "music.note")
                .font(.system(size: 11))
                .foregroundStyle(Color.shannonSecondary)
        } else {
            // Idle state: animated Shannon waveform in the agent's status colour.
            WaveformIdleView(color: statusDotColor)
                .frame(width: 16, height: 14)
        }
    }

    private var statusDotColor: Color {
        if entropy.collapsed { return .shannonWarning }
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.shannonSurfaceElevated)
                Image(systemName: headerIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(headerIconColor)
            }
            .frame(width: 40, height: 40)

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
        if entropy.collapsed { return "exclamationmark.triangle.fill" }
        if let p = busy.first { return iconName(for: p) }
        if showMedia { return "music.note" }
        return "waveform.path.ecg"
    }

    private var headerIconColor: Color {
        if entropy.collapsed { return .shannonWarning }
        if let p = busy.first { return color(for: p) }
        if bridge.connected { return .shannonSuccess }
        return .shannonAccent
    }

    private var headerTitle: String {
        if entropy.collapsed { return "Entropy collapse" }
        if let p = busy.first {
            return busy.count == 1 ? p.displayName : "\(busy.count) agents active"
        }
        if showMedia { return nowPlaying.state.info?.title ?? "Now Playing" }
        return "Shannon"
    }

    private var headerSubtitle: String {
        if entropy.collapsed {
            return String(format: "H %.1f  ΔH %+.1f · %@", entropy.entropy, entropy.deltaH,
                          entropy.agent ?? entropy.backend)
        }
        if let p = busy.first {
            let task = AgentActivitySnapshot.shorten(p.lastTask, max: 52)
            if busy.count == 1 {
                return task.isEmpty ? "\(p.status.label) · \(p.relativeAge)" : task
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
            let rows = Array((busy.isEmpty ? summary.agents.prefix(3) : busy.prefix(4)))
            ForEach(rows) { agent in
                agentRow(agent)
            }
            // Entropy strip is always visible — ambient signal even when bridge is idle.
            entropyStrip
        }
    }

    private func agentRow(_ a: AgentActivitySnapshot) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: a))
                .frame(width: 6, height: 6)
            Image(systemName: iconName(for: a))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color(for: a))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("\(style(for: a).emoji) \(style(for: a).displayName)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color(for: a))
                    Text(a.status.label)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(color(for: a))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(color(for: a).opacity(0.15)))
                    Spacer(minLength: 0)
                    Text(a.relativeAge)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.shannonTertiary)
                }
                if !a.lastTask.isEmpty {
                    Text(a.lastTask)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.shannonSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyBoard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No agents running")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.shannonSecondary)
            Text("Switch to Terminal, Claude, ChatGPT, Codex, or a browser and press ⌘D to attach that session as an agent with its own pet.")
                .font(.system(size: 10))
                .foregroundStyle(Color.shannonTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                hintChip("⌘D", "capture")
                hintChip("agent: id", "clipboard")
                if bridge.connected {
                    hintChip("H \(String(format: "%.1f", entropy.entropy))", "live")
                }
            }
        }
    }

    private func hintChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.shannonPrimary)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Color.shannonTertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.shannonSurfaceElevated))
    }

    private var entropyStrip: some View {
        HStack(spacing: 8) {
            Text(String(format: "H %.2f", entropy.entropy))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(entropy.collapsed ? Color.shannonWarning : Color.shannonSecondary)
            Text(String(format: "ΔH %+.2f", entropy.deltaH))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(entropy.deltaH < -1 ? Color.shannonWarning : Color.shannonTertiary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.shannonTertiary.opacity(0.35))
                    Capsule()
                        .fill(entropy.collapsed ? Color.shannonWarning
                              : (bridge.connected ? Color.shannonSuccess : Color.shannonAccent))
                        .frame(width: geo.size.width * CGFloat(min(max(entropy.entropy / 12.0, 0.04), 1)))
                }
            }
            .frame(height: 5)
            Text(bridge.connected ? entropy.backend : "idle")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.shannonTertiary)
        }
        .padding(.top, 2)
    }

    // MARK: Media (secondary)

    private var mediaBlock: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.shannonTertiary.opacity(0.5))
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
                .frame(width: 5, height: 5)
            Text(footerText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.shannonTertiary)
                .lineLimit(1)
            Spacer()
            if ingest.isHighlighting, let last = ingest.lastResult {
                Text("+\(last.agent.id)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
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

    private func style(for a: AgentActivitySnapshot) -> AgentStyle {
        AgentStyleCatalog.style(for: a.id)
    }

    private func iconName(for a: AgentActivitySnapshot) -> String {
        style(for: a).systemImage
    }

    /// Brand color modulated by run status.
    private func color(for a: AgentActivitySnapshot) -> Color {
        let brand = style(for: a).color
        switch a.status {
        case .active, .midTask: return brand
        case .blocked: return .shannonWarning
        case .idle, .unknown: return brand.opacity(0.45)
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
            Circle().stroke(Color.shannonTertiary, lineWidth: 2)
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
/// Uses TimelineView for smooth, GPU-backed animation without a Timer.
private struct WaveformIdleView: View {
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 2, height: barHeight(i: i, t: t))
                }
            }
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
