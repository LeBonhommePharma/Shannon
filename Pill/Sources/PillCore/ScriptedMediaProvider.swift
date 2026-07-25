import Foundation

// MARK: - Pure AppleScript parse (unit-tested)

/// Music / Spotify Now Playing via AppleScript — BLOCKED.md §1 fallback when
/// MediaRemote is entitlement-gated empty.
///
/// Coverage: Music.app + Spotify only. No browsers/VLC. No artwork for most
/// Spotify builds. Requires Automation consent per app (fail-closed).
public enum ScriptedMediaLogic {
    public enum App: String, Sendable, CaseIterable {
        case music = "Music"
        case spotify = "Spotify"

        public var bundleID: String {
            switch self {
            case .music: return "com.apple.Music"
            case .spotify: return "com.spotify.client"
            }
        }
    }

    /// Parse `title|artist|album|duration|position|playing` lines from osascript.
    public static func parsePipeLine(_ raw: String, source: App) -> NowPlayingInfo? {
        let line = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 6 else { return nil }
        let title = parts[0]
        let artist = parts[1]
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        let album = parts[2]
        let duration = Double(parts[3]) ?? 0
        let elapsed = Double(parts[4]) ?? 0
        let playingRaw = parts[5].lowercased()
        let isPlaying = playingRaw == "true" || playingRaw == "playing" || playingRaw == "1"
        return NowPlayingInfo(
            title: title,
            artist: artist,
            album: album,
            duration: max(0, duration),
            elapsed: max(0, elapsed),
            isPlaying: isPlaying,
            artworkData: nil,
            sourceBundleID: source.bundleID
        )
    }

    public static func statusScript(for app: App) -> String {
        switch app {
        case .music:
            return """
            tell application "Music"
              if it is running and (player state is playing or player state is paused) then
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set d to duration of current track
                set p to player position
                set pl to (player state is playing)
                return t & "|" & a & "|" & al & "|" & d & "|" & p & "|" & pl
              end if
            end tell
            return "|||||"
            """
        case .spotify:
            return """
            tell application "Spotify"
              if it is running then
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set d to (duration of current track) / 1000
                set p to player position
                set pl to (player state is playing)
                return t & "|" & a & "|" & al & "|" & d & "|" & p & "|" & pl
              end if
            end tell
            return "|||||"
            """
        }
    }

    public static func toggleScript(for app: App) -> String {
        """
        tell application "\(app.rawValue)"
          playpause
        end tell
        """
    }

    public static func nextScript(for app: App) -> String {
        """
        tell application "\(app.rawValue)"
          next track
        end tell
        """
    }

    public static func previousScript(for app: App) -> String {
        """
        tell application "\(app.rawValue)"
          previous track
        end tell
        """
    }
}

// MARK: - Live provider

/// Polls Music then Spotify via osascript when MediaRemote is empty.
public final class ScriptedMediaProvider: NowPlayingProviding {
    private var handler: ((NowPlayingEvent) -> Void)?
    private var timer: Timer?
    private var lastApp: ScriptedMediaLogic.App?
    public private(set) var lastInfo: NowPlayingInfo?

    /// Always "available" as a fallback path — individual scripts may fail closed.
    public var isAvailable: Bool { true }

    public init() {}

    public func start(onEvent: @escaping (NowPlayingEvent) -> Void) {
        handler = onEvent
        refresh()
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
    }

    public func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let info = self.pollOnce()
            DispatchQueue.main.async {
                if let info {
                    self.lastInfo = info
                    self.lastApp = ScriptedMediaLogic.App.allCases
                        .first { $0.bundleID == info.sourceBundleID }
                    self.handler?(.updated(info))
                } else if self.lastInfo != nil {
                    self.lastInfo = nil
                    self.lastApp = nil
                    self.handler?(.cleared)
                }
            }
        }
    }

    private func pollOnce() -> NowPlayingInfo? {
        for app in ScriptedMediaLogic.App.allCases {
            if let info = runStatus(app) { return info }
        }
        return nil
    }

    private func runStatus(_ app: ScriptedMediaLogic.App) -> NowPlayingInfo? {
        guard let out = runOsascript(ScriptedMediaLogic.statusScript(for: app)) else { return nil }
        return ScriptedMediaLogic.parsePipeLine(out, source: app)
    }

    public func togglePlayPause() {
        guard let app = lastApp else { return }
        _ = runOsascript(ScriptedMediaLogic.toggleScript(for: app))
        refresh()
    }

    public func nextTrack() {
        guard let app = lastApp else { return }
        _ = runOsascript(ScriptedMediaLogic.nextScript(for: app))
        refresh()
    }

    public func previousTrack() {
        guard let app = lastApp else { return }
        _ = runOsascript(ScriptedMediaLogic.previousScript(for: app))
        refresh()
    }

    public func seek(toProgress fraction: Double) {
        // AppleScript seek is app-specific and rarely reliable; leave as no-op.
        _ = fraction
    }

    private func runOsascript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2.0)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

// MARK: - Composite (MediaRemote primary, scripted fallback)

/// Prefers MediaRemote; when it only ever delivers empty, falls back to Music/Spotify scripts.
public final class CompositeNowPlayingProvider: NowPlayingProviding {
    private let primary: MediaRemoteProvider
    private let fallback: ScriptedMediaProvider
    private var handler: ((NowPlayingEvent) -> Void)?
    private var usingFallback = false
    private var primaryEmptyStreak = 0

    public var isAvailable: Bool { primary.isAvailable || fallback.isAvailable }

    public init(
        primary: MediaRemoteProvider = MediaRemoteProvider(),
        fallback: ScriptedMediaProvider = ScriptedMediaProvider()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func start(onEvent: @escaping (NowPlayingEvent) -> Void) {
        handler = onEvent
        primary.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .cleared:
                self.notePrimaryEmpty()
            case .updated(let info) where info.title.isEmpty && info.artist.isEmpty:
                self.notePrimaryEmpty()
            case .updated, .playbackChanged, .elapsed:
                // Live MediaRemote payload — own the stream, drop fallback.
                self.primaryEmptyStreak = 0
                self.usingFallback = false
                self.handler?(event)
            }
        }
        fallback.start { [weak self] event in
            guard let self, self.usingFallback || !self.primary.hasDelivered else { return }
            self.handler?(event)
        }
    }

    public func stop() {
        primary.stop()
        fallback.stop()
        handler = nil
    }

    public func togglePlayPause() {
        if usingFallback { fallback.togglePlayPause() }
        else { primary.togglePlayPause() }
    }

    public func nextTrack() {
        if usingFallback { fallback.nextTrack() }
        else { primary.nextTrack() }
    }

    public func previousTrack() {
        if usingFallback { fallback.previousTrack() }
        else { primary.previousTrack() }
    }

    public func seek(toProgress fraction: Double) {
        if usingFallback { fallback.seek(toProgress: fraction) }
        else { primary.seek(toProgress: fraction) }
    }

    private func notePrimaryEmpty() {
        primaryEmptyStreak += 1
        // After an empty MediaRemote poll, try scripted Music/Spotify.
        if primaryEmptyStreak >= 1 {
            usingFallback = true
        }
        if usingFallback {
            // Let fallback own the next tick; don't force-clear yet.
            fallback.refresh()
        } else {
            handler?(.cleared)
        }
    }
}
