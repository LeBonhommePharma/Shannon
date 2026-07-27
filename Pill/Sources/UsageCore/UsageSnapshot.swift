import Foundation

// MARK: - Provider-agnostic usage (ENH-014 / ENH-026)

/// One provider-reported quota / plan window (5h, 7d, monthly, or labeled other).
///
/// **Hard rule:** `usedPercent` is only set when the source itself reported a
/// percentage. Never derive a fraction from raw token totals.
public struct UsageWindow: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// ~5-hour rolling plan window (Codex primary `window_minutes` 300).
        case fiveHour
        /// ~7-day rolling plan window (Codex secondary `window_minutes` 10080).
        case sevenDay
        /// Monthly quota when the source labels it as such.
        case monthly
        /// Source-labeled non-standard window (e.g. ClaudeUsage extra window).
        case other
    }

    public var kind: Kind
    /// Optional provider label (plan name, model-scoped window). Never invented.
    public var label: String?
    /// 0…100 provider-reported used percent. Never computed from tokens.
    public var usedPercent: Double?
    public var resetsAt: Date?
    /// Provider-reported duration in minutes (e.g. Codex `window_minutes`).
    public var windowMinutes: Int?

    public init(
        kind: Kind,
        label: String? = nil,
        usedPercent: Double? = nil,
        resetsAt: Date? = nil,
        windowMinutes: Int? = nil
    ) {
        self.kind = kind
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = (trimmed?.isEmpty == false) ? trimmed : nil
        self.usedPercent = usedPercent.flatMap {
            $0.isFinite ? min(100, max(0, $0)) : nil
        }
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes.flatMap { $0 > 0 ? $0 : nil }
    }

    public var hasDisplayable: Bool {
        usedPercent != nil || label != nil
    }

    /// Compact chip fragment, e.g. `5h 26%`, `7d 94%`, `Fable 14%`.
    public var shortLabel: String? {
        guard let pct = usedPercent else { return nil }
        let tag: String
        switch kind {
        case .fiveHour: tag = "5h"
        case .sevenDay: tag = "7d"
        case .monthly: tag = "mo"
        case .other:
            if let label, !label.isEmpty {
                tag = String(label.prefix(8))
            } else {
                tag = "win"
            }
        }
        return String(format: "%@ %.0f%%", tag, pct)
    }
}

/// Optional usage metrics — only populated when a real local source provided them.
///
/// Shared by artifact readers, gate-facing UI, and session presenters so token
/// chips never invent numbers. Fail-closed: empty / invalid fields stay nil.
public struct UsageSnapshot: Sendable, Equatable {
    public var tokensUsed: Int?
    public var tokensLimit: Int?
    public var contextPercent: Double?
    public var planLabel: String?
    /// Provider-reported plan/quota windows (5h / 7d / monthly…). Empty when
    /// the source did not expose window fields (ENH-026).
    public var windows: [UsageWindow]

    public init(
        tokensUsed: Int? = nil,
        tokensLimit: Int? = nil,
        contextPercent: Double? = nil,
        planLabel: String? = nil,
        windows: [UsageWindow] = []
    ) {
        self.tokensUsed = tokensUsed.flatMap { $0 >= 0 ? $0 : nil }
        self.tokensLimit = tokensLimit.flatMap { $0 > 0 ? $0 : nil }
        self.contextPercent = contextPercent.flatMap {
            $0.isFinite ? min(100, max(0, $0)) : nil
        }
        let p = planLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.planLabel = (p?.isEmpty == false) ? p : nil
        // Drop windows that carry nothing displayable and no resets signal.
        self.windows = windows.filter {
            $0.usedPercent != nil || $0.label != nil || $0.resetsAt != nil || $0.windowMinutes != nil
        }
    }

    public var hasAny: Bool {
        tokensUsed != nil
            || tokensLimit != nil
            || contextPercent != nil
            || planLabel != nil
            || !windows.isEmpty
    }

    /// Multi-window chip fragment (≤2 windows), e.g. `5h 26% · 7d 94%`.
    public var windowsLabel: String? {
        let parts = windows.compactMap(\.shortLabel)
        guard !parts.isEmpty else { return nil }
        return parts.prefix(2).joined(separator: " · ")
    }

    public var shortLabel: String? {
        // Prefer honest multi-window plan gauges when the source provided them.
        if let w = windowsLabel {
            return w
        }
        if let pct = contextPercent {
            return String(format: "ctx %.0f%%", pct)
        }
        if let u = tokensUsed, let lim = tokensLimit, lim > 0 {
            return "\(u)/\(lim)"
        }
        if let u = tokensUsed {
            return "\(u) tok"
        }
        if let plan = planLabel {
            return plan
        }
        return nil
    }
}

/// Build usage from known token / window fields only (fail-closed).
public enum UsageBridge {
    /// Map optional input/output token counts to a usage snapshot.
    ///
    /// - Sums input+output when both present and positive
    /// - Single-sided counts when only one side is present and > 0
    /// - Returns nil when nothing usable (never invents)
    /// - **Never** invents windows or quota percentages from tokens
    public static func fromTokens(input: Int?, output: Int?) -> UsageSnapshot? {
        snapshot(tokensIn: input, tokensOut: output)
    }

