import SwiftUI
import ShannonCore
import ShannonTheme

/// The phone's only screen.
///
/// Design rules it follows literally: monochrome plus one accent, no gradients
/// or shadows, generous spacing, and nothing on screen when nothing matters.
/// Every control updates local state first and reconciles with CloudKit after,
/// so no tap ever waits on the network.
@available(iOS 17.0, *)
struct HomeView: View {
    let model: PhoneModel

    private var snapshot: ShannonSnapshot { model.store.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: ShannonLayout.IOSCard.interCardSpacing) {
                    if let pending = snapshot.oldestPendingConfirmation() {
                        ConfirmationCard(
                            confirmation: pending,
                            gesturesAvailable: model.isAwaitingConfirmation
                        ) { answer in
                            model.answer(answer, source: .tap)
                        }
                        .id(pending.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }

                    ForEach(snapshot.docking) { progress in
                        DockingCard(progress: progress)
                    }

                    if let media = snapshot.nowPlaying, !media.isIdle {
                        NowPlayingCard(media: media) { model.send($0) }
                    }

                    ForEach(snapshot.timers) { timer in
                        TimerCard(timer: timer)
                    }

                    ForEach(snapshot.agents.rankedForDisplay()) { agent in
                        AgentCard(agent: agent)
                    }

                    ForEach(snapshot.notifications) { note in
                        NotificationCard(note: note)
                    }

                    if snapshot.isEmpty {
                        EmptyStateView(error: model.store.lastError)
                            .padding(.top, 96)
                    }
                }
                .scrollTargetLayout()
                .shannonPageInset()
                .padding(.vertical, ShannonSpacing.sm)
            }
            .scrollTargetBehavior(.viewAligned)
            .background(Color.shannonBackground.ignoresSafeArea())
            .navigationTitle("Shannon")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AirPodsIndicator(monitor: model.airPods) }
                ToolbarItem(placement: .topBarTrailing) { MicButton(model: model) }
            }
            .animation(.shannonEase, value: snapshot.confirmations)
            .animation(.shannonEase, value: snapshot.agents)
            .animation(.shannonEase, value: snapshot.notifications)
        }
        .tint(.shannonAccent)
    }
}

// MARK: - Confirmation

/// The one card that interrupts. Everything else is passive status; this is
/// Shannon waiting on LP, so it gets the accent border and the top slot.
@available(iOS 17.0, *)
struct ConfirmationCard: View {
    let confirmation: PendingConfirmation
    let gesturesAvailable: Bool
    var onAnswer: (ConfirmationAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            Text(confirmation.question)
                .font(.shannonHeadline)
                .foregroundStyle(Color.shannonPrimary)

            if !confirmation.detail.isEmpty {
                Text(confirmation.detail)
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonSecondary)
            }

            HStack(spacing: ShannonSpacing.sm) {
                AnswerButton(title: "Confirm", symbol: "checkmark", tint: .shannonAccent) {
                    onAnswer(.confirmed)
                }
                AnswerButton(title: "Deny", symbol: "xmark", tint: .shannonSecondary) {
                    onAnswer(.denied)
                }
            }
            .padding(.top, ShannonSpacing.xs)

            if gesturesAvailable {
                Label("Nod to confirm · shake to deny", systemImage: "airpodspro")
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonTertiary)
            }
        }
        .shannonCard(isHighlighted: true)
    }
}

/// Buttons animate from local state on press and never wait on the write.
@available(iOS 17.0, *)
struct AnswerButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.shannonCallout)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ShannonSpacing.sm)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: ShannonRadius.md))
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.96 : 1)
        .animation(.shannonSnap, value: isPressed)
        .onLongPressGesture(minimumDuration: 0, pressing: { isPressed = $0 }, perform: {})
    }
}

// MARK: - Status cards

@available(iOS 17.0, *)
struct AgentCard: View {
    let agent: AgentState

