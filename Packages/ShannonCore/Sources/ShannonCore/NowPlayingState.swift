import Foundation

/// Mirrored Now Playing state from the Mac. Artwork is carried as JPEG data
/// and is the only field here that is not trivially small, so the publisher
/// downsamples it before writing.
public struct NowPlayingSnapshot: CloudSyncable, Codable, Hashable {
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds; 0 for live streams that publish no duration.
    public var duration: Double
    public var elapsed: Double
    public var isPlaying: Bool
    /// Downsampled JPEG. Nil when the source publishes no artwork.
    public var artworkJPEG: Data?
    public var sourceBundleID: String?
    public var updatedAt: Date

    /// Artwork above this size is dropped rather than synced — iCloud is not a
    /// CDN and the watch never renders anything this large.
    public static let maxArtworkBytes = 200 * 1024

    public init(
        title: String,
        artist: String = "",
        album: String = "",
        duration: Double = 0,
        elapsed: Double = 0,
        isPlaying: Bool = false,
        artworkJPEG: Data? = nil,
        sourceBundleID: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.isPlaying = isPlaying
        self.artworkJPEG = artworkJPEG
        self.sourceBundleID = sourceBundleID
        self.updatedAt = updatedAt
    }

    public var isIdle: Bool { title.isEmpty && artist.isEmpty }

    /// 0.0...1.0 scrubber position.
    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    /// Complication / compact line: "▶ Track — Artist".
    public func compactLine(maxLength: Int = 34) -> String? {
        guard !isIdle else { return nil }
        let glyph = isPlaying ? "▶" : "❙❙"
        let body = artist.isEmpty ? title : "\(title) — \(artist)"
        let composed = "\(glyph) \(body)"
        guard composed.count > maxLength else { return composed }
        return String(composed.prefix(max(maxLength - 1, 1))) + "…"
    }

    /// Drops artwork that exceeds the sync budget. Applied by the publisher
    /// before every write.
    public func trimmedForSync() -> NowPlayingSnapshot {
        guard let art = artworkJPEG, art.count > Self.maxArtworkBytes else { return self }
        var copy = self
        copy.artworkJPEG = nil
        return copy
    }

    // MARK: CloudSyncable

    public static let recordType = "NowPlaying"
    /// Singleton per iCloud account: the Mac has one Now Playing state.
    public var recordName: String { "nowplaying-current" }

    enum Field {
        static let title = "title"
        static let artist = "artist"
        static let album = "album"
        static let duration = "duration"
        static let elapsed = "elapsed"
        static let isPlaying = "isPlaying"
        static let artwork = "artworkJPEG"
        static let sourceBundleID = "sourceBundleID"
    }

    public var cloudFields: CloudFields {
        var f: CloudFields = [
            Field.title: .string(title),
            Field.artist: .string(artist),
            Field.album: .string(album),
            Field.duration: .double(duration),
            Field.elapsed: .double(elapsed),
            Field.isPlaying: .bool(isPlaying),
            CloudKeys.updatedAt: .date(updatedAt),
        ]
        if let artworkJPEG { f[Field.artwork] = .data(artworkJPEG) }
        if let sourceBundleID { f[Field.sourceBundleID] = .string(sourceBundleID) }
        return f
    }

    public init(cloudFields f: CloudFields) throws {
        self.init(
            title: try f.string(Field.title),
            artist: try f.string(Field.artist),
            album: try f.string(Field.album),
            duration: try f.double(Field.duration),
            elapsed: try f.double(Field.elapsed),
            isPlaying: try f.bool(Field.isPlaying),
            artworkJPEG: try f.optionalData(Field.artwork),
            sourceBundleID: try f.optionalString(Field.sourceBundleID),
            updatedAt: try f.date(CloudKeys.updatedAt)
        )
    }
}

/// Playback commands sent phone/watch → Mac. Written as records the Mac
/// subscribes to; the Mac deletes each one after executing it.
public enum PlaybackCommand: String, Codable, Sendable, CaseIterable {
    case togglePlayPause
    case nextTrack
    case previousTrack
}

public struct RemoteCommand: CloudSyncable, Codable, Identifiable, Hashable {
    /// Unique per issue — commands must not overwrite each other, unlike state.
    public var id: String
    public var command: PlaybackCommand
    /// Which device issued it, for the Mac's log.
    public var origin: String
    public var issuedAt: Date

    /// Commands older than this are ignored by the Mac. A tap queued while the
    /// watch was offline should not skip a track twenty minutes later.
    public static let staleAfter: TimeInterval = 60

    public init(
        id: String = UUID().uuidString,
        command: PlaybackCommand,
        origin: String,
        issuedAt: Date = Date()
    ) {
        self.id = id
        self.command = command
        self.origin = origin
        self.issuedAt = issuedAt
    }

    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(issuedAt) > Self.staleAfter
    }

    // MARK: CloudSyncable

    public static let recordType = "RemoteCommand"
    public var recordName: String { "command-\(id)" }

    enum Field {
        static let id = "commandID"
        static let command = "command"
        static let origin = "origin"
        static let issuedAt = "issuedAt"
    }

    public var cloudFields: CloudFields {
        [
            Field.id: .string(id),
            Field.command: .string(command.rawValue),
            Field.origin: .string(origin),
            Field.issuedAt: .date(issuedAt),
            CloudKeys.updatedAt: .date(issuedAt),
        ]
    }

    public init(cloudFields f: CloudFields) throws {
        let raw = try f.string(Field.command)
        guard let command = PlaybackCommand(rawValue: raw) else {
            throw CloudDecodeError.unknownEnumValue(field: Field.command, value: raw)
        }
        self.init(
            id: try f.string(Field.id),
            command: command,
            origin: try f.string(Field.origin),
            issuedAt: try f.date(Field.issuedAt)
        )
    }
}
