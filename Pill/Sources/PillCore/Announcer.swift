import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

public protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String)
    func stopSpeaking()
}

public final class RecordingSynthesizer: SpeechSynthesizing {
    public private(set) var spoken: [String] = []
    public var isSpeaking = false
    public init() {}
    public func speak(_ text: String) { spoken.append(text) }
    public func stopSpeaking() { isSpeaking = false }
}

#if canImport(AVFAudio)
/// `AVSpeechSynthesizer` wrapper.
///
/// Note on spatial audio: the brief asked for `AVAudioEnvironmentNode`
/// positioning at front-centre. `AVSpeechSynthesizer` renders to the system
/// output directly and cannot be routed through an `AVAudioEngine` graph on
/// macOS (the `write(_:toBufferCallback:)` path yields buffers but loses the
/// system voice routing), so announcements are plain stereo. See BLOCKED.md §9.
public final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()

    public override init() { super.init() }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    public func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
#endif

/// Speaks Shannon's events, holding output when the headphones go away.
///
/// The hold/resume policy lives in `AnnouncementQueue`; this type owns the
/// wiring between the audio route and the synthesizer.
@MainActor
public final class Announcer: ObservableObject {
    @Published public private(set) var isHeld = false
    @Published public private(set) var route: AudioOutputRoute?
    @Published public private(set) var lastSpoken: String?

    private var queue = AnnouncementQueue()
    private let synthesizer: SpeechSynthesizing
    private let routeProvider: AudioRouteProviding

    /// When true, spoken output only happens while head-worn audio is
    /// connected — Shannon does not announce docking results out loud to a
    /// room through the built-in speakers.
    public var requireHeadworn = true

    public init(synthesizer: SpeechSynthesizing, routeProvider: AudioRouteProviding) {
        self.synthesizer = synthesizer
        self.routeProvider = routeProvider
    }

    public func start() {
        // The provider contract guarantees main-thread delivery, so state can
        // settle synchronously rather than a hop behind the route change.
        routeProvider.start { [weak self] newRoute in
            MainActor.assumeIsolated { self?.routeChanged(to: newRoute) }
        }
    }

    public func stop() {
        routeProvider.stop()
        synthesizer.stopSpeaking()
    }

    /// Queue something to say. Speaks immediately when not held.
    public func announce(_ announcement: Announcement) {
        queue.enqueue(announcement)
        drain()
    }

    public func announce(_ text: String, priority: Announcement.Priority = .routine) {
        announce(Announcement(text: text, priority: priority))
    }

    /// Silence output — "pause"/"stop" voice command, or a call starting.
    public func hold() {
        queue.hold()
        isHeld = true
        synthesizer.stopSpeaking()
    }

    public func resume() {
        let due = queue.release()
        isHeld = false
        for item in due { speak(item) }
    }

    var pendingCount: Int { queue.count }

    private func routeChanged(to newRoute: AudioOutputRoute?) {
        let transition = RouteTransition.between(old: route, new: newRoute)
        route = newRoute

        switch transition {
        case .headwornDisconnected:
            hold()
        case .headwornConnected:
            resume()
        case .changedOutput, .none:
            break
        }
    }

    private func drain() {
        guard !isHeld else { return }
        if requireHeadworn && route?.isHeadworn != true {
            // Nothing to speak into: hold rather than discard.
            queue.hold()
            isHeld = true
            return
        }
        while let item = queue.next() { speak(item) }
    }

    private func speak(_ item: Announcement) {
        lastSpoken = item.text
        synthesizer.speak(item.text)
    }
}
