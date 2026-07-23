import SwiftUI
import ShannonCore
import ShannonTheme

/// A full-screen view styled as a watch face.
///
/// watchOS does not let third-party apps ship real watch faces, so this is the
/// next best thing: when Shannon is foregrounded it looks and behaves like one.
/// The complications in the sibling extension cover the actual watch face.
///
/// Always-On is treated as a first-class state, not an afterthought: in
/// reduced luminance the layout drops to time plus one line, and the accent
/// dims to 15%, which keeps burn-in low and the display legible.
@available(watchOS 10.0, *)
struct ShannonFaceView: View {
    let model: WatchModel
    /// Opt-in ambient biofeedback; inert unless LP has enabled it.
    var heartRate: HeartRateMonitor?
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var snapshot: ShannonSnapshot { model.snapshot }
    private var docking: DockingProgress? {
        snapshot.docking.first(where: { $0.isRunning }) ?? snapshot.docking.first
    }
    private var agent: AgentState? { snapshot.agents.rankedForDisplay().first }

    private var accent: Color {
        // Always-On dims to 15% for burn-in; an elevated heart rate (only when
        // that feature is enabled) brightens slightly instead.
        let base = isLuminanceReduced ? 0.15 : 1.0
        let elevated = (heartRate?.isEnabled == true) && (heartRate?.isElevated == true)
        return Color.shannonAccent.opacity(isLuminanceReduced ? base : (elevated ? 1.0 : 0.9))
    }

    var body: some View {
        // TimelineView drives the clock; in Always-On watchOS throttles this
        // to once a minute on its own, so there is no separate AOD timer.
        TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 60 : 1)) { context in
            VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
                clock(context.date)

                if !isLuminanceReduced {
                    if let pending = model.pendingConfirmation {
                        // The gate takes over the face — no sheet, no stack.
                        GateApprovalView(model: model, pending: pending)
                    } else {
                        if model.delivery != .idle {
                            // Answer in flight: show where it is instead of
                            // pretending nothing happened.
                            DeliveryRow(delivery: model.delivery, accent: accent)
                        }
                        if let docking { DockingRow(progress: docking, accent: accent) }
                        if let agent { AgentRow(agent: agent) }
                        if let media = snapshot.nowPlaying, !media.isIdle {
                            MediaRow(media: media)
                        }
                    }
                } else {
                    // Always-On: exactly one line of status, nothing else.
                    Text(snapshot.complicationLine())
                        .font(.shannonMono)
                        .foregroundStyle(Color.shannonSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .containerBackground(Color.shannonBackground.gradient, for: .navigation)
    }

    private func clock(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(isLuminanceReduced ? Color.shannonSecondary : Color.shannonPrimary)
                .contentTransition(.numericText())
                .accessibilityAddTraits(.isButton)

            Text(date, format: .dateTime.weekday(.wide).day())
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonTertiary)
        }
    }
}

/// Where the last answer is on its way to the phone.
@available(watchOS 10.0, *)
struct DeliveryRow: View {
    let delivery: WatchModel.AnswerDelivery
    let accent: Color

    var body: some View {
        HStack(spacing: ShannonSpacing.xs) {
            switch delivery {
            case .idle:
                EmptyView()
            case .sending:
                ProgressView().controlSize(.mini)
                Text("Sending answer…")
            case .sent:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                Text("Answer sent")
            case .queued:
                Image(systemName: "tray.and.arrow.up")
                Text("Answer queued for iPhone")
            }
        }
        .font(.shannonCaption)
        .foregroundStyle(Color.shannonSecondary)
    }
}

@available(watchOS 10.0, *)
struct DockingRow: View {
    let progress: DockingProgress
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: ShannonSpacing.xs) {
                ProgressView(value: progress.fraction)
                    .tint(accent)
                Text("\(Int(progress.fraction * 100))%")
                    .font(.shannonMono)
                    .foregroundStyle(Color.shannonSecondary)
            }
            Text(progress.benchmarkName)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(Color.shannonPrimary)
                .lineLimit(1)
            Text(statusLine)
                .font(.shannonMono)
                .foregroundStyle(Color.shannonSecondary)
                .lineLimit(1)
        }
    }

    private var statusLine: String {
        var parts = [progress.countLabel]
        if let rmsd = progress.bestRMSD { parts.append(String(format: "%.2fÅ", rmsd)) }
        if let eta = progress.etaLabel { parts.append(eta) }
        return parts.joined(separator: " · ")
    }
}

@available(watchOS 10.0, *)
struct AgentRow: View {
    let agent: AgentState

    var body: some View {
        HStack(spacing: ShannonSpacing.xs) {
            Text(agent.activity.glyph)
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonAccent)
            Text(agent.name)
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let entropy = agent.entropyBits {
                Text(String(format: "H %.2f", entropy))
                    .font(.shannonMono)
                    .foregroundStyle(agent.isCollapsed ? Color.shannonError : Color.shannonTertiary)
            }
        }
    }
}

@available(watchOS 10.0, *)
struct MediaRow: View {
    let media: NowPlayingSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(media.isPlaying ? "▶" : "❙❙") \(media.title)")
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonSecondary)
                .lineLimit(1)
            if !media.artist.isEmpty {
                Text(media.artist)
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(1)
            }
        }
    }
}