    private var state: ShannonStatusDot.State {
        switch agent.activity {
        case .running:  return .active
        case .blocked:  return .warning
        case .errored:  return .error
        case .finished: return .success
        case .idle:     return .neutral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.xs) {
            HStack(spacing: ShannonSpacing.sm) {
                ShannonStatusDot(state: state)
                Text(agent.name)
                    .font(.shannonHeadline)
                    .foregroundStyle(Color.shannonPrimary)
                Spacer()
                Text("\(agent.turnCount)")
                    .shannonNumeric()
            }

            if !agent.taskTitle.isEmpty {
                Text(agent.taskTitle)
                    .font(.shannonBody)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(2)
            }

            if let entropy = agent.entropyLabel {
                Text(entropy)
                    .font(.shannonMono)
                    // A collapsed distribution is the whole point of Shannon —
                    // it must read at a glance, not blend into grey text.
                    .foregroundStyle(agent.isCollapsed ? Color.shannonError : Color.shannonTertiary)
            }
        }
        .shannonCard()
        .contextMenu {
            Button("Copy last action") {
                UIPasteboard.general.string = agent.lastAction
                Haptics.transition()
            }
        }
    }
}

@available(iOS 17.0, *)
struct DockingCard: View {
    let progress: DockingProgress

    var body: some View {
        HStack(spacing: ShannonSpacing.md) {
            ProgressRing(fraction: progress.fraction, label: progress.countLabel)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: ShannonSpacing.xs) {
                Text(progress.benchmarkName)
                    .font(.shannonHeadline)
                    .foregroundStyle(Color.shannonPrimary)
                    .lineLimit(1)

                Text(statusLine)
                    .font(.shannonMono)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .shannonCard()
    }

    /// One dense line instead of a stack of labelled rows — the ring already
    /// carries the headline number.
    private var statusLine: String {
        var parts: [String] = []
        if let rmsd = progress.bestRMSD { parts.append(String(format: "%.2fÅ", rmsd)) }
        if let eta = progress.etaLabel { parts.append(eta) }
        if !progress.currentTarget.isEmpty { parts.append(progress.currentTarget) }
        return parts.isEmpty ? "starting…" : parts.joined(separator: " · ")
    }
}

struct ProgressRing: View {
    var fraction: Double
    var label: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.shannonAccentSubtle, lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(fraction, 0.001))
                .stroke(Color.shannonAccent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.shannonEase, value: fraction)
            Text(label)
                .font(.shannonMono)
                .foregroundStyle(Color.shannonPrimary)
        }
    }
}

@available(iOS 17.0, *)
struct NowPlayingCard: View {
    let media: NowPlayingSnapshot
    var onCommand: (PlaybackCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            HStack(spacing: ShannonSpacing.sm) {
                Artwork(data: media.artworkJPEG)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: ShannonRadius.sm))

                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title)
                        .font(.shannonCallout)
                        .foregroundStyle(Color.shannonPrimary)
                        .lineLimit(1)
                    Text(media.artist)
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

                TransportButton(symbol: media.isPlaying ? "pause.fill" : "play.fill") {
                    onCommand(.togglePlayPause)
                }
                TransportButton(symbol: "forward.fill") { onCommand(.nextTrack) }
            }

            if media.duration > 0 {
                ProgressView(value: media.progress)
                    .tint(.shannonAccent)
            }
        }
        .shannonCard()
        .contextMenu {
            Button("Previous track") { onCommand(.previousTrack) }
        }
    }
}

/// Optimistic transport control: the glyph flips the instant it is tapped,
/// and the command reaches the Mac afterwards.
@available(iOS 17.0, *)
struct TransportButton: View {
    let symbol: String
    var action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.shannonPrimary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.9 : 1)
        .animation(.shannonSnap, value: isPressed)
        .onLongPressGesture(minimumDuration: 0, pressing: { isPressed = $0 }, perform: {})
    }
}

struct Artwork: View {
    let data: Data?

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.shannonSurfaceElevated
                Image(systemName: "music.note")
                    .foregroundStyle(Color.shannonTertiary)
            }
        }
    }
}

@available(iOS 17.0, *)
struct TimerCard: View {
    let timer: TimerState

    var body: some View {
        // TimelineView drives the countdown without a per-second @State write,
        // so only this label redraws each tick.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                Text(timer.label.isEmpty ? "Timer" : timer.label)
                    .font(.shannonCallout)
                    .foregroundStyle(Color.shannonSecondary)
                Spacer()
                Text(timer.remainingLabel(now: context.date))
                    .font(.system(.title3, design: .rounded).monospacedDigit().weight(.medium))
                    .foregroundStyle(timer.isPaused ? Color.shannonTertiary : Color.shannonPrimary)
            }
            .shannonCard()
        }
    }
}

/// Swipe to dismiss, long-press for the secondary action — no nested menus.
@available(iOS 17.0, *)
struct NotificationCard: View {
    let note: NotificationMirror
    @State private var offset: CGFloat = 0
    @State private var isDismissed = false

