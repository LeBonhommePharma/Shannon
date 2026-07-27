import SwiftUI
import ShannonCore
import ShannonTheme

/// The phone's only screen.
///
/// Design rules: monochrome plus one accent, generous spacing, and nothing on
/// screen when nothing matters. The passive status list stays flat and
/// shadowless; the one exception is the confirmation banner, which floats over
/// the list on `.ultraThinMaterial` so it reads as a transient interruption
/// rather than another card. Every control updates local state first and
/// reconciles with CloudKit after, so no tap ever waits on the network.
@available(iOS 17.0, *)
struct HomeView: View {
    let model: PhoneModel

    private var snapshot: ShannonSnapshot { model.store.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: ShannonLayout.IOSCard.interCardSpacing) {
                    ForEach(snapshot.docking) { progress in
                        DockingCard(progress: progress)
                    }

                    if let media = snapshot.nowPlaying, !media.isIdle {
                        NowPlayingCard(media: media) { model.send($0) }
                    }

                    ForEach(snapshot.timers) { timer in
                        TimerCard(timer: timer)
                    }

                    // UX-006: Mac collapsed multi-agent density — count chip when
                    // more than one agent needs a glance (needs-you + working).
                    if let fleet = AgentListSkim.multiAgentCountLabel(
                        activeCount: AgentListSkim.activeFleetCount(in: snapshot)
                    ) {
                        HStack(spacing: ShannonSpacing.xs) {
                            Text(fleet)
                                .font(.shannonCaption.weight(.semibold))
                                .shannonNumeric()
                                .foregroundStyle(Color.shannonPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.shannonSurfaceElevated, in: Capsule())
                            // UX-055: fleet caption shares AgentListSkim (Mac collapsed help).
                            Text(AgentListSkim.multiAgentGlanceCaption)
                                .font(.shannonCaption)
                                .foregroundStyle(Color.shannonTertiary)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            AgentListSkim.multiAgentAccessibilityLabel(
                                activeCount: AgentListSkim.activeFleetCount(in: snapshot)
                            ) ?? "\(fleet) agents"
                        )
                    }

                    // Ranked skim rows: needs-you first, shared badge, short secondary.
                    ForEach(AgentListSkim.rows(in: snapshot)) { row in
                        AgentCard(row: row)
                    }

                    // UX-046: capacity under empty/offline EmptyStateView undercuts
                    // fail-closed tone (local Nominal thermal still paints as "live").
                    // Show Mac + phone capacity only when the roster has content.
                    if !snapshot.isEmpty {
                        // Host capacity (SSD / thermal / most-constrained) from Mac.
                        HostCapacityCard(
                            title: snapshot.device?.deviceName ?? "Mac",
                            capacity: snapshot.device?.capacity,
                            platformSymbol: "laptopcomputer"
                        )
                        .shannonCard()

                        // Local phone pressure (ProcessInfo thermal only — no die temp).
                        HostCapacityCard(
                            title: "iPhone",
                            capacity: LocalHostCapacity.current(platform: "iOS"),
                            platformSymbol: "iphone"
                        )
                        .shannonCard()
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
            // UX-025: brand title shares Core quietShort.
            .navigationTitle(CompanionFocusCopy.quietShort)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AirPodsIndicator(monitor: model.airPods) }
                ToolbarItem(placement: .topBarTrailing) { MicButton(model: model) }
            }
            // The confirmation rides above the scroll content as a compact
            // banner, so status keeps scrolling underneath it instead of being
            // shoved down the page. This is the one thing Shannon interrupts
            // for, and it is still only ever a banner — never a takeover.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let pending = snapshot.oldestPendingConfirmation() {
                    ConfirmationBanner(
                        confirmation: pending,
                        // UX-037: coaching follows actual motion arming, not mere pending.
                        gesturesArmed: model.headGesturesArmed,
                        gestureStatus: model.headGestureStatus,
                        lastError: model.store.lastError
                    ) { answer in
                        model.answer(answer, source: .tap)
                    }
                    .id(pending.id)
                    .padding(.horizontal, ShannonLayout.IOSCard.pageMargin)
                    .padding(.top, ShannonSpacing.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // A quiet, non-blocking hint that the Mac hub is unreachable, shown
            // only when there is other content on screen (an empty screen
            // already explains the disconnect through EmptyStateView).
            .safeAreaInset(edge: .bottom) {
                if model.store.lastError != nil && !snapshot.isEmpty {
                    DisconnectedPill()
                        .padding(.bottom, ShannonSpacing.xs)
                        .transition(.opacity)
                }
            }
            .animation(.shannonEase, value: snapshot.confirmations)
            .animation(.shannonEase, value: snapshot.agents)
            .animation(.shannonEase, value: snapshot.notifications)
            .animation(.shannonEase, value: model.store.lastError)
        }
        .tint(.shannonAccent)
    }
}

// MARK: - Press style

