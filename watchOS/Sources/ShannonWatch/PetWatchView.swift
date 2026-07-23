import SwiftUI
import ShannonCore
import ShannonTheme

// MARK: - PetWatchView

/// Full-screen pet view for Apple Watch.
/// Always-on: renders silhouette at 15% opacity via `isLuminanceReduced`.
/// Crown: each full rotation = +1 XP + spin animation.
/// Double Tap (watchOS 11+): random trick animation + 5 XP.
/// Long press: action menu (memory | stats).
@available(watchOS 10.0, *)
struct PetWatchView: View {
    let model: WatchModel
    @Environment(PetStore.self) private var store
    @Environment(PetInteractionEngine.self) private var engine

    @State private var crownValue: Double = 0
    @State private var lastCrownInt: Int  = 0
    @State private var rotationDeg: Double = 0
    @State private var showMenu = false
    @State private var bounceID = UUID()
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        ZStack {
            Color.shannonBackground.ignoresSafeArea()
            petContent
        }
        .focusable()
        .digitalCrownRotation($crownValue,
                               from: -Double.infinity,
                               through: Double.infinity,
                               sensitivity: .low,
                               isContinuous: true,
                               isHapticFeedbackEnabled: true)
        .onChange(of: crownValue) { _, newVal in
            rotationDeg = newVal * 360
            let intVal = Int(newVal)
            if intVal != lastCrownInt {
                lastCrownInt = intVal
                engine.handle(.crownSpin)
            }
        }
        .onTapGesture(count: 2) {
            engine.handle(.doubleTapWatch)
            bounceID = UUID()
        }
        .onLongPressGesture { showMenu = true }
        .shannonPrimaryHandGesture()
        .confirmationDialog("Pet", isPresented: $showMenu) {
            Button("Show Memory")  { }
            Button("Pet Stats")    { }
            Button("Cancel", role: .cancel) {}
        }
        .containerBackground(Color.shannonBackground.gradient, for: .navigation)
    }

    // MARK: Content

    @ViewBuilder
    private var petContent: some View {
        VStack(spacing: ShannonSpacing.xs) {
            PetAvatarCanvasWatch(
                params: PetAvatarDescriptor.params(for: store.pet.avatarSeed),
                mood:   dimmed ? .sleeping : store.pet.mood,
                size:   dimmed ? 70 : 100
            )
            .rotationEffect(.degrees(rotationDeg))
            .opacity(dimmed ? 0.15 : 1)
            .id(bounceID)
            .transition(.scale(scale: 1.3).combined(with: .opacity))

            if !dimmed {
                Text(store.pet.name)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.shannonPrimary)
                Text(store.pet.mood.label)
                    .font(.caption2)
                    .foregroundStyle(Color.shannonSecondary)
                ProgressView(value: store.pet.xpFraction)
                    .tint(.shannonAccent)
                    .frame(width: 80)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: dimmed)
    }
}

// MARK: - PetWatchStatsView

@available(watchOS 10.0, *)
struct PetWatchStatsView: View {
    @Environment(PetStore.self) private var store

    var body: some View {
        List {
            LabeledContent("Level",   value: "\(store.pet.level)")
            LabeledContent("XP",      value: "\(store.pet.xp)")
            LabeledContent("Mood",    value: store.pet.mood.label)
            LabeledContent("Species", value: store.pet.species.rawValue)
        }
        .navigationTitle(store.pet.name)
        .containerBackground(Color.shannonBackground.gradient, for: .navigation)
    }
}
