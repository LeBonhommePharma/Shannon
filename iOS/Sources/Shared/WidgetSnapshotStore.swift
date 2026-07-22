import Foundation
import WidgetKit
import ShannonCore

/// App Group bridge between the app and its widget extension.
enum WidgetSnapshotStore {
    /// Must match the App Group on both the app and the widget target.
    static let appGroupID = "group.com.lebonhommepharma.shannon"
    private static let filename = "widget-snapshot.json"

    static var placeholder: ShannonSnapshot {
        ShannonSnapshot(
            agents: [
                AgentState(id: "a", name: "FlexAID∆S", activity: .running,
                           turnCount: 12, entropyBits: 0.61),
            ],
            docking: [
                DockingProgress(id: "astex", benchmarkName: "Astex Diverse",
                                targetsComplete: 34, targetsTotal: 85, bestRMSD: 1.42),
            ]
        )
    }

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(filename)
    }

    static func save(_ snapshot: ShannonSnapshot) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Artwork is never rendered by the widget and would bloat the file.
        var trimmed = snapshot
        trimmed.nowPlaying?.artworkJPEG = nil
        guard let data = try? encoder.encode(trimmed) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func load() -> ShannonSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ShannonSnapshot.self, from: data)
    }
}
