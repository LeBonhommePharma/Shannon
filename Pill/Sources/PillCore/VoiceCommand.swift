import Foundation

/// What a finished dictation utterance resolved to.
public enum VoiceCommand: Sendable, Equatable {
    case confirm
    case deny
    case showStatus
    case pause
    case runBenchmark
    case whatsDocking
    /// Anything that is not a recognised command: forwarded to the agent.
    case query(String)
}

/// Turns a raw transcript into a command.
///
/// The central safety rule: **a control command must be the entire utterance.**
/// "yes" confirms; "yes, but check the ligand first" is a query. Substring
/// matching would let "no problem, run the benchmark" read as a denial, and
/// these commands gate destructive actions like "commit and push" — so an
/// ambiguous utterance is always downgraded to a query rather than guessed at.
///
/// Matching is token-based for the same reason: "north" must not contain "no",
/// and "yesterday" must not contain "yes".
public struct VoiceCommandParser: Sendable {

    /// Phrases that map to each command. Multi-word phrases are matched as a
    /// whole token sequence.
    private static let table: [(phrases: [[String]], command: VoiceCommand)] = [
        (["confirm", "yes", "approve", "approved", "yep", "yeah"].map { [$0] }, .confirm),
        (["deny", "no", "cancel", "decline", "nope"].map { [$0] }, .deny),
        ([["show", "status"], ["status"], ["show", "me", "status"]], .showStatus),
        ([["pause"], ["stop"], ["halt"]], .pause),
        ([["run", "benchmark"], ["start", "benchmark"], ["run", "the", "benchmark"]], .runBenchmark),
        ([["what's", "docking"], ["whats", "docking"], ["what", "is", "docking"],
          ["what's", "the", "docking"]], .whatsDocking),
    ]

    public init() {}

    /// Returns nil for an empty or punctuation-only transcript.
    public func parse(_ transcript: String) -> VoiceCommand? {
        let tokens = Self.tokenize(transcript)
        guard !tokens.isEmpty else { return nil }

        for (phrases, command) in Self.table where phrases.contains(tokens) {
            return command
        }

        // Not a bare command: hand the original text to the agent, trimmed but
        // otherwise untouched so the agent sees what the user actually said.
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return .query(cleaned)
    }

    /// Lowercase, strip punctuation except the apostrophe (so "what's" stays
    /// one token), split on whitespace.
    static func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let scrubbed = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "'" || ch.isWhitespace { return ch }
            return " "
        }
        return String(scrubbed)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

// MARK: - Announcements

/// Something Shannon wants to say out loud.
public struct Announcement: Sendable, Equatable, Identifiable {
    public enum Priority: Int, Sendable, Comparable {
        case routine = 0    // "target complete"
        case important = 1  // "benchmark finished"
        case urgent = 2     // "agent blocked", pending confirmation

        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    public let id: UUID
    public let text: String
    public let priority: Priority

    public init(id: UUID = UUID(), text: String, priority: Priority = .routine) {
        self.id = id
        self.text = text
        self.priority = priority
    }
}

/// Ordering and hold/release policy for spoken output.
///
/// Kept pure so the awkward part — what happens to queued speech while the
/// AirPods are out of your ears — is testable without a synthesizer. Routine
/// chatter that piled up while you were away is dropped on resume; urgent
/// items are kept, because "agent blocked, input needed" is still true five
/// minutes later while "target 3 complete" is just noise.
public struct AnnouncementQueue: Sendable {
    private var pending: [Announcement] = []
    public private(set) var isHeld = false

    /// Routine items older than this are dropped when output resumes.
    public var dropRoutineOnResume = true

    public init() {}

    public var count: Int { pending.count }
    public var isEmpty: Bool { pending.isEmpty }

    /// Enqueue, keeping higher priorities ahead of lower ones but preserving
    /// order within a priority (a stable insert, not a sort).
    public mutating func enqueue(_ announcement: Announcement) {
        let idx = pending.firstIndex { $0.priority < announcement.priority } ?? pending.count
        pending.insert(announcement, at: idx)
    }

    /// Stop releasing items — AirPods removed, a call started, or the user
    /// asked Shannon to be quiet.
    public mutating func hold() { isHeld = true }

    /// Resume. Returns the items that should now be spoken, in order.
    public mutating func release() -> [Announcement] {
        isHeld = false
        if dropRoutineOnResume {
            pending.removeAll { $0.priority == .routine }
        }
        let out = pending
        pending.removeAll()
        return out
    }

    /// Next item to speak, or nil while held or empty.
    public mutating func next() -> Announcement? {
        guard !isHeld, !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    public mutating func clear() { pending.removeAll() }
}
