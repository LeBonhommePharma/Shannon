import SwiftUI
import ShannonCore
import ShannonTheme

// MARK: - PetRailView

/// Pet lives at the top of the right-column notification rail on iPad.
/// 96 pt avatar · mood idle animation · today's diary · XP bar with level.
/// Pencil hover triggers gaze offset (via `updatePencilGaze(to:in:)`).
@available(iOS 17.0, *)
public struct PetRailView: View {
    @Environment(PetStore.self) private var store
    @Environment(PetInteractionEngine.self) private var engine

    @State private var entries: [PetMemoryEntry] = []
    @State private var pencilOffset: CGSize = .zero
    @State private var idleRotation: Double = 0

    public var body: some View {
        VStack(spacing: ShannonSpacing.md) {
            petSection
            Divider().background(Color.shannonNeutral.opacity(0.3))
            diarySection
            Divider().background(Color.shannonNeutral.opacity(0.3))
            xpSection
            Spacer(minLength: 0)
        }
        .padding(ShannonSpacing.md)
        .task { await loadEntries() }
        .onAppear { startIdleAnimation() }
    }

    // MARK: Pet section

    private var petSection: some View {
        VStack(spacing: ShannonSpacing.sm) {
            PetAvatarCanvas(
                params: PetAvatarDescriptor.params(for: store.pet.avatarSeed),
                mood:   store.pet.mood,
                size:   96
            )
            .offset(pencilOffset)
            .rotationEffect(.degrees(idleRotation))
            .animation(.easeInOut(duration: 0.2), value: pencilOffset)
            .onTapGesture { engine.handle(.tap); PadHaptics.tap() }
            .accessibilityLabel("\(store.pet.name), feeling \(store.pet.mood.label)")

            Text(store.pet.name)
                .font(.headline)
                .foregroundStyle(Color.shannonPrimary)

            HStack(spacing: ShannonSpacing.xs) {
                Image(systemName: store.pet.mood.symbol)
                Text(store.pet.mood.label)
            }
            .font(.caption)
            .foregroundStyle(moodColor)
            .animation(.easeInOut(duration: 0.3), value: store.pet.mood)
        }
    }

    // MARK: Diary section

    private var diarySection: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.xs) {
            Text("Today's Memory")
                .font(.caption)
                .foregroundStyle(Color.shannonTertiary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: ShannonSpacing.xs) {
                    if entries.isEmpty {
                        Text("No entries yet — interact with your pet!")
                            .font(.caption)
                            .foregroundStyle(Color.shannonTertiary)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.date.formatted(.dateTime.hour().minute()))
                                .font(.caption2)
                                .foregroundStyle(Color.shannonTertiary)
                            Text(entry.text)
                                .font(.caption)
                                .foregroundStyle(Color.shannonSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(ShannonSpacing.xs)
                        .background(Color.shannonSurface,
                                    in: RoundedRectangle(cornerRadius: ShannonRadius.sm))
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    // MARK: XP section

    private var xpSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Level \(store.pet.level)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.shannonSecondary)
                Spacer()
                Text("\(store.pet.xpToNextLevel) XP to go")
                    .font(.caption2)
                    .foregroundStyle(Color.shannonTertiary)
            }
            ProgressView(value: store.pet.xpFraction)
                .tint(.shannonAccent)
        }
    }

    // MARK: Helpers

    private var moodColor: Color {
        switch store.pet.mood.colorRole {
        case .blue:   return .shannonAccent
        case .teal:   return Color(hue: 0.5, saturation: 0.7, brightness: 0.7)
        case .amber:  return .shannonWarning
        case .red:    return .shannonError
        case .gray:   return .shannonNeutral
        case .purple: return Color(hue: 0.78, saturation: 0.6, brightness: 0.75)
        }
    }

    /// Called by `PetPencilTracker` to shift the avatar's gaze toward the Pencil.
    public func updatePencilGaze(to point: CGPoint, in bounds: CGRect) {
        let dx = min(max((point.x - bounds.midX) / bounds.width,  -0.5), 0.5) * 20
        let dy = min(max((point.y - bounds.midY) / bounds.height, -0.5), 0.5) * 20
        pencilOffset = CGSize(width: dx, height: dy)
    }

    /// Reset the gaze when the Pencil leaves proximity.
    public func resetPencilGaze() {
        withAnimation(.easeOut(duration: 0.4)) { pencilOffset = .zero }
    }

    private func loadEntries() async {
        entries = await PetMemoryStore(petID: store.pet.id).recentEntries(limit: 10)
    }

    private func startIdleAnimation() {
        // Gentle idle: a subtle ±2° wobble on a 4-second loop.
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            idleRotation = 2
        }
    }
}
