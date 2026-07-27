import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

// MARK: - Mac voice callout speaker (ENH-030)

/// Speaks pref-gated needs-you / task_complete callouts via `SpeechSynthesizing`.
///
/// Policy lives in `VoiceCalloutPolicy` (pure). This type only:
/// 1. Reads live gates (pref / mute / focus)
/// 2. Speaks the decided text through the injected synthesizer
///
/// Default pref is **off** — no ambient noise until the user opts in.
@MainActor
public final class MacVoiceCallout {
    private let synthesizer: SpeechSynthesizing

    /// Product pref (default off). Injectable for tests.
    public var voiceCalloutsEnabled: () -> Bool = {
        ShannonPreferences.voiceCalloutsEnabled()
    }

    /// Explicit mute (fail closed when true).
    public var isMuted: () -> Bool = { false }

    /// Focus / Do Not Disturb active → hold speech (fail closed).
    public var isFocusActive: () -> Bool = { false }

    /// Last text spoken (tests / debug). Nil until a successful announce.
    public private(set) var lastSpoken: String?

    public init(synthesizer: SpeechSynthesizing) {
        self.synthesizer = synthesizer
    }

    /// Prefer system TTS when available; recording stub for tests / no-AV hosts.
    public static func makeDefaultSynthesizer() -> SpeechSynthesizing {
        #if canImport(AVFAudio)
        return SystemSpeechSynthesizer()
        #else
        return RecordingSynthesizer()
        #endif
    }

    /// Announce if policy allows. Never invents text — empty decide → silence.
    public func announce(kind: VoiceCalloutKind, agentName: String) {
        guard let text = VoiceCalloutPolicy.decide(
            kind: kind,
            agentName: agentName,
            voiceCalloutsEnabled: voiceCalloutsEnabled(),
            muted: isMuted(),
            focusActive: isFocusActive()
        ) else {
            return
        }
        lastSpoken = text
        synthesizer.speak(text)
    }

    /// Speak a pre-decided line (call sites that already ran pure `decide`).
    public func speakIfPresent(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        lastSpoken = text
        synthesizer.speak(text)
    }
}
