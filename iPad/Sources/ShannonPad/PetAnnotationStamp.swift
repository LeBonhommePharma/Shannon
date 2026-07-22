import SwiftUI
import ShannonCore
import ShannonTheme

// MARK: - PetAnnotationStamp

/// A mood-stamped pet medallion placed on agent cards as an annotation.
/// Deterministic from `avatarSeed ^ moodOrdinal` — no image assets.
@available(iOS 17.0, *)
public struct PetAnnotationStamp: View {
    public let pet: ShannonPet
    public let size: CGFloat

    public init(pet: ShannonPet, size: CGFloat = 40) {
        self.pet = pet; self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(stampColor.opacity(0.15))
            Circle()
                .strokeBorder(stampColor, lineWidth: 1.5)
            PetAvatarCanvas(
                params: PetAvatarDescriptor.params(for: stampSeed),
                mood:   pet.mood,
                size:   size * 0.68
            )
        }
        .frame(width: size, height: size)
    }

    /// Blend seed with mood ordinal so each mood produces a distinct stamp.
    private var stampSeed: UInt64 {
        pet.avatarSeed ^ UInt64(PetMood.allCases.firstIndex(of: pet.mood) ?? 0)
    }

    private var stampColor: Color {
        switch pet.mood.colorRole {
        case .blue:   return .shannonAccent
        case .teal:   return Color(hue: 0.5, saturation: 0.7, brightness: 0.7)
        case .amber:  return .shannonWarning
        case .red:    return .shannonError
        case .gray:   return .shannonNeutral
        case .purple: return Color(hue: 0.78, saturation: 0.6, brightness: 0.75)
        }
    }
}

// MARK: - "Get pet's opinion" context menu modifier

@available(iOS 17.0, *)
public extension View {
    /// Adds a "Get pet's opinion" action to any agent card's context menu.
    /// Stamps the card with a mood-appropriate pet seal and writes a memory
    /// entry: "I looked at [agentName] and felt [mood]".
    func petOpinionContextMenu(
        pet: ShannonPet,
        agentName: String,
        engine: PetInteractionEngine
    ) -> some View {
        contextMenu {
            Button {
                engine.handle(.tap)
                Task {
                    await PetMemoryStore(petID: pet.id).append(
                        entry: PetMemoryEntry(
                            kind: .observation,
                            text: "I looked at \(agentName) and felt \(pet.mood.label)"
                        )
                    )
                }
            } label: {
                Label("Get pet's opinion", systemImage: "pawprint.fill")
            }
        }
    }
}

// MARK: - Stage Manager floating overlay

/// A 16-pt floating pet badge that persists above all Stage Manager windows.
/// Present via `PetFloatingOverlay.show(pet:)` from the app delegate /
/// scene delegate when the main scene activates.
@available(iOS 17.0, *)
public struct PetFloatingBadge: View {
    @Environment(PetStore.self) private var store
    @State private var bounceScale: CGFloat = 1

    public var body: some View {
        PetAvatarCanvas(
            params: PetAvatarDescriptor.params(for: store.pet.avatarSeed),
            mood:   store.pet.mood,
            size:   16
        )
        .scaleEffect(bounceScale)
        .onReceive(NotificationCenter.default.publisher(for: .petLevelUp)) { _ in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.3)) { bounceScale = 1.6 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring()) { bounceScale = 1 }
            }
        }
        .allowsHitTesting(false) // overlay — don't intercept touches
    }
}
