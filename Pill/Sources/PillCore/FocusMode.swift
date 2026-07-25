import Foundation

// MARK: - Focus / Do Not Disturb (BLOCKED.md §2 best-effort)

/// Best-effort Focus state. Schema is undocumented and changes across releases —
/// always fail closed to `.unknown`.
public enum FocusModeState: String, Sendable, Equatable {
    case off
    case on
    case unknown

    public var shortLabel: String {
        switch self {
        case .off: return "Focus: off"
        case .on: return "Focus: on"
        case .unknown: return "Focus: unknown"
        }
    }
}

/// Pure parse helpers for Focus/DND store files (unit-tested without TCC).
public enum FocusModeLogic {
    /// Parse `Assertions.json`-style content: non-empty active assertions → on.
    ///
    /// Accepts:
    /// - `{ "data": [ ... ] }` or `{ "data": { ... } }`
    /// - top-level array
    /// - `{ "activeModeAssertion": ... }` / keys containing "assertion"
    public static func parseAssertionsJSON(_ data: Data) -> FocusModeState {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return .unknown
        }
        if let arr = obj as? [Any] {
            return arr.isEmpty ? .off : .on
        }
        guard let dict = obj as? [String: Any] else { return .unknown }

        // Common shapes observed across releases.
        if let dataVal = dict["data"] {
            if let arr = dataVal as? [Any] {
                return arr.isEmpty ? .off : .on
            }
            if let d = dataVal as? [String: Any] {
                // Nested store: look for non-empty collections under known keys.
                for key in ["assertions", "activeAssertions", "store"] {
                    if let a = d[key] as? [Any] {
                        return a.isEmpty ? .off : .on
                    }
                    if let m = d[key] as? [String: Any], !m.isEmpty {
                        return .on
                    }
                }
                return d.isEmpty ? .off : .on
            }
        }
        if dict["activeModeAssertion"] != nil { return .on }
        if let assertions = dict["assertions"] as? [Any] {
            return assertions.isEmpty ? .off : .on
        }
        // Unknown schema — do not invent off/on.
        return .unknown
    }

    /// Mode name from ModeConfigurations when present (best-effort).
    public static func parseActiveModeName(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Several historical keys.
        for key in ["activeModeIdentifier", "modeIdentifier", "selectedMode"] {
            if let s = obj[key] as? String, !s.isEmpty { return s }
        }
        if let dataObj = obj["data"] as? [String: Any] {
            for key in ["activeModeIdentifier", "modeIdentifier"] {
                if let s = dataObj[key] as? String, !s.isEmpty { return s }
            }
        }
        return nil
    }
}

/// Live reader — best-effort file open under the user's Library.
public enum FocusModeReader {
    public static var assertionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
    }

    public static var modesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/ModeConfigurations.json")
    }

    public static func read(
        assertionsURL: URL = assertionsURL,
        modesURL: URL = modesURL,
        fileManager: FileManager = .default
    ) -> (state: FocusModeState, modeName: String?) {
        guard fileManager.fileExists(atPath: assertionsURL.path),
              let data = try? Data(contentsOf: assertionsURL)
        else {
            return (.unknown, nil)
        }
        let state = FocusModeLogic.parseAssertionsJSON(data)
        var name: String?
        if fileManager.fileExists(atPath: modesURL.path),
           let md = try? Data(contentsOf: modesURL) {
            name = FocusModeLogic.parseActiveModeName(md)
        }
        return (state, name)
    }
}

/// Lightweight poller for the menu bar popover.
@MainActor
public final class FocusModeMonitor: ObservableObject {
    @Published public private(set) var state: FocusModeState = .unknown
    @Published public private(set) var modeName: String?

    private var timer: Timer?

    public init() {}

    public func start(interval: TimeInterval = 8.0) {
        refresh()
        let t = Timer(timeInterval: max(4, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = interval * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        Task.detached(priority: .utility) {
            let r = FocusModeReader.read()
            await MainActor.run { [weak self] in
                self?.state = r.state
                self?.modeName = r.modeName
            }
        }
    }

    public var shortLabel: String {
        if let modeName, state == .on {
            return "Focus: \(modeName)"
        }
        return state.shortLabel
    }
}