/// The one press treatment every tappable control uses.
///
/// Why this exists: the old controls wrapped a `Button` and *also* attached a
/// `.onLongPressGesture(minimumDuration: 0)` to drive the pressed scale. Inside
/// a `ScrollView` that long-press recognizer competes with both the button's
/// own tap gesture and the scroll's drag, and routinely wins the touch — so
/// the button's `action` never fired. On the confirmation card that read as
/// the app being *stuck*: the tap appeared to do nothing and the prompt never
/// cleared. Driving the pressed state from `ButtonStyle.Configuration.isPressed`
/// keeps a tap a tap, with no second gesture to swallow it.
struct ShannonPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.shannonSnap, value: configuration.isPressed)
    }
}

// MARK: - Confirmation

/// The one thing Shannon interrupts for, as a compact notification-style banner
/// rather than a full card in the list: a translucent `.ultraThinMaterial`
/// surface pinned above the scroll content, with the question and two inline
/// answers. It floats over status instead of pushing it around.
///
/// **UX-003:** Approve/Deny verbs + disabled copy when hub offline match Mac
/// `GateAskCard` via `GateAskActionCopy` (fail-closed — no silent dead taps).
@available(iOS 17.0, *)
struct ConfirmationBanner: View {
    let confirmation: PendingConfirmation
    /// True only when `HeadGestureListener` is actually armed (UX-037).
    let gesturesArmed: Bool
    /// Device-reported status for `HeadGestureCopy.unavailableLine`.
    var gestureStatus: String = "not available"
    /// `ShannonStore.lastError` — when set, answers cannot write back.
    var lastError: String? = nil
    var onAnswer: (ConfirmationAnswer) -> Void

    private var affordance: GateAskActionCopy.Affordance {
        GateAskActionCopy.companionAffordance(
            pending: confirmation,
            lastError: lastError
        )
    }

    var body: some View {
        let a = affordance
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            HStack(alignment: .top, spacing: ShannonSpacing.sm) {
                Image(systemName: "questionmark.bubble.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.shannonAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(GateAskActionCopy.needsApproval)
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonWarning)
                    Text(confirmation.question)
                        .font(.shannonCallout)
                        .foregroundStyle(Color.shannonPrimary)
                        .lineLimit(2)
                    if !confirmation.detail.isEmpty {
                        Text(confirmation.detail)
                            .font(.shannonCaption)
                            .foregroundStyle(Color.shannonSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            if let status = a.statusMessage {
                Text(status)
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: ShannonSpacing.sm) {
                AnswerButton(
                    title: a.denyLabel,
                    symbol: "xmark",
                    tint: .shannonSecondary,
                    enabled: a.canInteract
                ) {
                    onAnswer(.denied)
                }
                AnswerButton(
                    title: a.approveLabel,
                    symbol: "checkmark",
                    tint: .shannonAccent,
                    enabled: a.canInteract
                ) {
                    onAnswer(.confirmed)
                }
            }

            // UX-028 / UX-037: HeadGestureCopy with Mac pill — available only when armed.
            if a.canInteract {
                Label(
                    gesturesArmed
                        ? HeadGestureCopy.availableHint
                        : HeadGestureCopy.unavailableLine(status: gestureStatus),
                    systemImage: gesturesArmed ? "airpodspro" : "airpodspro.chargingcase.wireless"
                )
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonTertiary)
            }
        }
        .padding(ShannonSpacing.md)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: ShannonRadius.xl, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ShannonRadius.xl, style: .continuous)
                .strokeBorder(Color.shannonAccent.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.shannonShadow.opacity(0.5), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                a.canInteract
                    ? "\(GateAskActionCopy.needsApproval). \(confirmation.question)"
                    : "\(GateAskActionCopy.needsApproval). \(confirmation.question). \(a.statusMessage ?? "")"
            )
        )
    }
}

/// A single inline answer. Just a styled `Button` — no extra gesture — so a tap
/// always reaches `action`. See `ShannonPressStyle` for why that matters here.
@available(iOS 17.0, *)
struct AnswerButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.shannonCallout)
                .foregroundStyle(enabled ? tint : tint.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, ShannonSpacing.sm)
                .background(
                    (enabled ? tint : tint.opacity(0.4)).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: ShannonRadius.md)
                )
        }
        .buttonStyle(ShannonPressStyle())
        .disabled(!enabled)
    }
}

/// Quiet hub-offline chip. Subtle by design: a missed sync is worth noting,
/// not alarming. Copy shared with empty state (UX-002).
@available(iOS 17.0, *)
struct DisconnectedPill: View {
    var body: some View {
        Label(CompanionEmptyStateCopy.offlineChip, systemImage: "bolt.horizontal.circle")
            .font(.shannonCaption)
            .foregroundStyle(Color.shannonSecondary)
            .padding(.horizontal, ShannonSpacing.sm)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.shannonSeparator, lineWidth: ShannonStroke.hairline))
            .accessibilityLabel(CompanionEmptyStateCopy.offlineAccessibility)
    }
}

// MARK: - Status cards

/// Agent roster card driven by ``AgentListSkim`` (UX-006).
///
/// Density matches Mac collapsed: shared attention badge (pending elevates to
/// needs-you), one short skim line (no multi-line task junk), measured entropy
/// only when published.
@available(iOS 17.0, *)
struct AgentCard: View {
    let row: AgentListSkim.Row

