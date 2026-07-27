import Foundation

// MARK: - Gate ask change paths / summary (ENH-031 / parity G9)

/// Pure presenter for **optional** change paths and summary on gate asks.
///
/// AgentCallout shows diffs/paths on approve; Shannon gate cards only had the
/// prompt text. When a real approval payload already carries path list or
/// summary fields, surface a clipped list under the prompt — never invent
/// paths, never fabricate diffs.
///
/// Fail-closed: missing / empty / non-string fields → empty presentation.
public enum GateAskChangePaths: Sendable {

    /// Max paths rendered before an overflow token (`+N more`).
    public static let defaultMaxPaths = 4

    /// Max characters per path line (clip middle-ish basename bias via prefix…).
    public static let defaultMaxPathLength = 52

    /// Max characters for the optional summary line.
    public static let defaultMaxSummaryLength = 80

    // MARK: Real wire keys only (never invent)

    /// Array-valued keys agents/hubs use for change path lists.
    /// Matches gate `POINTER_KEYS` plurals + common approval payload shapes.
    public static let pathListKeys: [String] = [
        "paths",
        "files",
        "filepaths",
        "filenames",
        "change_paths",
        "changed_paths",
        "changed_files",
        "file_paths",
        "paths_changed",
    ]

    /// Scalar path keys (single file approvals).
    public static let pathScalarKeys: [String] = [
        "path",
        "file",
        "filepath",
        "filename",
        "file_path",
    ]

    /// Optional one-line summary keys. Shown only when non-empty real string.
    public static let summaryKeys: [String] = [
        "change_summary",
        "files_summary",
        "diff_summary",
        "paths_summary",
        "summary",
    ]

    // MARK: Presentation

    /// Clipped display package for one ask surface.
    public struct Presentation: Equatable, Sendable {
        /// Optional one-line summary from a real payload field.
        public let summary: String?
        /// Path lines already length-clipped; order preserved from payload.
        public let pathLines: [String]
        /// Paths not shown (beyond maxPaths). Zero when fully listed.
        public let overflowCount: Int

        public init(summary: String? = nil, pathLines: [String] = [], overflowCount: Int = 0) {
            self.summary = GateAskChangePaths.nonEmpty(summary)
            self.pathLines = pathLines
            self.overflowCount = max(0, overflowCount)
        }

        public var isEmpty: Bool {
            summary == nil && pathLines.isEmpty
        }

        /// Lines for a multi-line `Text` / stack (summary → paths → overflow).
        public var displayLines: [String] {
            var lines: [String] = []
            if let summary { lines.append(summary) }
            lines.append(contentsOf: pathLines)
            if overflowCount > 0 {
                lines.append("+\(overflowCount) more")
            }
            return lines
        }

        /// Single block for one `Text` view; `nil` when nothing real to show.
        public var joinedDisplay: String? {
            let lines = displayLines
            guard !lines.isEmpty else { return nil }
            return lines.joined(separator: "\n")
        }

        /// Compact accessibility label (single sentence).
        public var accessibilityLabel: String? {
            guard !isEmpty else { return nil }
            var parts: [String] = []
            if let summary { parts.append(summary) }
            if !pathLines.isEmpty {
                parts.append(pathLines.joined(separator: ", "))
            }
            if overflowCount > 0 {
                parts.append("\(overflowCount) more")
            }
            let joined = parts.joined(separator: ". ")
            return joined.isEmpty ? nil : joined
        }
    }

    // MARK: Format

    /// Build presentation from already-extracted real fields.
    ///
    /// - Parameters:
    ///   - paths: Path strings from payload (not invented). Empty → no path lines.
    ///   - summary: Optional real summary string.
    ///   - maxPaths: Cap on listed paths (overflow reported).
    ///   - maxPathLength: Per-path character clip.
    ///   - maxSummaryLength: Summary character clip.
    public static func present(
        paths: [String],
        summary: String? = nil,
        maxPaths: Int = defaultMaxPaths,
        maxPathLength: Int = defaultMaxPathLength,
        maxSummaryLength: Int = defaultMaxSummaryLength
    ) -> Presentation {
        let cleaned = sanitizePaths(paths)
        let cap = Swift.max(0, maxPaths)
        let shown = Array(cleaned.prefix(cap)).map { clip($0, maxLength: maxPathLength) }
        let overflow = Swift.max(0, cleaned.count - shown.count)
        let sum = clipOptional(summary, maxLength: maxSummaryLength)
        return Presentation(summary: sum, pathLines: shown, overflowCount: overflow)
    }

    /// Extract real path list + summary from a decoded payload dictionary.
    ///
    /// Only known keys; only string / string-array values. Never invents paths
    /// from free-form prompt prose.
    public static func extract(fromPayload payload: [String: Any]) -> (paths: [String], summary: String?) {
        var paths: [String] = []
        var seen = Set<String>()

        func appendPath(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            guard !seen.contains(t) else { return }
            seen.insert(t)
            paths.append(t)
        }

        for key in pathListKeys {
            guard let value = payload[key] else { continue }
            if let arr = value as? [String] {
                for s in arr { appendPath(s) }
            } else if let arr = value as? [Any] {
                for el in arr {
                    if let s = el as? String { appendPath(s) }
                }
            } else if let s = value as? String {
                // Some clients ship a single path under a plural key.
                appendPath(s)
            }
        }

        for key in pathScalarKeys {
            guard let s = payload[key] as? String else { continue }
            appendPath(s)
        }

        var summary: String?
        for key in summaryKeys {
            guard let s = payload[key] as? String else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                summary = t
                break
            }
        }

        return (paths, summary)
    }

    /// Extract from a JSON object string. Non-object / invalid JSON → empty.
    public static func extract(fromJSON json: String) -> (paths: [String], summary: String?) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ([], nil)
        }
        return extract(fromPayload: obj)
    }

    /// Present directly from a payload dictionary.
    public static func present(
        payload: [String: Any],
        maxPaths: Int = defaultMaxPaths,
        maxPathLength: Int = defaultMaxPathLength,
        maxSummaryLength: Int = defaultMaxSummaryLength
    ) -> Presentation {
        let extracted = extract(fromPayload: payload)
        return present(
            paths: extracted.paths,
            summary: extracted.summary,
            maxPaths: maxPaths,
            maxPathLength: maxPathLength,
            maxSummaryLength: maxSummaryLength
        )
    }

    /// Present from JSON string (fail-closed empty when not a JSON object).
    public static func present(
        json: String,
        maxPaths: Int = defaultMaxPaths,
        maxPathLength: Int = defaultMaxPathLength,
        maxSummaryLength: Int = defaultMaxSummaryLength
    ) -> Presentation {
        let extracted = extract(fromJSON: json)
        return present(
            paths: extracted.paths,
            summary: extracted.summary,
            maxPaths: maxPaths,
            maxPathLength: maxPathLength,
            maxSummaryLength: maxSummaryLength
        )
    }

    // MARK: Helpers

    /// Drop blanks / whitespace-only; preserve order; de-dupe exact strings.
    public static func sanitizePaths(_ paths: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for p in paths {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            guard !seen.contains(t) else { continue }
            seen.insert(t)
            out.append(t)
        }
        return out
    }

    public static func clip(_ text: String, maxLength: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = Swift.max(1, maxLength)
        guard t.count > limit else { return t }
        return String(t.prefix(limit - 1)) + "…"
    }

    public static func clipOptional(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return clip(t, maxLength: maxLength)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
