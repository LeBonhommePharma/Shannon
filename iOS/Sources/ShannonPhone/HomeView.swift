import SwiftUI
import UIKit
import ShannonCore

struct HomeView: View {
    @EnvironmentObject private var environment: PhoneEnvironment

    private var snapshot: ShannonSnapshot { environment.store.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let device = snapshot.device {
                        MacStatusCard(device: device)
                    }

                    ForEach(snapshot.docking) { progress in
                        DockingCard(progress: progress)
                    }

                    if let media = snapshot.nowPlaying, !media.isIdle {
                        NowPlayingCard(media: media) { environment.send($0) }
                    }

                    ForEach(snapshot.timers) { timer in
                        TimerCard(timer: timer)
                    }

                    ForEach(snapshot.agents.rankedForDisplay()) { agent in
                        AgentCard(agent: agent)
                    }

                    if !snapshot.notifications.isEmpty {
                        NotificationFeed(notifications: snapshot.notifications)
                    }

                    if snapshot.isEmpty {
                        EmptyStateView(error: environment.store.lastError)
                            .padding(.top, 80)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Shannon")
            .refreshable { await environment.store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SyncIndicator(
                        syncedAt: environment.store.lastSyncedAt,
                        isRefreshing: environment.store.isRefreshing
                    )
                }
            }
        }
    }
}

/// Cards share one chrome so the list reads as a single surface.
struct Card<Content: View>: View {
    var title: String
    var systemImage: String
    var accent: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct MacStatusCard: View {
    let device: MacDeviceState

    var body: some View {
        Card(title: device.deviceName, systemImage: "laptopcomputer", accent: .secondary) {
            HStack(spacing: 12) {
                Text(device.batteryLabel)
                    .font(.title3.weight(.semibold).monospacedDigit())
                ProgressView(value: device.fillFraction)
                    .tint(device.batteryPercent <= 20 && !device.isCharging ? .red : .green)
            }
            if device.isStale() {
                Text("Mac offline — last seen \(device.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AgentCard: View {
    let agent: AgentState

    private var accent: Color {
        switch agent.activity {
        case .running:  return .blue
        case .idle:     return .secondary
        case .blocked:  return .orange
        case .errored:  return .red
        case .finished: return .green
        }
    }

    var body: some View {
        Card(title: agent.name, systemImage: "cpu", accent: accent) {
            HStack {
                Text(agent.activity.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(accent)
                Spacer()
                Text("\(agent.turnCount) turns")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !agent.taskTitle.isEmpty {
                Text(agent.taskTitle).font(.body)
            }
            if !agent.lastAction.isEmpty {
                Text(agent.lastAction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let entropy = agent.entropyLabel {
                Text(entropy)
                    .font(.caption.monospacedDigit())
                    // A collapsed distribution is the whole point of Shannon —
                    // it must be visible at a glance, not buried in grey text.
                    .foregroundStyle(agent.isCollapsed ? .red : .secondary)
            }
        }
    }
}

struct DockingCard: View {
    let progress: DockingProgress

    var body: some View {
        Card(title: progress.benchmarkName, systemImage: "atom", accent: .purple) {
            HStack(spacing: 18) {
                ProgressRing(fraction: progress.fraction, label: progress.countLabel)
                    .frame(width: 84, height: 84)

                VStack(alignment: .leading, spacing: 6) {
                    if !progress.currentTarget.isEmpty {
                        LabeledContent("Target", value: progress.currentTarget)
                    }
                    if let rmsd = progress.bestRMSD {
                        LabeledContent("Best RMSD",
                                       value: "\(String(format: "%.2f", rmsd)) Å")
                    }
                    if let rate = progress.successRate {
                        LabeledContent("Success",
                                       value: "\(Int((rate * 100).rounded()))%")
                    }
                    if let eta = progress.etaLabel {
                        LabeledContent("ETA", value: eta)
                    }
                }
                .font(.caption.monospacedDigit())
            }
        }
    }
}

struct ProgressRing: View {
    var fraction: Double
    var label: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.purple.opacity(0.15), lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(fraction, 0.001))
                .stroke(Color.purple, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            Text(label)
                .font(.caption.weight(.semibold).monospacedDigit())
        }
    }
}

struct NowPlayingCard: View {
    let media: NowPlayingSnapshot
    var onCommand: (PlaybackCommand) -> Void

    var body: some View {
        Card(title: "Now Playing", systemImage: "music.note", accent: .pink) {
            HStack(spacing: 14) {
                Artwork(data: media.artworkJPEG)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(media.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }

            if media.duration > 0 {
                ProgressView(value: media.progress).tint(.pink)
            }

            HStack(spacing: 34) {
                Spacer()
                Button { onCommand(.previousTrack) } label: {
                    Image(systemName: "backward.fill")
                }
                Button { onCommand(.togglePlayPause) } label: {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                Button { onCommand(.nextTrack) } label: {
                    Image(systemName: "forward.fill")
                }
                Spacer()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }
}

struct Artwork: View {
    let data: Data?

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.pink.opacity(0.15)
                Image(systemName: "music.note").foregroundStyle(.pink)
            }
        }
    }
}

struct TimerCard: View {
    let timer: TimerState
    /// Drives the local countdown; only the deadline is synced.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Card(title: timer.label.isEmpty ? "Timer" : timer.label,
             systemImage: "timer", accent: .orange) {
            HStack {
                Text(timer.remainingLabel(now: now))
                    .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
                if timer.isPaused {
                    Text("paused").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onReceive(tick) { now = $0 }
    }
}

struct NotificationFeed: View {
    let notifications: [NotificationMirror]

    var body: some View {
        Card(title: "Mac notifications", systemImage: "bell.badge", accent: .teal) {
            ForEach(notifications) { note in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(note.sender).font(.caption.weight(.semibold))
                        Spacer()
                        Text(note.postedAt.formatted(.relative(presentation: .numeric)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !note.title.isEmpty {
                        Text(note.title).font(.subheadline)
                    }
                    Text(note.body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                .padding(.vertical, 4)
                if note.id != notifications.last?.id { Divider() }
            }
        }
    }
}

struct SyncIndicator: View {
    let syncedAt: Date?
    let isRefreshing: Bool

    var body: some View {
        if isRefreshing {
            ProgressView()
        } else if let syncedAt {
            Text(syncedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct EmptyStateView: View {
    let error: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing running").font(.headline)
            Text(error == nil
                 ? "Agent state from your Mac appears here."
                 // The distinction matters: an idle Mac and a broken iCloud
                 // link look identical otherwise.
                 : "Can't reach iCloud. Check that Shannon is signed in on this device.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
    }
}
