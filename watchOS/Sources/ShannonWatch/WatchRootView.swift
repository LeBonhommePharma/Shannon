import SwiftUI
import ShannonCore

/// Three cards maximum, scrolled with the Digital Crown. Anything that needs
/// more detail belongs on the phone.
struct WatchRootView: View {
    @EnvironmentObject private var relay: WatchRelay

    private var snapshot: ShannonSnapshot { relay.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    if let docking = snapshot.docking.first(where: { $0.isRunning })
                        ?? snapshot.docking.first {
                        WatchDockingCard(progress: docking)
                    }

                    if let agent = snapshot.agents.rankedForDisplay().first {
                        WatchAgentCard(agent: agent)
                    }

                    if let media = snapshot.nowPlaying, !media.isIdle {
                        WatchNowPlayingCard(media: media) { relay.send($0) }
                    }

                    if snapshot.isEmpty {
                        Text("Waiting for iPhone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 30)
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("Shannon")
        }
    }
}

private struct WatchCard<Content: View>: View {
    var accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct WatchDockingCard: View {
    let progress: DockingProgress

    var body: some View {
        WatchCard(accent: .purple) {
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.benchmarkName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(progress.countLabel)
                    .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                ProgressView(value: progress.fraction).tint(.purple)
                HStack {
                    if let rmsd = progress.bestRMSD {
                        Text("\(String(format: "%.2f", rmsd))Å").font(.caption2.monospacedDigit())
                    }
                    Spacer()
                    if let eta = progress.etaLabel {
                        Text(eta).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct WatchAgentCard: View {
    let agent: AgentState

    private var accent: Color {
        switch agent.activity {
        case .running:  return .blue
        case .blocked:  return .orange
        case .errored:  return .red
        case .finished: return .green
        case .idle:     return .gray
        }
    }

    var body: some View {
        WatchCard(accent: accent) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(agent.activity.glyph) \(agent.name)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if !agent.taskTitle.isEmpty {
                    Text(agent.taskTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    Text("\(agent.turnCount) turns").font(.caption2.monospacedDigit())
                    Spacer()
                    if let entropy = agent.entropyLabel {
                        Text(entropy)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(agent.isCollapsed ? .red : .secondary)
                    }
                }
            }
        }
    }
}

struct WatchNowPlayingCard: View {
    let media: NowPlayingSnapshot
    var onCommand: (PlaybackCommand) -> Void

    var body: some View {
        WatchCard(accent: .pink) {
            VStack(alignment: .leading, spacing: 6) {
                Text(media.title).font(.caption.weight(.medium)).lineLimit(1)
                Text(media.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 20) {
                    Spacer()
                    Button { onCommand(.previousTrack) } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button { onCommand(.togglePlayPause) } label: {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { onCommand(.nextTrack) } label: {
                        Image(systemName: "forward.fill")
                    }
                    Spacer()
                }
                .buttonStyle(.plain)
            }
        }
    }
}