    /// Provider-agnostic snapshot from real fields only.
    ///
    /// Windows must already be provider-reported — this never derives a
    /// used-percent from `tokensIn`/`tokensOut`.
    public static func snapshot(
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        windows: [UsageWindow] = [],
        planLabel: String? = nil,
        contextPercent: Double? = nil,
        tokensLimit: Int? = nil
    ) -> UsageSnapshot? {
        let used: Int? = {
            switch (tokensIn, tokensOut) {
            case let (i?, o?):
                let sum = i + o
                if sum > 0 { return sum }
                return i > 0 ? i : nil
            case let (i?, nil):
                return i > 0 ? i : nil
            case let (nil, o?):
                return o > 0 ? o : nil
            case (nil, nil):
                return nil
            }
        }()
        let snap = UsageSnapshot(
            tokensUsed: used,
            tokensLimit: tokensLimit,
            contextPercent: contextPercent,
            planLabel: planLabel,
            windows: windows
        )
        return snap.hasAny ? snap : nil
    }

    // MARK: - Codex rate_limits (on-disk token_count events)

    /// Parse Codex `rate_limits` object attached to `token_count` events.
    ///
    /// Observed shape (real rollouts):
    /// ```
    /// "rate_limits": {
    ///   "primary":   {"used_percent": 26.0, "window_minutes": 300,   "resets_at": <unix>},
    ///   "secondary": {"used_percent": 94.0, "window_minutes": 10080, "resets_at": <unix>},
    ///   "plan_type": "plus"
    /// }
    /// ```
    /// Returns empty when null/missing/malformed — never invents percentages.
    public static func windowsFromCodexRateLimits(_ rateLimits: [String: Any]?) -> [UsageWindow] {
        guard let rateLimits else { return [] }
        var out: [UsageWindow] = []
        if let primary = rateLimits["primary"] as? [String: Any],
           let w = windowFromCodexSlot(primary, preferredKind: .fiveHour) {
            out.append(w)
        }
        if let secondary = rateLimits["secondary"] as? [String: Any],
           let w = windowFromCodexSlot(secondary, preferredKind: .sevenDay) {
            out.append(w)
        }
        return out
    }

    /// Plan label from Codex `rate_limits.plan_type` when present and non-empty.
    public static func planLabelFromCodexRateLimits(_ rateLimits: [String: Any]?) -> String? {
        guard let raw = rateLimits?["plan_type"] as? String else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: - ClaudeUsage-style single window (local API / cache)

    /// Build one window from a provider-reported percent + optional reset.
    ///
    /// Matches ClaudeUsage local API fields (`percentUsed`, `resetsAt`) and
    /// similar shapes. Returns nil when no usable percent (never invents 0%).
    public static func windowFromProvider(
        kind: UsageWindow.Kind,
        percentUsed: Double?,
        resetsAt: Date? = nil,
        label: String? = nil,
        windowMinutes: Int? = nil
    ) -> UsageWindow? {
        let pct = percentUsed.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        // Require at least a percent or a label+reset so empty shells stay out.
        guard pct != nil || (label?.isEmpty == false && resetsAt != nil) else {
            return nil
        }
        let w = UsageWindow(
            kind: kind,
            label: label,
            usedPercent: pct,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes
        )
        return w.hasDisplayable || w.resetsAt != nil ? w : nil
    }

    /// Map provider `window_minutes` to a kind when exact known durations match.
    ///
    /// - 300 → fiveHour
    /// - 10080 → sevenDay
    /// - 43200 → monthly
    /// - else → preferredKind (caller slot default) or `.other`
    public static func kind(
        fromWindowMinutes minutes: Int?,
        preferred: UsageWindow.Kind? = nil
    ) -> UsageWindow.Kind {
        guard let m = minutes, m > 0 else {
            return preferred ?? .other
        }
        switch m {
        case 300: return .fiveHour
        case 10_080: return .sevenDay
        case 43_200: return .monthly
        default:
            return preferred ?? .other
        }
    }

    // MARK: - Internals

    private static func windowFromCodexSlot(
        _ slot: [String: Any],
        preferredKind: UsageWindow.Kind
    ) -> UsageWindow? {
        let minutes = positiveInt(slot["window_minutes"])
        let kind = kind(fromWindowMinutes: minutes, preferred: preferredKind)
        let pct = finiteDouble(slot["used_percent"])
        let resets = unixDate(slot["resets_at"])
        // Need at least a provider percent (or minutes+reset) to surface.
        guard pct != nil || (minutes != nil && resets != nil) else { return nil }
        return UsageWindow(
            kind: kind,
            label: nil,
            usedPercent: pct,
            resetsAt: resets,
            windowMinutes: minutes
        )
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        if let d = value as? Double, d.isFinite {
            return min(100, max(0, d))
        }
        if let i = value as? Int {
            return min(100, max(0, Double(i)))
        }
        if let n = value as? NSNumber {
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            guard d.isFinite else { return nil }
            return min(100, max(0, d))
        }
        return nil
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        if let i = value as? Int {
            return i > 0 ? i : nil
        }
        if let n = value as? NSNumber {
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            guard d > 0, d == floor(d), d <= Double(Int.max) else { return nil }
            return n.intValue
        }
        if let d = value as? Double {
            guard d > 0, d == floor(d), d <= Double(Int.max) else { return nil }
            return Int(d)
        }
        return nil
    }

    private static func unixDate(_ value: Any?) -> Date? {
        if let i = value as? Int {
            // Guard absurd values (seconds since 1970).
            guard i > 1_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(i))
        }
        if let d = value as? Double {
            guard d > 1_000_000_000, d.isFinite else { return nil }
            return Date(timeIntervalSince1970: d)
        }
        if let n = value as? NSNumber {
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            guard d > 1_000_000_000, d.isFinite else { return nil }
            return Date(timeIntervalSince1970: d)
        }
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        return nil
    }
}

/// Module identity (replaces empty UsageCoreStub).
public enum UsageCore {
    public static let moduleName = "UsageCore"
}
