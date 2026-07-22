import SwiftUI
import ShannonCore
import ShannonTheme

// MARK: - Pet Dynamic Island Views
//
// Three layout variants consumed by the ActivityKit Live Activity:
//   • PetIslandLeading   — compact leading slot (16 pt avatar + mood ring)
//   • PetIslandExpanded  — expanded banner (avatar left, last memory right)
//   • PetIslandMinimal   — minimal presentation (mood-colour dot)

@available(iOS 17.0, *)
public struct PetIslandLeading: View {
    public let pet: ShannonPet
    public init(pet: ShannonPet) { self.pet = pet }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(moodColor.opacity(0.85), lineWidth: 1.5)
                .frame(width: 22, height: 22)
            PetAvatarCanvas(
                params: PetAvatarDescriptor.params(for: pet.avatarSeed),
                mood:   pet.mood,
                size:   16
            )
        }
    }

    var moodColor: Color { PetDynamicIslandColors.color(for: pet.mood.colorRole) }
}

@available(iOS 17.0, *)
public struct PetIslandMinimal: View {
    public let pet: ShannonPet
    public init(pet: ShannonPet) { self.pet = pet }

    public var body: some View {
        Circle()
            .fill(PetDynamicIslandColors.color(for: pet.mood.colorRole))
            .frame(width: 10, height: 10)
    }
}

@available(iOS 17.0, *)
public struct PetIslandExpanded: View {
    public let pet: ShannonPet
    public let lastMemory: String
    public init(pet: ShannonPet, lastMemory: String) {
        self.pet = pet; self.lastMemory = lastMemory
    }

    public var body: some View {
        HStack(spacing: ShannonSpacing.md) {
            PetAvatarCanvas(
                params: PetAvatarDescriptor.params(for: pet.avatarSeed),
                mood:   pet.mood,
                size:   48
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(pet.name)
                    .font(.headline)
                    .foregroundStyle(Color.shannonPrimary)
                Text(lastMemory.isEmpty ? "feeling \(pet.mood.label)" : lastMemory)
                    .font(.caption)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(ShannonSpacing.sm)
    }
}

// MARK: - Colour helper

@available(iOS 17.0, *)
enum PetDynamicIslandColors {
    static func color(for role: MoodColorRole) -> Color {
        switch role {
        case .blue:   return .shannonAccent
        case .teal:   return Color(hue: 0.5, saturation: 0.7, brightness: 0.8)
        case .amber:  return .shannonWarning
        case .red:    return .shannonError
        case .gray:   return .shannonNeutral
        case .purple: return Color(hue: 0.78, saturation: 0.6, brightness: 0.8)
        }
    }
}