    var body: some View {
        if !isDismissed {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(note.sender)
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonAccent)
                    Spacer()
                    Text(note.postedAt.formatted(.relative(presentation: .numeric)))
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonTertiary)
                }
                if !note.title.isEmpty {
                    Text(note.title)
                        .font(.shannonCallout)
                        .foregroundStyle(Color.shannonPrimary)
                }
                Text(note.body)
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(2)
            }
            .shannonCard()
            .offset(x: offset)
            .gesture(
                DragGesture()
                    .onChanged { offset = $0.translation.width }
                    .onEnded { value in
                        if abs(value.translation.width) > 120 {
                            withAnimation(.shannonSnap) {
                                offset = value.translation.width > 0 ? 600 : -600
                                isDismissed = true
                            }
                            Haptics.transition()
                        } else {
                            withAnimation(.shannonSnap) { offset = 0 }
                        }
                    }
            )
            .contextMenu {
                Button("Copy") {
                    UIPasteboard.general.string = "\(note.sender): \(note.body)"
                    Haptics.transition()
                }
            }
        }
    }
}

// MARK: - Toolbar

@available(iOS 17.0, *)
struct AirPodsIndicator: View {
    let monitor: AirPodsMonitor

    var body: some View {
        if monitor.isConnected {
            HStack(spacing: 3) {
                Image(systemName: monitor.kind.symbol)
                // Battery is only ever shown when it is low enough to matter.
                if monitor.showsLowBattery, let percent = monitor.batteryPercent {
                    Text("\(percent)%").font(.shannonCaption)
                }
            }
            .foregroundStyle(monitor.showsLowBattery ? Color.shannonWarning : Color.shannonTertiary)
            .transition(.opacity)
        }
    }
}

/// Press and hold to dictate; release submits. Double-tap toggles hands-free.
@available(iOS 17.0, *)
struct MicButton: View {
    let model: PhoneModel
    @State private var isHolding = false

    var body: some View {
        if model.voice.isAvailable && model.voice.isAuthorized {
            Image(systemName: model.voice.isListening ? "mic.fill" : "mic")
                .foregroundStyle(model.voice.isListening ? Color.shannonAccent : Color.shannonTertiary)
                .scaleEffect(isHolding ? 1.15 : 1)
                .animation(.shannonSnap, value: isHolding)
                .accessibilityLabel("Dictate")
                .onLongPressGesture(minimumDuration: 0.15) {
                    // Fires on hold begin.
                } onPressingChanged: { pressing in
                    isHolding = pressing
                    if pressing {
                        Haptics.transition()
                        model.startDictation()
                    } else if !model.voice.isHandsFree {
                        model.finishDictation()
                    }
                }
                .overlay(alignment: .bottom) {
                    if model.voice.isListening {
                        VoiceOverlay(voice: model.voice)
                            .offset(y: 64)
                    }
                }
        }
    }
}

/// Live waveform plus the transcript, and a preview of the command that
/// releasing will run.
@available(iOS 17.0, *)
struct VoiceOverlay: View {
    let voice: VoiceDictation

    var body: some View {
        VStack(spacing: ShannonSpacing.xs) {
            HStack(spacing: 2) {
                ForEach(Array(voice.levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.shannonAccent)
                        .frame(width: 2, height: max(3, CGFloat(level) * 22))
                }
            }
            .animation(.shannonSnap, value: voice.levels)

            if !voice.transcript.isEmpty {
                Text(voice.transcript)
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: 220)
            }
        }
        .padding(ShannonSpacing.sm)
        .background(Color.shannonSurfaceElevated, in: RoundedRectangle(cornerRadius: ShannonRadius.md))
        .fixedSize()
    }
}

@available(iOS 17.0, *)
struct EmptyStateView: View {
    let error: String?

    var body: some View {
        VStack(spacing: ShannonSpacing.sm) {
            Text(error == nil ? "Nothing running" : "Can't reach iCloud")
                .font(.shannonHeadline)
                .foregroundStyle(Color.shannonSecondary)
            Text(error == nil
                 ? "Agent state from your Mac appears here."
                 // An idle Mac and a broken iCloud link look identical
                 // otherwise, and only one of them is worth acting on.
                 : "Check that this device is signed in to iCloud.")
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, ShannonSpacing.xl)
    }
}
