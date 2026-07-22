import Foundation

/// Now Playing bridge over the private MediaRemote framework.
///
/// macOS has no public API for reading *another* app's Now Playing state —
/// `MPNowPlayingInfoCenter` only ever reports your own process. Every notch
/// utility (Islet included) therefore goes through MediaRemote, which is a
/// PrivateFramework. Two consequences, both handled here rather than crashing:
///
///  1. Starting with macOS 15.4 Apple gated `MRMediaRemoteGetNowPlayingInfo`
///     behind the `com.apple.mediaremote.now-playing-info` entitlement, which
///     Apple does not grant to third-party developers. On those systems the
///     symbols resolve but the callback yields an empty dictionary.
///  2. A Sequoia-era replacement exists as a *daemon* API with no stable
///     public surface, so there is no drop-in substitute.
///
/// `isAvailable` reports whether we resolved the symbols at all; `hasDelivered`
/// distinguishes "framework present but returning nothing" (the entitlement
/// wall) from "genuinely nothing playing". See Pill/BLOCKED.md.
public final class MediaRemoteProvider: NowPlayingProviding {

    private typealias GetNowPlayingInfo =
        @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias SendCommand =
        @convention(c) (Int, CFDictionary?) -> Bool
    private typealias RegisterNotifications =
        @convention(c) (DispatchQueue) -> Void
    private typealias SetElapsed =
        @convention(c) (Double) -> Void

    // MediaRemote command codes.
    private enum Command {
        static let togglePlayPause = 2
        static let nextTrack = 4
        static let previousTrack = 5
    }

    private enum InfoKey {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
    }

    private let handle: UnsafeMutableRawPointer?
    private let getInfo: GetNowPlayingInfo?
    private let sendCommand: SendCommand?
    private let register: RegisterNotifications?
    private let setElapsed: SetElapsed?

    private var handler: ((NowPlayingEvent) -> Void)?
    private var pollTimer: Timer?
    private var observer: NSObjectProtocol?

    /// True once MediaRemote has handed us a non-empty payload at least once.
    public private(set) var hasDelivered = false

    public var isAvailable: Bool { getInfo != nil }

    public init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        let lib = dlopen(path, RTLD_LAZY)
        handle = lib

        // Binds against the local `lib` rather than `self.handle` so the
        // lookups can run before all stored properties are initialized.
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let lib, let p = dlsym(lib, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }

        getInfo = sym("MRMediaRemoteGetNowPlayingInfo", as: GetNowPlayingInfo.self)
        sendCommand = sym("MRMediaRemoteSendCommand", as: SendCommand.self)
        register = sym("MRMediaRemoteRegisterForNowPlayingNotifications",
                       as: RegisterNotifications.self)
        setElapsed = sym("MRMediaRemoteSetElapsedTime", as: SetElapsed.self)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let handle { dlclose(handle) }
    }

    public func start(onEvent: @escaping (NowPlayingEvent) -> Void) {
        guard isAvailable else { return }
        handler = onEvent

        register?(.main)
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }

        refresh()

        // MediaRemote notifications are unreliable for browser-hosted audio,
        // so poll as a floor.
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        handler = nil
    }

    public func refresh() {
        guard let getInfo else { return }
        getInfo(.main) { [weak self] raw in
            guard let self else { return }
            guard let event = Self.event(from: raw) else {
                self.handler?(.cleared)
                return
            }
            self.hasDelivered = true
            self.handler?(event)
        }
    }

    /// Translate a MediaRemote payload into an event. Exposed for tests.
    public static func event(from raw: [String: Any]) -> NowPlayingEvent? {
        let title = raw[InfoKey.title] as? String ?? ""
        let artist = raw[InfoKey.artist] as? String ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return nil }

        let rate = raw[InfoKey.playbackRate] as? Double ?? 0
        let info = NowPlayingInfo(
            title: title,
            artist: artist,
            album: raw[InfoKey.album] as? String ?? "",
            duration: raw[InfoKey.duration] as? Double ?? 0,
            elapsed: raw[InfoKey.elapsed] as? Double ?? 0,
            isPlaying: rate > 0,
            artworkData: raw[InfoKey.artworkData] as? Data
        )
        return .updated(info)
    }

    public func togglePlayPause() { _ = sendCommand?(Command.togglePlayPause, nil) }
    public func nextTrack() { _ = sendCommand?(Command.nextTrack, nil) }
    public func previousTrack() { _ = sendCommand?(Command.previousTrack, nil) }

    public func seek(toProgress fraction: Double) {
        guard let setElapsed else { return }
        getInfo?(.main) { raw in
            guard let duration = raw[InfoKey.duration] as? Double, duration > 0 else { return }
            setElapsed(min(max(fraction, 0), 1) * duration)
        }
    }
}
