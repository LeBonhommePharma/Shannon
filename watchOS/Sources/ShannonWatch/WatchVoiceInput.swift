import Foundation
import ShannonCore
#if canImport(WatchKit)
import WatchKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Voice input on the watch uses the system dictation sheet rather than a
/// bespoke recogniser. Apple's sheet already handles Scribble, dictation and
/// the mic affordance better than a reimplementation would, and it keeps the
/// audio session out of Shannon's hands entirely.
///
/// The recognised text goes through the same `VoiceCommand.parse` the phone
/// and Mac use, so "confirm" means the same thing on every device.
@available(watchOS 10.0, *)
@MainActor
public enum WatchVoiceInput {

    public static func present(_ completion: @escaping (VoiceCommand) -> Void) {
        #if canImport(WatchKit)
        guard let controller = WKExtension.shared().visibleInterfaceController else {
            completion(.freeform(""))
            return
        }
        controller.presentTextInputController(
            withSuggestions: VoiceCommand.watchSuggestions,
            allowedInputMode: .plain
        ) { results in
            let text = (results?.first as? String) ?? ""
            Task { @MainActor in
                completion(VoiceCommand.parse(text))
            }
        }
        #else
        completion(.freeform(""))
        #endif
    }
}

/// Spoken announcements on the watch, e.g. "Target complete — 0.34 ångströms".
///
/// Two rules, both about not talking over things: never speak while other
/// audio is playing or a call is active, and suppress the watch's own taptics
/// for the duration of an announcement so LP does not get buzzed and told the
/// same thing simultaneously.
@available(watchOS 10.0, *)
@MainActor
public final class WatchAnnouncer {
    public private(set) var isSpeaking = false

    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif

    public init() {}

    public func announce(_ text: String) {
        guard !text.isEmpty else { return }
        #if canImport(AVFoundation)
        let session = AVAudioSession.sharedInstance()
        guard !session.isOtherAudioPlaying else { return }
        do {
            // `.spokenAudio` ducks rather than stops whatever else is running,
            // and routes through AirPods when they are connected.
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking = true
        synthesizer.speak(utterance)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(text.count) / 12 + 1))
            self?.isSpeaking = false
        }
        #endif
    }

    /// True while a taptic would collide with speech.
    public var shouldSuppressHaptics: Bool { isSpeaking }
}
