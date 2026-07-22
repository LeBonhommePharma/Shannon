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
    @Binding var isExpanded: Bool

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: PillMetrics.corner, style: .continuous)
                .fill(.black)
                .shadow(radius: isExpanded ? 12 : 0)

            if isExpanded {
                expanded
            } else {
                collapsed
            }
        }
        .frame(
            width: isExpanded ? PillMetrics.expandedWidth : PillMetrics.collapsedWidth,
            height: isExpanded ? PillMetrics.expandedHeight : PillMetrics.collapsedHeight
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isExpanded)
        .onHover { hovering in
            isExpanded = hovering
        }
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
                .foregroundStyle(.white)
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
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(nowPlaying.state.info?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                    if !nowPlaying.providerAvailable {
                        Text("Now Playing unavailable — see BLOCKED.md")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.9))
                            .lineLimit(2)
                    }
                }
                Spacer()
                if let snap = battery.snapshot {
                    VStack(spacing: 2) {
                        BatteryRing(snapshot: snap, diameter: 30)
                        Text(snap.timeLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.6))
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
                    .fill(.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundStyle(.white.opacity(0.35))
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
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(.white.opacity(0.85))
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
            .foregroundStyle(.white.opacity(0.5))
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
                .foregroundStyle(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(bridge.connected ? Color.green : Color.white.opacity(0.25))
                .frame(width: 6, height: 6)
            if let status = bridge.status {
                Text("\(status.pillLabel) · \(status.backend)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(status.collapsed ? .orange : .white.opacity(0.55))
            } else {
                Text("agent offline")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
        }
    }
}

/// Circular charge ring; pulses amber at ≤20% and red at ≤10%.
struct BatteryRing: View {
    let snapshot: BatterySnapshot
    var diameter: CGFloat = 18

    @State private var pulsing = false

    private var tint: Color {
        switch snapshot.alertLevel {
        case .normal:   return snapshot.isCharging ? .green : .white
        case .low:      return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 2)
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
                    .foregroundStyle(.white.opacity(0.85))
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