    private var state: ShannonStatusDot.State {
        if row.isNeedsYou { return .warning }
        if row.isCollapsed { return .warning }
        switch row.attention {
        case .needsYou: return .warning
        case .working: return .active
        case .finished: return .success
        case .idle: return .neutral
        case .unknown: return .error
        }
    }

    private var isWorking: Bool { row.attention == .working && !row.isNeedsYou }

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.xs) {
            HStack(spacing: ShannonSpacing.sm) {
                ShannonStatusDot(state: state)
                    .modifier(PulseIfRunning(isRunning: isWorking))
                Text(row.name)
                    .font(.shannonHeadline)
                    .foregroundStyle(Color.shannonPrimary)
                Spacer()
                Text(row.badge)
                    .font(.shannonCaption)
                    .foregroundStyle(
                        row.isNeedsYou || row.isCollapsed
                            ? Color.shannonWarning
                            : Color.shannonTertiary
                    )
                Text("\(row.turnCount)")
                    .shannonNumeric()
            }

            if let skim = row.skimLine {
                Text(skim)
                    .font(.shannonBody)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
            }

            if let entropy = row.entropyLabel {
                Text(entropy)
                    .font(.shannonMono)
                    .foregroundStyle(row.isCollapsed ? Color.shannonError : Color.shannonTertiary)
            }
        }
        .shannonCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(row.badge)")
        .contextMenu {
            if let skim = row.skimLine {
                Button("Copy last action") {
                    UIPasteboard.general.string = skim
                    Haptics.transition()
                }
            }
        }
    }
}

/// Running status-dot breath (same 1.6s period as Mac / iPad).
/// UX-007: forever-pulse off under Reduce Motion — solid full-opacity dot.
@available(iOS 17.0, *)
private struct PulseIfRunning: ViewModifier {
    var isRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var shouldPulse: Bool {
        MotionChromePolicy.shouldPulseRunningDot(
            isRunning: isRunning,
            reduceMotion: reduceMotion
        )
    }

    func body(content: Content) -> some View {
        content
            .opacity(shouldPulse && pulsing ? 0.45 : 1)
            .animation(shouldPulse ? ShannonMotion.pillPulse : .shannonSnap, value: pulsing)
            .onAppear { syncPulse() }
            .onChange(of: isRunning) { _ in syncPulse() }
            .onChange(of: reduceMotion) { _ in syncPulse() }
    }

    private func syncPulse() {
        pulsing = shouldPulse
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

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.shannonPrimary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(ShannonPressStyle(pressedScale: 0.9))
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

/// Press and hold to dictate; release submits. Double-tap toggles hands-free (UX-045).
@available(iOS 17.0, *)
struct MicButton: View {
    let model: PhoneModel
    @State private var isHolding = false

    var body: some View {
        if model.voice.isAvailable && model.voice.isAuthorized {
            Image(systemName: model.voice.isListening || model.voice.isHandsFree ? "mic.fill" : "mic")
                .foregroundStyle(
                    model.voice.isListening || model.voice.isHandsFree
                        ? Color.shannonAccent
                        : Color.shannonTertiary
                )
                .scaleEffect(isHolding || model.voice.isHandsFree ? 1.15 : 1)
                .animation(.shannonSnap, value: isHolding)
                .animation(.shannonSnap, value: model.voice.isHandsFree)
                .accessibilityLabel(
                    model.voice.isHandsFree ? "Hands-free dictation on — double-tap to finish" : "Dictate"
                )
                .accessibilityHint("Hold to talk, or double-tap for hands-free")
                // UX-045: double-tap enters/exits hands-free (must not depend on long-press alone).
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        model.toggleHandsFreeDictation()
                    }
                )
                .onLongPressGesture(minimumDuration: 0.15) {
                    // Fires on hold complete — unused; press state drives start/stop.
                } onPressingChanged: { pressing in
                    isHolding = pressing
                    if pressing {
                        // Hold while already hands-free keeps listening; no restart.
                        guard !model.voice.isHandsFree else { return }
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

/// Fail-closed empty roster (UX-002): idle vs hub offline share Core copy so
/// phone never looks "all quiet" when CloudKit is down.
/// Status colour legend (UX-010) matches Mac amber=ask / red=collapse.
@available(iOS 17.0, *)
struct EmptyStateView: View {
    let error: String?

    private var copy: CompanionEmptyStateCopy.Content {
        CompanionEmptyStateCopy.content(lastError: error)
    }

    var body: some View {
        VStack(spacing: ShannonSpacing.sm) {
            Text(copy.title)
                .font(.shannonHeadline)
                .foregroundStyle(copy.isOffline ? Color.shannonWarning : Color.shannonSecondary)
            Text(copy.detail)
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonTertiary)
                .multilineTextAlignment(.center)
            Text(StatusLegendCopy.line)
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, ShannonSpacing.xs)
                .accessibilityLabel(StatusLegendCopy.accessibilityLabel)
        }
        .padding(.horizontal, ShannonSpacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(copy.title). \(copy.detail). \(StatusLegendCopy.accessibilityLabel)"
        )
    }
}
