import Foundation

// MARK: - PetMemoryEntry

/// A single line in the pet's natural-language diary.
/// Stored as Markdown in `~/.shannon/pets/{id}/memory.md`.
/// Never contains credentials, tokens, or agent tool-call details.
public struct PetMemoryEntry: Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case interaction, milestone, observation
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var text: String

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, text: String) {
        self.id   = id
        self.date = date
        self.kind = kind
        self.text = text
    }

    /// Markdown representation: an H2 timestamp header + the entry body.
    public var markdownLine: String {
        "## \(Self.stamp(date))\n\(text)\n"
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)
    }
}

// MARK: - PetMemoryStore

/// Thread-safe, append-only store for the pet's diary.
/// Writes are debounced 2 s so rapid interactions don't thrash the file.
/// The diary file coexists with the Python `pet_manager.py` layout —
/// both agents append; neither truncates.
public actor PetMemoryStore {
    private let url: URL
    private var pending: [PetMemoryEntry] = []
    private var flushTask: Task<Void, Never>?

    public init(petID: String) {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shannon/pets/\(petID)", isDirectory: true)
        #else
        let base = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("shannon/pets/\(petID)", isDirectory: true)
        #endif
        url = base.appendingPathComponent("memory.md")
    }

    /// Queue an entry; actual disk write is debounced 2 s.
    public func append(entry: PetMemoryEntry) {
        pending.append(entry)
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    /// Return the most-recent `limit` entries, newest first.
    public func recentEntries(limit: Int = 10) -> [PetMemoryEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(Self.parse(text).suffix(limit).reversed())
    }

    // MARK: Private

    private func flush() {
        guard !pending.isEmpty else { return }
        let toWrite = pending
        pending.removeAll()
        ensureFile()
        let appended = toWrite.map { $0.markdownLine }.joined(separator: "\n")
        if var existing = try? String(contentsOf: url, encoding: .utf8) {
            existing += "\n\(appended)"
            try? existing.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func ensureFile() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
        try? (url as NSURL).setResourceValue(
            URLFileProtection.complete, forKey: .fileProtectionKey)
    }

    private static func parse(_ text: String) -> [PetMemoryEntry] {
        var out: [PetMemoryEntry] = []
        for chunk in text.components(separatedBy: "\n## ") {
            let lines = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                             .components(separatedBy: "\n")
            guard let header = lines.first, header.count >= 16,
                  let date = PetMemoryEntry.parseDate(String(header.prefix(16))) else { continue }
            let body = lines.dropFirst().joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            out.append(PetMemoryEntry(date: date, kind: .interaction, text: body))
        }
        return out
    }
}
