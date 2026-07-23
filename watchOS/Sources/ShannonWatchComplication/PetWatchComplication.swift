import WidgetKit
import SwiftUI
import ShannonCore
import ShannonTheme

// MARK: - PetWatchComplication
//
// Added to ShannonComplicationBundle (in ShannonComplication.swift).
// Data is read from the App Group UserDefaults populated by PetWatchSyncRelay.

@available(watchOS 10.0, *)
struct PetWatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShannonPetComplication",
                            provider: PetComplicationProvider()) { entry in
            PetComplicationView(entry: entry)
                .containerBackground(Color.shannonBackground, for: .widget)
        }
        .configurationDisplayName("Shannon Pet")
        .description("Pet mood and level on your watch face.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
    }
}

// MARK: - Entry

struct PetComplicationEntry: TimelineEntry {
    let date: Date
    let mood: PetMood
    let level: Int
    let petName: String
    let avatarSeed: UInt64
    let lastMemory: String
}

// MARK: - Provider

@available(watchOS 10.0, *)
struct PetComplicationProvider: TimelineProvider {

    private static var placeholder: PetComplicationEntry {
        PetComplicationEntry(date: Date(), mood: .curious, level: 3,
                             petName: "Shan", avatarSeed: 42, lastMemory: "")
    }

    func placeholder(in context: Context) -> PetComplicationEntry { Self.placeholder }

    func getSnapshot(in context: Context,
                     completion: @escaping (PetComplicationEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<PetComplicationEntry>) -> Void) {
        let e = loadEntry()
        completion(Timeline(entries: [e],
                            policy: .after(Date().addingTimeInterval(900))))
    }

    private func loadEntry() -> PetComplicationEntry {
        let d = UserDefaults(suiteName: "group.com.lebonhommepharma.shannon")
        return PetComplicationEntry(
            date:       Date(),
            mood:       PetMood(rawValue: d?.string(forKey: "pet.mood") ?? "") ?? .calm,
            level:      d?.integer(forKey: "pet.level") ?? 1,
            petName:    d?.string(forKey:  "pet.name")  ?? "Shan",
            avatarSeed: UInt64(d?.string(forKey: "pet.avatarSeed") ?? "0") ?? 0,
            lastMemory: d?.string(forKey: "pet.lastMemory") ?? ""
        )
    }
}

// MARK: - View

@available(watchOS 10.0, *)
struct PetComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PetComplicationEntry

    var body: some View {
        switch family {
        case .accessoryCorner:
            PetAvatarCanvasWatch(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                 mood: entry.mood, size: 20)
                .widgetLabel("Lv \(entry.level) · \(entry.mood.label)")
        case .accessoryRectangular:
            HStack(spacing: 4) {
                PetAvatarCanvasWatch(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                     mood: entry.mood, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.petName).font(.caption2.weight(.semibold)).widgetAccentable()
                    Text(entry.mood.label).font(.caption2)
                    if !entry.lastMemory.isEmpty {
                        Text(entry.lastMemory).font(.caption2).lineLimit(1)
                    }
                }
            }
        default: // .accessoryCircular
            ZStack {
                AccessoryWidgetBackground()
                PetAvatarCanvasWatch(params: PetAvatarDescriptor.params(for: entry.avatarSeed),
                                     mood: entry.mood, size: 32)
            }
        }
    }
}
