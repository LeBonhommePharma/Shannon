import Foundation

public struct NowPlayingInfo: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds. 0 when the source does not publish a duration (live streams).
    public var duration: Double
    public var elapsed: Double
    public var isPlaying: Bool
    public var artworkData: Data?
    /// Bundle id of the app that published this, e.g. "com.apple.Music".
    public var sourceBundleID: String?

    public init(
        title: String,
        artist: String = "",
        album: String = "",
        duration: Double = 0,
        elapsed: Double = 0,
        isPlaying: Bool = false,
        artworkData: Data? = nil,
        sourceBundleID: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.isPlaying = isPlaying
        self.artworkData = artworkData
        self.sourceBundleID = sourceBundleID
    }

    /// 0.0...1.0 scrubber position. Zero-duration sources report 0.
    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// What the pill is currently showing for media.
public enum NowPlayingState: Sendable, Equatable {
    case idle
    case playing(NowPlayingInfo)
    case paused(NowPlayingInfo)

    public var info: NowPlayingInfo? {
        switch self {
        case .idle: return nil
        case .playing(let i), .paused(let i): return i
        }
    }

    public var isActive: Bool { info != nil }
}

public enum NowPlayingEvent: Sendable, Equatable {
    /// The system published a fresh info payload.
    case updated(NowPlayingInfo)
    /// Playback state toggled without new track metadata.
    case playbackChanged(isPlaying: Bool)
    /// Elapsed time ticked (local interpolation between polls).
    case elapsed(Double)
    /// Every media app stopped publishing.
    case cleared
}

/// Pure reducer over media events. Isolated from MediaRemote so the
/// transitions can be tested without a live media session.
public struct NowPlayingStateMachine: Sendable {
    public private(set) var state: NowPlayingState = .idle

    public init(state: NowPlayingState = .idle) {
        self.state = state
    }

    @discardableResult
    public mutating func apply(_ event: NowPlayingEvent) -> NowPlayingState {
        switch event {
        case .cleared:
            state = .idle

        case .updated(let info):
            // An empty title is how some sources signal "nothing loaded".
            if info.title.isEmpty && info.artist.isEmpty {
                state = .idle
            } else {
                state = info.isPlaying ? .playing(info) : .paused(info)
            }

        case .playbackChanged(let isPlaying):
            guard var info = state.info else { return state }
            info.isPlaying = isPlaying
            state = isPlaying ? .playing(info) : .paused(info)

        case .elapsed(let seconds):
            guard var info = state.info else { return state }
            info.elapsed = info.duration > 0 ? min(seconds, info.duration) : max(seconds, 0)
            state = info.isPlaying ? .playing(info) : .paused(info)
        }
        return state
    }

    /// Text for the collapsed pill: "▶ track — artist" (or "❙❙" when paused).
    /// Returns nil when there is nothing to show, so the pill can fall back
    /// to the Shannon entropy readout.
    public func collapsedLabel(maxLength: Int = 42) -> String? {
        guard let info = state.info else { return nil }
        let glyph = info.isPlaying ? "▶" : "❙❙"
        let body = info.artist.isEmpty ? info.title : "\(info.title) — \(info.artist)"
        let composed = "\(glyph) \(body)"
        guard composed.count > maxLength else { return composed }
        let keep = max(maxLength - 1, 1)
        return String(composed.prefix(keep)) + "…"
    }
}

// MARK: - Providers

public protocol NowPlayingProviding: AnyObject {
    /// Begin publishing events. Called on the main actor.
    func start(onEvent: @escaping (NowPlayingEvent) -> Void)
    func stop()
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    /// Seek to a fraction of the track, 0.0...1.0.
    func seek(toProgress fraction: Double)
    /// False when the backing system API is unavailable on this OS build.
    var isAvailable: Bool { get }
}

/// Deterministic provider used by tests and by `--demo` runs.
public final class StubNowPlayingProvider: NowPlayingProviding {
    private var handler: ((NowPlayingEvent) -> Void)?
    public private(set) var commands: [String] = []
    public var isAvailable: Bool { true }

    public init() {}

    public func start(onEvent: @escaping (NowPlayingEvent) -> Void) { handler = onEvent }
    public func stop() { handler = nil }
    public func emit(_ event: NowPlayingEvent) { handler?(event) }

    public func togglePlayPause() { commands.append("togglePlayPause") }
    public func nextTrack() { commands.append("nextTrack") }
    public func previousTrack() { commands.append("previousTrack") }
    public func seek(toProgress fraction: Double) {
        commands.append("seek:\(String(format: "%.3f", fraction))")
    }
}

/// Observable wrapper the SwiftUI views bind to.
@MainActor
public final class NowPlayingModel: ObservableObject {
    @Published public private(set) var state: NowPlayingState = .idle
    @Published public private(set) var providerAvailable: Bool

    private var machine = NowPlayingStateMachine()
    private let provider: NowPlayingProviding
    private var tickTimer: Timer?

    public init(provider: NowPlayingProviding) {
        self.provider = provider
        self.providerAvailable = provider.isAvailable
    }

    public var collapsedLabel: String? { machine.collapsedLabel() }

    public func start() {
        guard provider.isAvailable else { return }
        provider.start { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Interpolate elapsed between system polls so the scrubber moves.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .playing(let info) = self.state else { return }
                self.handle(.elapsed(info.elapsed + 1))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    public func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        provider.stop()
    }

    private func handle(_ event: NowPlayingEvent) {
        state = machine.apply(event)
    }

    public func togglePlayPause() { provider.togglePlayPause() }
    public func nextTrack() { provider.nextTrack() }
    public func previousTrack() { provider.previousTrack() }
    public func seek(to fraction: Double) { provider.seek(toProgress: fraction) }
}
