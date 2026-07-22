import SwiftUI
import PillCore

/// Sizes for the two pill states. The collapsed height matches the notch so
/// the pill reads as part of the hardware.
public enum PillMetrics {
    public static let collapsedHeight: CGFloat = 32
    public static let collapsedWidth: CGFloat = 240
    public static let expandedWidth: CGFloat = 380
    public static let expandedHeight: CGFloat = 168
    public static let corner: CGFloat = 16
}

struct PillView: View {
    @ObservedObject var nowPlaying: NowPlayingModel
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var bridge: ShannonBridge
    @ObservedObject var confirmation: ConfirmationController
    @Binding var isExpanded: Bool

    /// A pending question forces the pill open — an approval prompt the user
    /// has to hover to discover would be worse than useless.
    private var showExpanded: Bool { isExpanded || confirmation.isAwaitingConfirmation }

    /// The pill lights its accent border whenever the agent bridge is live —
    /// that glow is the only at-rest signal that Shannon is watching.
    private var isAgentActive: Bool { bridge.connected }

    private var corner: CGFloat {
        PillMetrics.corner
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
        .shannonPill(isActive: isAgentActive, cornerRadius: corner)
        .overlay(flashOverlay)
        .animation(.shannonFloat, value: showExpanded)
        .onHover { hovering in
            isExpanded = hovering
        }
    }

    /// Green wash on confirm, red on deny — the visual half of the gesture ack.
    private var flashOverlay: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(confirmation.flash == .confirm ? Color.shannonSuccess : Color.shannonError)
            .opacity(confirmation.flash == nil ? 0 : 0.35)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.25), value: confirmation.flash)
    }

    // MARK: Collapsed

    private var collapsed: some View {
        HStack(spacing: 8) {
            if let art = artworkImage {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Text(collapsedText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.shannonPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let snap = battery.snapshot {
                BatteryRing(snapshot: snap, diameter: 16)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PillMetrics.collapsedHeight)
    }

    /// Media wins the collapsed strip when something is playing; otherwise the
    /// pill falls back to the Shannon entropy readout, then to a bare label.
    private var collapsedText: String {
        if let label = nowPlaying.collapsedLabel { return label }
        if let status = bridge.status { return status.pillLabel }
        return "Shannon"
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                artworkView
                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlaying.state.info?.title ?? "Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.shannonPrimary)
                        .lineLimit(1)
                    Text(nowPlaying.state.info?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.shannonSecondary)
                        .lineLimit(1)
                    if !nowPlaying.providerAvailable {
                        Text("Now Playing unavailable — see BLOCKED.md")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.shannonWarning)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if let snap = battery.snapshot {
                    VStack(spacing: 2) {
                        BatteryRing(snapshot: snap, diameter: 30)
                        Text(snap.timeLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.shannonSecondary)
                    }
                }
            }

            scrubber
            transport
            Spacer(minLength: 0)
            footer
        }
        .padding(12)
    }

    private var artworkView: some View {
        Group {
            if let art = artworkImage {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.shannonSurfaceElevated)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundStyle(Color.shannonTertiary)
                    )
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var artworkImage: NSImage? {
        guard let data = nowPlaying.state.info?.artworkData else { return nil }
        return NSImage(data: data)
    }

    private var scrubber: some View {
        let info = nowPlaying.state.info
        return VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.shannonTertiary.opacity(0.5))
                    Capsule()
                        .fill(Color.shannonAccent)
                        .frame(width: geo.size.width * (info?.progress ?? 0))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        guard geo.size.width > 0 else { return }
                        nowPlaying.seek(to: value.location.x / geo.size.width)
                    }
                )
            }
            .frame(height: 4)

            HStack {
                Text(NowPlayingInfo.formatTime(info?.elapsed ?? 0))
                Spacer()
                Text(NowPlayingInfo.formatTime(info?.duration ?? 0))
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Color.shannonTertiary)
        }
    }

    private var transport: some View {
        HStack(spacing: 22) {
            transportButton("backward.fill") { nowPlaying.previousTrack() }
            transportButton(nowPlaying.state.info?.isPlaying == true
                            ? "pause.fill" : "play.fill") {
                nowPlaying.togglePlayPause()
            }
            transportButton("forward.fill") { nowPlaying.nextTrack() }
        }
    }

    private func transportButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .foregroundStyle(Color.shannonPrimary)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(bridge.connected ? Color.shannonSuccess : Color.shannonTertiary)
                .frame(width: 6, height: 6)
            if let status = bridge.status {
                Text("\(status.pillLabel) · \(status.backend)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(status.collapsed ? Color.shannonWarning : Color.shannonSecondary)
            } else {
                Text("agent offline")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.shannonTertiary)
            }
            Spacer()
        }
    }
}

/// The question the pill asks, answerable by head gesture or by clicking.
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

            // Always say which input is live: a user who nods at a pill that
            // is not listening deserves to know why nothing happened.
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
        _ title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
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

/// Circular charge ring; pulses amber at ≤20% and red at ≤10%.
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
            Circle()
                .stroke(Color.shannonTertiary, lineWidth: 2)
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
