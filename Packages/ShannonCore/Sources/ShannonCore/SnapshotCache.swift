import Foundation

/// On-disk snapshot + optional hub/sync error for App Group readers (widgets).
///
/// **UX-038:** companions persist fail-closed offline alongside the last good
/// agent list. `lastError == nil` means last write considered sync healthy;
/// non-nil drives `CompanionEmptyStateCopy` offline chrome in the widget.
///
/// Encoding is a thin envelope. Legacy files that were bare `ShannonSnapshot`
/// JSON still load (offline = false).
public struct SnapshotCacheRecord: Codable, Equatable, Sendable {
    public var snapshot: ShannonSnapshot
    /// `ShannonStore.lastError` at write time, or nil when last refresh succeeded.
    public var lastError: String?

    public init(snapshot: ShannonSnapshot, lastError: String? = nil) {
        self.snapshot = snapshot
        self.lastError = lastError
    }

    /// Fail-closed offline flag for widget / complication empty chrome.
    public var isOffline: Bool {
        CompanionEmptyStateCopy.hasSyncError(lastError)
    }
}

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

    /// Persist snapshot plus optional offline/lastError signal (UX-038).
    @discardableResult
    public func save(_ snapshot: ShannonSnapshot, lastError: String? = nil) -> Bool {
        save(SnapshotCacheRecord(snapshot: snapshot, lastError: lastError))
    }

    @discardableResult
    public func save(_ record: SnapshotCacheRecord) -> Bool {
        guard let fileURL else { return false }
        guard let data = try? Self.encoder.encode(record) else { return false }

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

    /// Full envelope (snapshot + offline). Prefer for widget fail-closed UI.
    public func loadRecord() -> SnapshotCacheRecord? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        if let record = try? Self.decoder.decode(SnapshotCacheRecord.self, from: data) {
            return record
        }
        // Backward compatible: pre-UX-038 bare ShannonSnapshot files.
        if let snapshot = try? Self.decoder.decode(ShannonSnapshot.self, from: data) {
            return SnapshotCacheRecord(snapshot: snapshot, lastError: nil)
        }
        return nil
    }

    public func load() -> ShannonSnapshot? {
        loadRecord()?.snapshot
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
