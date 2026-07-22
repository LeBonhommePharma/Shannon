import Foundation

/// On-disk snapshot cache, written with file protection so the cached agent
/// task titles and notification previews are encrypted at rest.
///
/// Replaces the per-app cache helpers the widget, complication and watch app
/// each had, so the protection level is set in exactly one place.
///
/// Protection level is `.completeUnlessOpen` rather than `.complete`: widgets
/// and complications are rendered by the system while the device is locked,
/// and `.complete` makes the file unreadable in precisely that window, which
/// would leave LP with a blank complication whenever his watch was locked.
/// The file is still encrypted at rest under the device passcode either way.
public struct SnapshotCache: Sendable {
    public enum Protection: Sendable {
        /// Readable while locked once the device has been unlocked since boot.
        /// Correct for anything a widget or complication renders.
        case completeUnlessOpen
        /// Unreadable whenever the device is locked. Correct for anything only
        /// the foreground app touches.
        case complete
    }

    public let fileURL: URL?
    public let protection: Protection

    /// App Group container shared by the app and its extensions. Widgets and
    /// complications are separate processes and cannot read the host app's
    /// own sandbox, so the cache has to live here.
    public static let appGroupID = "group.com.lebonhommepharma.shannon"

    public init(
        filename: String,
        appGroupID: String = SnapshotCache.appGroupID,
        protection: Protection = .completeUnlessOpen
    ) {
        self.fileURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(filename)
        self.protection = protection
    }

    /// Explicit-URL initialiser, used by tests to write into a temp directory.
    public init(fileURL: URL?, protection: Protection = .completeUnlessOpen) {
        self.fileURL = fileURL
        self.protection = protection
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @discardableResult
    public func save(_ snapshot: ShannonSnapshot) -> Bool {
        guard let fileURL else { return false }
        guard let data = try? Self.encoder.encode(snapshot) else { return false }

        var options: Data.WritingOptions = [.atomic]
        #if os(iOS) || os(watchOS)
        // Data Protection. Not available on macOS, where the equivalent
        // guarantee is FileVault plus the app sandbox.
        options.insert(protection == .complete
                       ? .completeFileProtection
                       : .completeFileProtectionUnlessOpen)
        #endif

        do {
            try data.write(to: fileURL, options: options)
            return true
        } catch {
            return false
        }
    }

    public func load() -> ShannonSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(ShannonSnapshot.self, from: data)
    }

    /// Removes the cache — called on sign-out, so a previous account's agent
    /// titles do not survive on disk.
    public func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Shared instances

    /// Written by the iPhone app, read by its widget.
    public static let phone = SnapshotCache(filename: "widget-snapshot.json")
    /// Written by the watch app, read by its complication.
    public static let watch = SnapshotCache(filename: "watch-snapshot.json")
}
