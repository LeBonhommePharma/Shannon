import WidgetKit
import SwiftUI
import ShannonCore
import ShannonTheme

// MARK: - PetWidget
//
// Added to ShannonWidgetBundle (in ShannonWidget.swift) so there is only one
// @main entry point. Supports systemSmall, systemMedium, lock screen, and
// StandBy via accessoryCircular / accessoryRectangular families.

struct PetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShannonPetWidget",
                            provider: PetWidgetProvider()) { entry in
            PetWidgetView(entry: entry)
                .containerBackground(Color.shannonBackground, for: .widget)
        }
        .configurationDisplayName("Shannon Pet")
        .description("Your pet's mood, level, and latest memory entry.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}

// MARK: - Entry

struct PetWidgetEntry: TimelineEntry {
    let date: Date
    let petName: String
    let mood: PetMood
    let level: Int
    let xpFraction: Double
    let avatarSeed: UInt64
    let lastMemory: String
}

// MARK: - Shared raw Codable used in App Group cache

private struct PetWidgetRaw: Codable {
    var name: String
    var mood: String
    var level: Int
    var xpFraction: Double
    var avatarSeed: UInt64
    var lastMemory: String
}

// MARK: - Provider

struct PetWidgetProvider: TimelineProvider {

    private static var placeholder: PetWidgetEntry {
        PetWidgetEntry(date: Date(), petName: "Shan", mood: .curious,
                       level: 3, xpFraction: 0.4, avatarSeed: 42,
                       lastMemory: "just woke up")
    }

    func placeholder(in context: Context) -> PetWidgetEntry { Self.placeholder }

    func getSnapshot(in context: Context,
                     completion: @escaping (PetWidgetEntry) -> Void) {
        completion(loadEntry() ?? Self.placeholder)
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<PetWidgetEntry>) -> Void) {
        let entry  = loadEntry() ?? Self.placeholder
        let policy = TimelineReloadPolicy.after(Date().addingTimeInterval(900))
        completion(Timeline(entries: [entry], policy: policy))
    }

    private func loadEntry() -> PetWidgetEntry? {
        guard let raw = UserDefaults(suiteName: "group.com.lebonhommepharma.shannon")?
                .data(forKey: "pet.widget.entry"),
              let decoded = try? JSONDecoder().decode(PetWidgetRaw.self, from: raw)
        else { return nil }
        return PetWidgetEntry(
            date: Date(), petName: decoded.name,
            mood: PetMood(rawValue: decoded.mood) ?? .calm,
            level: decoded.level, xpFraction: decoded.xpFraction,
            avatarSeed: decoded.avatarSeed, lastMemory: decoded.lastMemory
        )
    }
}

// MARK: - View

struct PetWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PetWidgetEntry

    var body: some View {
        switch family {

        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                PetAvatarCanvas(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                mood: entry.mood, size: 36)
            }

        case .accessoryRectangular:
            HStack(spacing: ShannonSpacing.sm) {
                PetAvatarCanvas(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                mood: entry.mood, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.petName).font(.caption2.weight(.semibold))
                    Text(entry.mood.label).font(.caption2)
                    Text(entry.lastMemory).font(.caption2).lineLimit(1)
                }
            }

        case .systemSmall:
            VStack(spacing: ShannonSpacing.xs) {
                PetAvatarCanvas(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                mood: entry.mood, size: 56)
                Text(entry.petName).font(.caption.weight(.semibold))
                    .foregroundStyle(Color.shannonPrimary)
                HStack(spacing: 3) {
                    Image(systemName: entry.mood.symbol).foregroundStyle(moodColor)
                    Text(entry.mood.label).font(.caption2).foregroundStyle(moodColor)
                }
            }

        default: // systemMedium + StandBy
            HStack(spacing: ShannonSpacing.md) {
                PetAvatarCanvas(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                mood: entry.mood, size: 72)
                VStack(alignment: .leading, spacing: ShannonSpacing.xs) {
                    Text(entry.petName)
                        .font(.headline)
                        .foregroundStyle(Color.shannonPrimary)
                    HStack(spacing: 4) {
                        Image(systemName: entry.mood.symbol).foregroundStyle(moodColor)
                        Text(entry.mood.label).font(.subheadline).foregroundStyle(moodColor)
                    }
                    if !entry.lastMemory.isEmpty {
                        Text(entry.lastMemory)
                            .font(.caption)
                            .foregroundStyle(Color.shannonSecondary)
                            .lineLimit(2)
                    }
                    ProgressView(value: entry.xpFraction).tint(.shannonAccent)
                    Text("Level \(entry.level)")
                        .font(.caption2)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
            .padding(ShannonSpacing.sm)
        }
    }

    private var moodColor: Color {
        switch entry.mood.colorRole {
        case .blue:   return .shannonAccent
        case .teal:   return Color(hue: 0.5, saturation: 0.7, brightness: 0.7)
        case .amber:  return .shannonWarning
        case .red:    return .shannonError
        case .gray:   return .shannonNeutral
        case .purple: return Color(hue: 0.78, saturation: 0.6, brightness: 0.75)
        }
    }
}
