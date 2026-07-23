import SwiftUI
import ShannonCore
import ShannonTheme

/// One screen at a time; the Digital Crown moves between them. No tab bar, no
/// nested navigation — on a watch, the crown is the navigation.
@available(watchOS 10.0, *)
struct WatchRootView: View {
    @Bindable var model: WatchModel

    var body: some View {
        Group {
            switch model.screen {
            case .face:
                ShannonFaceView(model: model)
            case .agents:
                AgentListView(model: model)
            case .nowPlaying:
                WatchNowPlayingView(model: model)
            case .notifications:
                NotificationListView(model: model)
            }
        }
        .animation(.shannonEase, value: model.screen)
        .focusable()
        .modifier(CrownRouter(model: model))
        // Double Tap (Series 9 and later): the primary action of whichever
        // screen is showing.
        .shannonPrimaryHandGesture()
        .onTapGesture(count: 2) { model.primaryAction() }
    }
}

/// The Digital Crown means different things on different screens: while a
/// gate prompt is showing it arms approve/deny; otherwise it navigates.
/// One modifier so the two bindings can never both be attached.
@available(watchOS 10.0, *)
struct CrownRouter: ViewModifier {
    @Bindable var model: WatchModel

    func body(content: Content) -> some View {
        if model.isAwaitingConfirmation, model.screen == .face {
            content
                .digitalCrownRotation(
                    $model.gateCrown,
                    from: -1, through: 1, by: 0.25,
                    sensitivity: .low,
                    isContinuous: false,
                    isHapticFeedbackEnabled: false
                )
                .onChange(of: model.gateCrown) { _, value in
                    model.gateCrownChanged(to: value)
                }
        } else {
            content
                .digitalCrownRotation(
                    $model.crownPosition,
                    from: 0,
                    through: Double(WatchScreen.allCases.count - 1),
                    by: 1,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )
                .onChange(of: model.crownPosition) { _, value in
                    model.crownChanged(to: value)
                }
        }
    }
}

/// The gate prompt. Replaces the face content while pending — no sheet, no
/// navigation push; when the answer is in, the face simply comes back.
///
/// Turn the crown up to arm Approve, down to arm Deny, then tap the armed
/// button (or Double Tap) to submit. Tapping either button directly also
/// works — the crown is a confirmation aid, not a gatekeeper.
@available(watchOS 10.0, *)
struct GateApprovalView: View {
    let model: WatchModel
    let pending: PendingConfirmation

    private var pendingCount: Int { model.snapshot.confirmations.count }

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            header

            Text(pending.question)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.shannonPrimary)
                .lineLimit(3)

            if !pending.detail.isEmpty {
                Text(pending.detail)
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(2)
            }

            buttons

            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: ShannonSpacing.xs) {
            Text(pendingCount > 1 ? "Gate 1 of \(pendingCount)" : "Gate")
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonAccent)
            Spacer(minLength: 0)
            if !model.isPhoneReachable {
                Label("iPhone away", systemImage: "iphone.slash")
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonTertiary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: ShannonSpacing.sm) {
            gateButton("Deny", system: "xmark", armed: model.gateChoice == .deny,
                       tint: .shannonNeutral) {
                model.answer(.denied, source: .tap)
            }
            gateButton("Approve", system: "checkmark", armed: model.gateChoice == .approve,
                       tint: .shannonAccent) {
                model.answer(.confirmed, source: .tap)
            }
            // Double Tap submits the crown-armed choice, never a blind yes.
            .shannonPrimaryHandGesture()
        }
        .buttonStyle(.bordered)
        // Unreachable is visible, not disabling: the answer queues and the
        // system delivers it when the phone is back. Greyed, never stuck.
        .opacity(model.isPhoneReachable ? 1 : 0.5)
    }

    private func gateButton(
        _ title: String, system: String, armed: Bool, tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
        }
        .tint(tint)
        .overlay(
            RoundedRectangle(cornerRadius: ShannonLayout.WatchCard.radius)
                .strokeBorder(armed ? tint : .clear, lineWidth: 2)
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.delivery {
        case .idle:
            Text(model.gateChoice == .none
                 ? "Turn crown: up approves, down denies"
                 : "Tap or double-tap to send")
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonTertiary)
        case .sending:
            Text("Sending…")
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonSecondary)
        case .sent:
            Text("Sent ✓")
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonAccent)
        case .queued:
            Text("Queued — delivers when iPhone is back")
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonSecondary)
        }
    }
}

@available(watchOS 10.0, *)
struct AgentListView: View {
    let model: WatchModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ShannonSpacing.sm) {
                ForEach(model.snapshot.agents.rankedForDisplay()) { agent in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(agent.activity.glyph) \(agent.name)")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.shannonPrimary)
                            .lineLimit(1)
                        // Two lines maximum per card: anything longer is
                        // unreadable at a glance on a wrist.
                        Text(agent.taskTitle.isEmpty ? "\(agent.turnCount) turns"
                                                     : agent.taskTitle)
                            .font(.shannonCaption)
                            .foregroundStyle(Color.shannonSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ShannonLayout.WatchCard.padding)
                    .background(Color.shannonSurface,
                                in: RoundedRectangle(cornerRadius: ShannonLayout.WatchCard.radius))
                    .contextMenu {
                        Button("Back to face") { model.goHome() }
                    }
                }

                if model.snapshot.agents.isEmpty {
                    Text("No agents")
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
        }
        .containerBackground(Color.shannonBackground.gradient, for: .navigation)
    }
}

@available(watchOS 10.0, *)
struct WatchNowPlayingView: View {
    let model: WatchModel

    var body: some View {
        VStack(spacing: ShannonSpacing.sm) {
            if let media = model.snapshot.nowPlaying, !media.isIdle {
                VStack(spacing: 2) {
                    Text(media.title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.shannonPrimary)
                        .lineLimit(2)
                    Text(media.artist)
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: ShannonSpacing.md) {
                    Button { model.send(.previousTrack) } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button { model.send(.togglePlayPause) } label: {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .shannonPrimaryHandGesture()
                    Button { model.send(.nextTrack) } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.shannonPrimary)
            } else {
                Text("Nothing playing")
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonTertiary)
            }
        }
        .containerBackground(Color.shannonBackground.gradient, for: .navigation)
    }
}

@available(watchOS 10.0, *)
struct NotificationListView: View {
    let model: WatchModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ShannonSpacing.sm) {
                ForEach(model.snapshot.notifications) { note in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note.sender)
                            .font(.shannonCaption)
                            .foregroundStyle(Color.shannonAccent)
                        Text(note.title.isEmpty ? note.body : note.title)
                            .font(.shannonCaption)
                            .foregroundStyle(Color.shannonPrimary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ShannonLayout.WatchCard.padding)
                    .background(Color.shannonSurface,
                                in: RoundedRectangle(cornerRadius: ShannonLayout.WatchCard.radius))
                }

                if model.snapshot.notifications.isEmpty {
                    Text("No notifications")
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
        }
        .containerBackground(Color.shannonBackground.gradient, for: .navigation)
    }
}

/// Double Tap binding.
///
/// `handGestureShortcut` landed in watchOS 11, while Shannon's floor is
/// watchOS 10 — so it is applied only where available. On watchOS 10 the
/// double-tap-on-screen gesture in `WatchRootView` remains the way in, and
/// every action reachable by Double Tap also has an ordinary button.
@available(watchOS 10.0, *)
extension View {
    @ViewBuilder
    func shannonPrimaryHandGesture() -> some View {
        if #available(watchOS 11.0, *) {
            self.handGestureShortcut(.primaryAction)
        } else {
            self
        }
    }
}
