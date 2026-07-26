import Foundation

// MARK: - Provider-agnostic usage (ENH-014)

/// Optional usage metrics — only populated when a real local source provided them.
///
/// Shared by artifact readers, gate-facing UI, and session presenters so token
/// chips never invent numbers. Fail-closed: empty / invalid fields stay nil.
public struct UsageSnapshot: Sendable, Equatable {
    public var tokensUsed: Int?
    public var tokensLimit: Int?
    public var contextPercent: Double?
    public var planLabel: String?

    public init(
        tokensUsed: Int? = nil,
        tokensLimit: Int? = nil,
        contextPercent: Double? = nil,
        planLabel: String? = nil
    ) {
        self.tokensUsed = tokensUsed.flatMap { $0 >= 0 ? $0 : nil }
        self.tokensLimit = tokensLimit.flatMap { $0 > 0 ? $0 : nil }
        self.contextPercent = contextPercent.flatMap {
            $0.isFinite ? min(100, max(0, $0)) : nil
        }
        let p = planLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.planLabel = (p?.isEmpty == false) ? p : nil
    }

    public var hasAny: Bool {
        tokensUsed != nil || tokensLimit != nil || contextPercent != nil || planLabel != nil
    }

    public var shortLabel: String? {
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

/// Build usage from known token fields only (fail-closed).
public enum UsageBridge {
    /// Map optional input/output token counts to a usage snapshot.
    ///
    /// - Sums input+output when both present and positive
    /// - Single-sided counts when only one side is present and > 0
    /// - Returns nil when nothing usable (never invents)
    public static func fromTokens(input: Int?, output: Int?) -> UsageSnapshot? {
        guard input != nil || output != nil else { return nil }
        let used: Int?
        switch (input, output) {
        case let (i?, o?):
            let sum = i + o
            used = sum > 0 ? sum : (i > 0 ? i : nil)
        case let (i?, nil):
            used = i > 0 ? i : nil
        case let (nil, o?):
            used = o > 0 ? o : nil
        case (nil, nil):
            used = nil
        }
        let snap = UsageSnapshot(tokensUsed: used)
        return snap.hasAny ? snap : nil
    }
}

/// Module identity (replaces empty UsageCoreStub).
public enum UsageCore {
    public static let moduleName = "UsageCore"
}
