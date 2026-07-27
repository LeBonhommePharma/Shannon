import WidgetKit
import SwiftUI
import ShannonCore
import ShannonTheme

// MARK: - PetWidget
//
// Added to ShannonWidgetBundle (in ShannonWidget.swift) so there is only one
// @main entry point. Supports systemSmall, systemMedium, lock screen, and
// StandBy via accessoryCircular / accessoryRectangular families.
//
// PET E7 (honesty): the phone app does **not** ship a PetStore mount or an
// App Group `pet.widget.entry` writer yet (`ShannonPhoneApp` roots only
// `HomeView`; `PetHomeView` is scaffold-only). Until a writer reloads
// `ShannonPetWidget`, missing cache is an explicit non-live scaffold — never
// a fake live mood for "Shan".

struct PetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShannonPetWidget",
                            provider: PetWidgetProvider()) { entry in
            PetWidgetView(entry: entry)
                .containerBackground(Color.shannonBackground, for: .widget)
        }
        .configurationDisplayName("Shannon Pet")
        .description(
            "Pet mood when the phone writes App Group data. Scaffold until live — not a live Mac hub pet yet."
        )
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
    /// True only when App Group `pet.widget.entry` decoded successfully (PET E7).
    let isLive: Bool
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

    /// Explicit non-live placeholder — not a fabricated active pet mood (PET E7).
    private static var scaffold: PetWidgetEntry {
        PetWidgetEntry(
            date: Date(),
            petName: "Pet",
            mood: .sleeping,
            level: 0,
            xpFraction: 0,
            avatarSeed: 0,
            lastMemory: "Not on this phone yet",
            isLive: false
        )
    }

    func placeholder(in context: Context) -> PetWidgetEntry { Self.scaffold }

    func getSnapshot(in context: Context,
                     completion: @escaping (PetWidgetEntry) -> Void) {
        completion(loadEntry() ?? Self.scaffold)
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<PetWidgetEntry>) -> Void) {
        let entry = loadEntry() ?? Self.scaffold
        // Sparse timeline when scaffold-only — no live writer to chase (PET E7).
        let interval: TimeInterval = entry.isLive ? 900 : 3_600
        let policy = TimelineReloadPolicy.after(Date().addingTimeInterval(interval))
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
            avatarSeed: decoded.avatarSeed, lastMemory: decoded.lastMemory,
            isLive: true
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
                if entry.isLive {
                    PetAvatarCanvas(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                    mood: entry.mood, size: 36)
                } else {
                    Image(systemName: "pawprint")
                        .font(.body)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
            .accessibilityLabel(entry.isLive
                ? "\(entry.petName), \(entry.mood.label)"
                : "Pet scaffold — not live on this phone")

        case .accessoryRectangular:
            HStack(spacing: ShannonSpacing.sm) {
                if entry.isLive {
                    PetAvatarCanvas(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                    mood: entry.mood, size: 28)
                } else {
                    Image(systemName: "pawprint")
                        .font(.caption)
                        .foregroundStyle(Color.shannonTertiary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.petName).font(.caption2.weight(.semibold))
                    Text(entry.isLive ? entry.mood.label : "Scaffold")
                        .font(.caption2)
                    Text(entry.lastMemory).font(.caption2).lineLimit(1)
                }
            }
            .accessibilityLabel(entry.isLive
                ? "\(entry.petName), \(entry.mood.label)"
                : "Pet scaffold — phone writer not shipped")

        case .systemSmall:
            VStack(spacing: ShannonSpacing.xs) {
                if entry.isLive {
                    PetAvatarCanvas(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                    mood: entry.mood, size: 56)
                    Text(entry.petName).font(.caption.weight(.semibold))
                        .foregroundStyle(Color.shannonPrimary)
                    HStack(spacing: 3) {
                        Image(systemName: entry.mood.symbol).foregroundStyle(moodColor)
                        Text(entry.mood.label).font(.caption2).foregroundStyle(moodColor)
                    }
                } else {
                    Image(systemName: "pawprint")
                        .font(.title2)
                        .foregroundStyle(Color.shannonTertiary)
                    Text("Pet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.shannonSecondary)
                    Text("Scaffold")
                        .font(.caption2)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
            .accessibilityLabel(entry.isLive
                ? "\(entry.petName), feeling \(entry.mood.label)"
                : "Pet scaffold — not live on this phone")

        default: // systemMedium + StandBy
            HStack(spacing: ShannonSpacing.md) {
                if entry.isLive {
                    PetAvatarCanvas(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                    mood: entry.mood, size: 72)
                } else {
                    Image(systemName: "pawprint")
                        .font(.largeTitle)
                        .foregroundStyle(Color.shannonTertiary)
                        .frame(width: 72, height: 72)
                }
                VStack(alignment: .leading, spacing: ShannonSpacing.xs) {
                    Text(entry.isLive ? entry.petName : "Shannon Pet")
                        .font(.headline)
                        .foregroundStyle(Color.shannonPrimary)
                    if entry.isLive {
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
                    } else {
                        Text("Not live on this phone")
                            .font(.subheadline)
                            .foregroundStyle(Color.shannonSecondary)
                        Text(entry.lastMemory)
                            .font(.caption)
                            .foregroundStyle(Color.shannonTertiary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(ShannonSpacing.sm)
            .accessibilityLabel(entry.isLive
                ? "\(entry.petName), feeling \(entry.mood.label), level \(entry.level)"
                : "Pet scaffold — phone writer not shipped")
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
