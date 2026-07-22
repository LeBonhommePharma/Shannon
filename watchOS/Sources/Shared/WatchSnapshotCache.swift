import Foundation
import ShannonCore

/// Last snapshot on disk, so the watch app and its complication survive a
/// relaunch with the phone out of range.
///
/// Backed by the App Group container rather than the app's own sandbox: the
/// complication runs in a separate process and cannot read the app's
/// Application Support directory.
enum WatchSnapshotCache {
    /// Must match the App Group on both watch targets.
    static let appGroupID = "group.com.lebonhommepharma.shannon"
    private static let filename = "shannon-snapshot.json"

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(filename)
    }

    static func save(_ snapshot: ShannonSnapshot) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot.trimmedForWatch()) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> ShannonSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ShannonSnapshot.self, from: data)
    }
}
