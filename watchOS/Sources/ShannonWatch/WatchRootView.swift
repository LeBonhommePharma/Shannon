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
        // Double Tap (Series 9 and later): the primary action of whichever
        // screen is showing.
        .shannonPrimaryHandGesture()
        .onTapGesture(count: 2) { model.primaryAction() }
    }
}

/// Confirm / deny buttons, shown on the face only while a question is pending.
@available(watchOS 10.0, *)
struct ConfirmationControls: View {
    let model: WatchModel

    var body: some View {
        HStack(spacing: ShannonSpacing.sm) {
            Button {
                model.answer(.confirmed, source: .tap)
            } label: {
                Label("Confirm", systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity)
            }
            .tint(.shannonAccent)
            // Double Tap maps here: the affirmative action, never the
            // destructive one.
            .shannonPrimaryHandGesture()

            Button {
                model.answer(.denied, source: .tap)
            } label: {
                Label("Deny", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity)
            }
            .tint(.shannonNeutral)
        }
        .buttonStyle(.bordered)
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
