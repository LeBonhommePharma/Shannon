import Foundation

// MARK: - Thermodynamic referee HUD (pure)

/// One-tap Handrail actions exposed on a measured collapse island.
///
/// These IDs are protocol-level; UI buttons map 1:1. Synthetic / unmeasured
/// collapse never surfaces them (see ``CollapseAttentionLogic``).
public enum HandrailAction: String, CaseIterable, Sendable, Equatable, Identifiable {
    case log = "LOG"
    case alert = "ALERT"
    case throttle = "THROTTLE"
    case kill = "KILL"
    case webhook = "WEBHOOK"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .log: return "doc.text"
        case .alert: return "bell.badge"
        case .throttle: return "gauge.with.dots.needle.33percent"
        case .kill: return "xmark.octagon"
        case .webhook: return "link"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .log: return "Log collapse event"
        case .alert: return "Raise alert"
        case .throttle: return "Throttle agent"
        case .kill: return "Kill agent process"
        case .webhook: return "Fire webhook"
        }
    }

    /// Canonical ordered set for the collapse island.
    public static let collapseSet: [HandrailAction] = [
        .log, .alert, .throttle, .kill, .webhook,
    ]
}

/// Attention level for the notch island entropy surface.
public enum CollapseAttention: String, Sendable, Equatable {
    /// No measured signal worth elevating chrome.
    case idle
    /// Significant measured ΔH but not collapsed.
    case watch
    /// Measured collapse — auto-expand / Handrail surface.
    case alarm
}

/// Pure decision for expand-on-collapse and Handrail visibility.
public struct CollapseAttentionDecision: Sendable, Equatable {
    public var state: CollapseAttention
    /// True only for measured collapse (never synthetic).
    public var shouldAutoExpand: Bool
    /// Non-empty only when `state == .alarm` and provenance is measured.
    public var handrailActions: [HandrailAction]
    public var agentLabel: String?
    public var entropy: Double?
    public var deltaH: Double?
    public var zScore: Double?
    /// Optional recent token/context snippet — never invented when absent.
    public var tokenSnippet: String?

    public init(
        state: CollapseAttention,
        shouldAutoExpand: Bool,
        handrailActions: [HandrailAction] = [],
        agentLabel: String? = nil,
        entropy: Double? = nil,
        deltaH: Double? = nil,
        zScore: Double? = nil,
        tokenSnippet: String? = nil
    ) {
        self.state = state
        self.shouldAutoExpand = shouldAutoExpand
        self.handrailActions = handrailActions
        self.agentLabel = agentLabel
        self.entropy = entropy
        self.deltaH = deltaH
        self.zScore = zScore
        self.tokenSnippet = tokenSnippet
    }
}

/// Collapse attention + Handrail mapping — pure, fail-closed.
public enum CollapseAttentionLogic {
    /// Absolute |ΔH| that elevates to `.watch` when measured and not collapsed.
    public static let watchAbsDeltaH: Double = 1.5

    /// Decide attention from a fleet reading + optional live bridge status.
    ///
    /// - Parameters:
    ///   - reading: provenance-resolved fleet reading (must already fail-closed).
    ///   - status: optional raw bridge status for agent label / z-score / snippet.
    ///   - tokenSnippet: optional context; blank → nil.
    public static func decide(
        reading: EntropyReading,
        status: ShannonStatus? = nil,
        tokenSnippet: String? = nil
    ) -> CollapseAttentionDecision {
        let snippet = Self.normalizedSnippet(tokenSnippet)
        // Measured collapse only — synthetic never alarms.
        if reading.collapsed == true, reading.isMeasured {
            let m = reading.measurement
            return CollapseAttentionDecision(
                state: .alarm,
                shouldAutoExpand: true,
                handrailActions: HandrailAction.collapseSet,
                agentLabel: status?.agent ?? m?.source.agentId,
                entropy: m?.bits ?? status?.entropy,
                deltaH: m?.deltaH ?? status?.deltaH,
                zScore: status?.zScore,
                tokenSnippet: snippet
            )
        }
        // Significant measured ΔH → watch (no Handrail, no auto-expand).
        if reading.isMeasured,
           let d = reading.measurement?.deltaH ?? status?.deltaH,
           d.isFinite,
           abs(d) >= watchAbsDeltaH
        {
            return CollapseAttentionDecision(
                state: .watch,
                shouldAutoExpand: false,
                handrailActions: [],
                agentLabel: status?.agent,
                entropy: reading.measurement?.bits ?? status?.entropy,
                deltaH: d,
                zScore: status?.zScore,
                tokenSnippet: snippet
            )
        }
        return CollapseAttentionDecision(state: .idle, shouldAutoExpand: false)
    }

    /// Handrail actions only for measured collapse (never synthetic / idle).
    public static func handrailActions(
        measuredCollapsed: Bool
    ) -> [HandrailAction] {
        measuredCollapsed ? HandrailAction.collapseSet : []
    }

