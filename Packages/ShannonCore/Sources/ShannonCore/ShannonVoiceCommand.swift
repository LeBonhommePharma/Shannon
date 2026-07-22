import Foundation

/// Voice commands, parsed identically on macOS, iOS and watchOS.
///
/// Speech recognisers return lightly punctuated, lower-cased-ish text with no
/// guarantee of exact wording, so matching is phrase-based rather than exact:
/// "yes, confirm that" and "Confirm." must both land on `.confirm`.
public enum VoiceCommand: Equatable, Sendable {
    case confirm
    case deny
    case status
    case benchmark
    case nowPlaying
    /// Anything unrecognised, normalised but otherwise untouched, for the Mac
    /// to treat as a query.
    case freeform(String)

    /// Phrases that answer a pending confirmation. Ordered longest-first at
    /// match time so "don't confirm" cannot match the "confirm" prefix.
    static let confirmPhrases = [
        "confirm", "confirmed", "yes", "yep", "yeah", "affirmative",
        "approve", "approved", "do it", "go ahead", "accept", "ok", "okay",
    ]

    static let denyPhrases = [
        "deny", "denied", "no", "nope", "negative", "reject", "rejected",
        "cancel", "stop", "don't", "do not", "abort",
    ]

    static let statusPhrases = [
        "status", "show status", "what's happening", "what is happening",
        "how's it going", "how is it going", "agents", "show agents",
    ]

    static let benchmarkPhrases = [
        "benchmark", "docking", "what's docking", "what is docking",
        "docking status", "progress", "rmsd",
    ]

    static let nowPlayingPhrases = [
        "now playing", "what's playing", "what is playing", "track",
        "what song", "music",
    ]

    /// Parse a raw transcript. Never throws and never returns nil: unmatched
    /// speech becomes `.freeform`, which the Mac answers as a question rather
    /// than silently dropping.
    public static func parse(_ transcript: String) -> VoiceCommand {
        let normalised = normalise(transcript)
        guard !normalised.isEmpty else { return .freeform("") }

        // Negation is checked first and wins outright. "no, don't confirm"
        // contains "confirm", and answering yes there would be the single
        // worst failure mode this parser has.
        if matches(normalised, denyPhrases) { return .deny }
        if matches(normalised, confirmPhrases) { return .confirm }
        if matches(normalised, benchmarkPhrases) { return .benchmark }
        if matches(normalised, nowPlayingPhrases) { return .nowPlaying }
        if matches(normalised, statusPhrases) { return .status }
        return .freeform(normalised)
    }

    /// Lower-case, strip punctuation, collapse whitespace. Also drops a
    /// leading wake phrase, since "hey Siri, Shannon confirm" arrives intact
    /// from the watch's App Intent route.
    static func normalise(_ transcript: String) -> String {
        var text = transcript.lowercased()
        for prefix in ["hey siri", "siri", "shannon"] {
            while text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
            }
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " '"))
        let stripped = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return stripped.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whole-word matching. Substring matching would fire `.deny` on "nope"
    /// inside "nopeless" and, worse, `.confirm` on any word containing "ok".
    static func matches(_ normalised: String, _ phrases: [String]) -> Bool {
        let words = normalised.split(separator: " ").map(String.init)
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            let phraseWords = phrase.split(separator: " ").map(String.init)
            guard phraseWords.count <= words.count else { continue }
            for start in 0...(words.count - phraseWords.count)
            where Array(words[start..<(start + phraseWords.count)]) == phraseWords {
                return true
            }
        }
        return false
    }

    /// The answer this command represents, or nil when it is not an answer.
    public var confirmationAnswer: ConfirmationAnswer? {
        switch self {
        case .confirm: return .confirmed
        case .deny:    return .denied
        default:       return nil
        }
    }

    /// Suggestions offered by the watch's built-in dictation UI.
    public static let watchSuggestions = ["confirm", "deny", "status"]
}