    private static func normalizedSnippet(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Entropy rail series (thermodynamic color map)

/// One sample on the live thermodynamic rail / sparkline.
public struct EntropyRailPoint: Sendable, Equatable {
    public var h: Double
    public var deltaH: Double?
    public var zScore: Double?
    public var color: EntropyColorRGB
    /// 0…1 fill for bar geometry (token domain polarity).
    public var fill: Double

    public init(
        h: Double,
        deltaH: Double? = nil,
        zScore: Double? = nil,
        color: EntropyColorRGB,
        fill: Double
    ) {
        self.h = h
        self.deltaH = deltaH
        self.zScore = zScore
        self.color = color
        self.fill = min(1, max(0, fill))
    }
}

/// Sliding-window H series → rail points with cool→warm→red lock-in color map.
public enum EntropyRailLogic {
    public static let defaultCapacity = 48

    /// Map a pure H series into rail points (token-distribution polarity).
    /// Empty / non-finite inputs yield empty (never invent samples).
    public static func points(
        hSeries: [Double],
        deltaHSeries: [Double]? = nil,
        zScoreSeries: [Double]? = nil,
        domain: EntropyDomain = .tokenDistribution,
        isCurrent: Bool = true
    ) -> [EntropyRailPoint] {
        guard !hSeries.isEmpty else { return [] }
        return hSeries.enumerated().compactMap { i, h in
            guard h.isFinite else { return nil }
            let d: Double? = {
                guard let series = deltaHSeries, i < series.count else { return nil }
                let v = series[i]
                return v.isFinite ? v : nil
            }()
            let z: Double? = {
                guard let series = zScoreSeries, i < series.count else { return nil }
                let v = series[i]
                return v.isFinite ? v : nil
            }()
            let color = EntropyGauge.colorRGB(
                bits: h,
                domain: domain,
                isCurrent: isCurrent
            )
            let fill = EntropyGauge.fillFraction(bits: h, domain: domain)
            return EntropyRailPoint(h: h, deltaH: d, zScore: z, color: color, fill: fill)
        }
    }

    /// Append one measured H into a bounded ring (oldest drop). Non-finite refused.
    public static func append(
        history: [Double],
        entropy: Double,
        capacity: Int = defaultCapacity
    ) -> [Double] {
        guard entropy.isFinite else { return history }
        let cap = max(1, capacity)
        var next = history
        next.append(entropy)
        if next.count > cap {
            next.removeFirst(next.count - cap)
        }
        return next
    }

    /// Latest rail point summary for badges ("H 8.4 ▽2.1 z−3.2").
    public static func summaryLabel(
        h: Double?,
        deltaH: Double?,
        zScore: Double?
    ) -> String? {
        guard let h, h.isFinite else { return nil }
        var parts = [String(format: "H %.1f", h)]
        if let d = deltaH, d.isFinite, d < 0 {
            parts.append(String(format: "▽%.1f", abs(d)))
        }
        if let z = zScore, z.isFinite {
            parts.append(String(format: "z%+.1f", z))
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Bridge push significance (pure)

/// Pure rules for whether a status frame is a "push-worthy" significant event.
public enum BridgePushLogic {
    /// |ΔH| between consecutive measured frames that counts as significant.
    public static let significantAbsDeltaH: Double = 0.75

    /// Whether `next` should drive UI without waiting for the next poll tick.
    ///
    /// Always true for measured collapse transitions; true when |ΔH| jump or
    /// absolute ΔH crosses threshold; never for synthetic backends.
    public static func isSignificantEvent(
        previous: ShannonStatus?,
        next: ShannonStatus
    ) -> Bool {
        guard !next.isSynthetic else { return false }
        if next.collapsed {
            // Rising edge or ongoing measured collapse is always significant.
            if previous?.collapsed != true { return true }
            return true
        }
        if abs(next.deltaH) >= significantAbsDeltaH { return true }
        if let prev = previous, !prev.isSynthetic {
            if abs(next.entropy - prev.entropy) >= significantAbsDeltaH { return true }
            if prev.collapsed && !next.collapsed { return true }
        }
        return false
    }

    /// Whether a decoded frame should replace published bridge status.
    public static func shouldPublishStatus(
        previous: ShannonStatus?,
        next: ShannonStatus?
    ) -> Bool {
        previous != next
    }
}

// MARK: - Handrail execution mapping (pure)

/// Maps a Handrail tap to a durable command string for the hub / gate bridge.
///
/// Does not perform side effects — callers (UI) dispatch the command.
public enum HandrailDispatch {
    public static func command(
        action: HandrailAction,
        agentId: String?,
        entropy: Double?,
        deltaH: Double?
    ) -> String {
        let agent = (agentId?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "unknown"
        let h = entropy.map { String(format: "%.3f", $0) } ?? "na"
        let d = deltaH.map { String(format: "%.3f", $0) } ?? "na"
        return "handrail.\(action.rawValue.lowercased()) agent=\(agent) H=\(h) dH=\(d)"
    }

    /// Whether the action is allowed for this attention decision (measured only).
    public static func isAllowed(
        action: HandrailAction,
        decision: CollapseAttentionDecision
    ) -> Bool {
        decision.state == .alarm && decision.handrailActions.contains(action)
    }
}
