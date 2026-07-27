import Foundation

// MARK: - Where a number came from

// MARK: - Measurement domain (polarity)

/// What physical quantity an H value represents.
///
/// The product historically painted one number under three incompatible
/// meanings. Token-distribution H collapses when **low** (eval-awareness
/// proxy). Gate message H is a verbosity/diversity score that the gate
/// escalates when **high**. Mixing them under one "H" badge inverted the
/// safety story: a short status looked "collapsed" while a long approval
/// prompt looked "healthy" even as the gate blocked it.
public enum EntropyDomain: String, Sendable, Equatable, CaseIterable {
    /// Next-token distribution entropy from the library detector (bridge).
    /// Danger direction: **low** H / negative ΔH.
    case tokenDistribution
    /// Gate-computed message content entropy (`decision.computed_H`).
    /// Danger direction: **high** H (verbosity / structural diversity).
    case messageContent

    /// Compact badge prefix for gauges.
    public var badge: String {
        switch self {
        case .tokenDistribution: return "H"
        case .messageContent: return "H_msg"
        }
    }

    public var shortName: String {
        switch self {
        case .tokenDistribution: return "token entropy"
        case .messageContent: return "message score"
        }
    }
}

/// Attribution for one entropy value. There is no "anonymous" case: every
/// `EntropyMeasurement` names either a live detector socket or a specific agent
/// row in the hub DB, so a bare bit-count with nothing behind it cannot be
/// constructed in the first place.
public enum EntropySource: Sendable, Equatable {
    /// A live detector reached over `shannon.pill_bridge`, tagged with the
    /// backend string that detector reported.
    case bridge(backend: String)
    /// Gate-computed **message** entropy (`decision.computed_H`) for one agent,
    /// read back from `agents.entropy_score` in `agent_hub.db`.
    /// This is **not** token-distribution collapse H — see `domain`.
    case gate(agentId: String, presence: AgentPresence)

    /// Physical meaning of this source's bits. Fixed by construction.
    public var domain: EntropyDomain {
        switch self {
        case .bridge: return .tokenDistribution
        case .gate: return .messageContent
        }
    }

    /// Short attribution for a tooltip or log line.
    public var label: String {
        switch self {
        case .bridge(let backend):
            let b = backend.trimmingCharacters(in: .whitespaces)
            return "bridge:\(b.isEmpty ? "?" : b) [\(domain.shortName)]"
        case .gate(let agentId, let presence):
            return "gate:\(agentId) (\(presence.label)) [\(domain.shortName)]"
        }
    }

    /// Gate agent id when this source is agent-scoped; `nil` for a bridge stream.
    public var agentId: String? {
        if case .gate(let agentId, _) = self { return agentId }
        return nil
    }

    /// Whether this source is *capable* of producing a current reading.
    ///
    /// A synthetic bridge backend never is (see `ShannonStatus.syntheticBackends`),
    /// and neither is an agent the gate knows has hung up: its last H is a real
    /// measurement of a conversation that has ended, not of anything happening
    /// now. Freshness is checked separately — this is the prior question of
    /// whether freshness could even mean anything.
    public var canBeCurrent: Bool {
        switch self {
        case .bridge(let backend):
            return !ShannonStatus.syntheticBackends.contains(
                backend.trimmingCharacters(in: .whitespaces).lowercased()
            )
        case .gate(_, let presence):
            return presence == .live
        }
    }
}

// MARK: - Policy

/// Operator-tunable thresholds for the entropy readout.
///
/// Every knob follows the `SHANNON_*` convention, has a safe default, and is
/// clamped so a typo cannot widen the gate. **Nothing here can turn an absent
/// detector into a healthy one** — that is the defect this module exists to
/// prevent, and it is not configurable.
///
/// | Variable | Default | Effect |
/// |---|---|---|
/// | `SHANNON_PILL_ENTROPY_MAX_AGE` | `120` (s) | A gate reading older than this is `.stale`, never `.measured`. Raise it if your agents are chatty but bursty; lower it if you want the pill to admit ignorance sooner. Clamped to `1 ... 86400`. |
/// | `SHANNON_PILL_ENTROPY_WARN_BITS` | `5.0` | Domain-aware threshold. For **token** H (bridge): bits *below* this → `.watch`. For **message** H (gate): bits *at or above* this → `.watch` (matches gate hard-block polarity). Clamped to `0 ... maxBits`. |
/// | `SHANNON_PILL_ENTROPY_MAX_BITS` | `64.0` | Values above this are rejected as corrupt rather than displayed. Clamped to `1 ... 1024`. |
/// | `SHANNON_PILL_ENTROPY_MODE` | `enforce` | `observe` keeps rendering a *stale* number (still labelled stale, still `.unknown` verdict) so a deployment can measure how often staleness happens before hiding numbers. `absent` shows nothing in either mode — there is no number to show. |
///
/// Any unparseable, out-of-range, or unrecognised value falls back to the
/// **safe default**, never to a permissive one. `SHANNON_PILL_ENTROPY_MODE=yolo`
/// is `enforce`.
public struct EntropyPolicy: Sendable, Equatable {

    /// What to do with a reading that is real but no longer current.
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        /// Stale numbers are withheld from numeric display. Default.
        case enforce
        /// Stale numbers are still shown (labelled stale) so the impact of
        /// enforcing can be measured first. Never applies to `.absent`.
        case observe
    }

    public var maxAge: TimeInterval
    public var warnBits: Double
    public var maxBits: Double
    public var mode: Mode

    public static let defaultMaxAge: TimeInterval = 120
    public static let minMaxAge: TimeInterval = 1
    public static let maxMaxAge: TimeInterval = 24 * 3600
    public static let defaultWarnBits: Double = 5.0
    public static let defaultMaxBits: Double = 64
    public static let minMaxBits: Double = 1
    public static let maxMaxBits: Double = 1024

    /// How far a measurement timestamp may sit in the future before we treat it
    /// as corrupt. A clock-skewed row must not be able to make a 40-minute-old
    /// reading look current, so anything beyond this is dropped entirely.
    public static let clockSkewTolerance: TimeInterval = 5

    public init(
        maxAge: TimeInterval = EntropyPolicy.defaultMaxAge,
        warnBits: Double = EntropyPolicy.defaultWarnBits,
        maxBits: Double = EntropyPolicy.defaultMaxBits,
        mode: Mode = .enforce
    ) {
        self.maxAge = Self.clamp(maxAge, Self.minMaxAge, Self.maxMaxAge, Self.defaultMaxAge)
        self.maxBits = Self.clamp(maxBits, Self.minMaxBits, Self.maxMaxBits, Self.defaultMaxBits)
        self.warnBits = Self.clamp(warnBits, 0, self.maxBits, min(Self.defaultWarnBits, self.maxBits))
        self.mode = mode
    }

    private static func clamp(
        _ value: Double, _ low: Double, _ high: Double, _ fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, low), high)
    }

    /// Resolve from an environment dictionary. Pure, so tests never touch the
    /// real process environment.
    public static func fromEnvironment(_ env: [String: String]) -> EntropyPolicy {
        func number(_ key: String, _ fallback: Double) -> Double {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                  let value = Double(raw), value.isFinite
            else { return fallback }
            return value
        }
        let modeRaw = (env["SHANNON_PILL_ENTROPY_MODE"] ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        return EntropyPolicy(
            maxAge: number("SHANNON_PILL_ENTROPY_MAX_AGE", defaultMaxAge),
            warnBits: number("SHANNON_PILL_ENTROPY_WARN_BITS", defaultWarnBits),
            maxBits: number("SHANNON_PILL_ENTROPY_MAX_BITS", defaultMaxBits),
            // Unrecognised → enforce. The permissive mode is never the fallback.
            mode: Mode(rawValue: modeRaw) ?? .enforce
        )
    }

    /// Process-wide policy, read once from the environment at first use.
    public static let current = EntropyPolicy.fromEnvironment(ProcessInfo.processInfo.environment)
}

// MARK: - A measured value

/// One entropy value that something actually measured, inseparable from its
/// attribution and its timestamp.
///
/// The initialiser is failable and is the **only** way to make one. A value
/// that is not finite, not positive, larger than `policy.maxBits`, or stamped
/// in the future is refused rather than clamped — a monitor that displays a
/// corrupt number is worse than one that admits it has nothing.
///
/// Note `bits > 0` specifically: `agents.entropy_score` is `REAL DEFAULT 0.0`,
/// so a row the gate has never scored is indistinguishable on disk from a
/// genuine reading of exactly zero. Both are refused. Zero bits would render as
/// total collapse, which is a false alarm, and a false alarm is how a monitor
/// gets switched off.
///
/// **Self-reports never construct one of these.** An agent's `shannon_H` claim
/// is attestation input for the gate ledger, not a measurement. Use
/// `EntropyIntegrity.measurementFromSelfReport` (always `nil`) or
/// `EntropyIntegrity.accept` (trusted sources only).
public struct EntropyMeasurement: Sendable, Equatable {
    /// Shannon entropy in bits. Always accompanied by `source` and `measuredAt`.
    public let bits: Double
    /// Change in H, when the producer reported one. `nil` means "not reported",
    /// never "zero".
    public let deltaH: Double?
    /// Collapse as asserted by the producer that measured this. `nil` means the
    /// producer did not say — which is *not* the same as `false`.
    public let collapsed: Bool?
    public let source: EntropySource
    /// When the measurement was taken, not when it was read.
    public let measuredAt: Date

    /// - Parameters:
    ///   - now: the caller's clock, used to refuse future-dated rows. Passed in
    ///     rather than read here so construction is deterministic under test.
    public init?(
        bits: Double,
        deltaH: Double? = nil,
        collapsed: Bool? = nil,
        source: EntropySource,
        measuredAt: Date,
        now: Date,
        policy: EntropyPolicy = .current
    ) {
        guard bits.isFinite, bits > 0, bits <= policy.maxBits else { return nil }
        if let deltaH, !deltaH.isFinite { return nil }
        guard measuredAt.timeIntervalSince1970 > 0 else { return nil }
        guard now.timeIntervalSince(measuredAt) >= -EntropyPolicy.clockSkewTolerance else {
            return nil
        }
        self.bits = bits
        self.deltaH = deltaH
        self.collapsed = collapsed
        self.source = source
        self.measuredAt = measuredAt
    }

    public func age(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(measuredAt))
    }
}

// MARK: - Why there is no value

/// Why the pill has nothing to show. Carries **no** number by construction, so
/// no consumer can accidentally render an absent reading as a value.
public enum EntropyAbsence: Sendable, Equatable {
    /// No detector socket and no scored agent in the hub DB.
    case noDetector
    /// The hub DB itself could not be opened, so we do not even know whether
    /// anything is being measured.
    case gateUnavailable
    /// A producer is connected but serving fabricated numbers (`--demo`, the
    /// local placeholder, or a detector that would not name its backend).
    case syntheticSource(String)
    /// A producer served a number that failed validation.
    case rejected(String)

    /// Plain-language line an operator can act on.
    public var reason: String {
        switch self {
        case .noDetector:
            return "No detector is attached and no agent has been scored by the gate. "
                + "Collapse detection is NOT running."
        case .gateUnavailable:
            return "The hub database could not be read, so no agent telemetry is "
                + "available. Collapse detection status is UNKNOWN."
        case .syntheticSource(let backend):
            return "The connected source '\(backend.isEmpty ? "?" : backend)' fabricates "
                + "its numbers, so nothing is being measured. Collapse detection is NOT running."
        case .rejected(let why):
            return "The reading was refused: \(why). Nothing is being displayed rather "
                + "than showing a value that failed validation."
        }
    }
}

// MARK: - Verdict

/// The safety judgement. `.healthy` is reachable **only** from `.measured`; no
/// policy, mode or input can produce it from a stale or absent reading.
public enum EntropyVerdict: String, Sendable, Equatable, CaseIterable {
    case healthy
    case watch
    case collapsed
    case unknown

    public var isHealthy: Bool { self == .healthy }

    public var label: String {
        switch self {
        case .healthy: return "healthy"
        case .watch: return "approaching threshold"
        case .collapsed: return "collapse detected"
        case .unknown: return "unknown — not measured"
        }
    }

    /// Domain-aware operator label. Message scores never claim "collapse".
    public func label(for domain: EntropyDomain) -> String {
        switch (self, domain) {
        case (.watch, .tokenDistribution): return "approaching collapse threshold"
        case (.watch, .messageContent): return "elevated message diversity"
        case (.healthy, .messageContent): return "message score normal"
        case (.healthy, .tokenDistribution): return "healthy"
        case (.collapsed, .tokenDistribution): return "collapse detected"
        case (.collapsed, .messageContent): return "elevated message diversity"
        case (.unknown, _): return "unknown — not measured"
        }
    }
}

// MARK: - Renderable value

/// A number plus everything needed to render it honestly. Returned only by
/// `EntropyReading.display(at:policy:)`, which is the sole path from a reading
/// to a bare `Double` intended for the screen.
public struct EntropyDisplay: Sendable, Equatable {
    public let bits: Double
    public let source: EntropySource
    public let age: TimeInterval
    /// False when the underlying measurement is older than the freshness budget.
    public let isCurrent: Bool

    /// Domain of the underlying measurement (`H` vs `H_msg`).
    public var domain: EntropyDomain { source.domain }

    /// `H` / `H_msg` for a current reading, with `⌛` when shown under observe mode.
    public var badge: String {
        let base = domain.badge
        return isCurrent ? base : "\(base)⌛"
    }

    /// Compact monospaced label for a gauge/badge: `H 7.59` or `H_msg⌛ 2.86`.
    public var shortLabel: String {
        String(format: "%@ %.2f", badge, bits)
    }

    /// Horizontal fill fraction for a progress rail (0…1), clamped so a zero
    /// reading never vanishes and a large H never overflows the track.
    /// Domain-aware: uses token fullScale 12 or message fullScale ~8 by default.
    public func fillFraction(fullScale: Double? = nil) -> Double {
        let scale = fullScale ?? EntropyGauge.fullScale(for: domain)
        return EntropyGauge.fillFraction(bits: bits, fullScale: scale, domain: domain)
    }

    /// Continuous multi-stop gauge color — domain polarity + stale desaturation.
    public func gaugeColorRGB(fullScale: Double? = nil) -> EntropyColorRGB {
        let scale = fullScale ?? EntropyGauge.fullScale(for: domain)
        return EntropyGauge.colorRGB(
            bits: bits,
            fullScale: scale,
            domain: domain,
            isCurrent: isCurrent
        )
    }
}

// MARK: - Gauge geometry + continuous color (pure)

/// Linear sRGB triple in 0…1. UI maps this to `Color` / `NSColor`; tests assert
/// intermediate hues without importing SwiftUI.
public struct EntropyColorRGB: Sendable, Equatable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = min(1, max(0, r))
        self.g = min(1, max(0, g))
        self.b = min(1, max(0, b))
    }

    /// Euclidean distance in RGB cube (for continuity tests).
    public func distance(to other: EntropyColorRGB) -> Double {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

/// Pure layout + color helpers for entropy rails. UI layers must not re-derive
/// fill or tint math; tests call these directly against shipped display values.
public enum EntropyGauge {
    /// Default full-scale bits for a domain (token H ≈ 12; message scores ≈ 8).
    public static func fullScale(for domain: EntropyDomain) -> Double {
        switch domain {
        case .tokenDistribution: return 12.0
        case .messageContent: return 8.0
        }
    }

    /// Maps bits onto a unit interval for a progress bar.
    ///
    /// - Token domain: fill grows with H (high entropy = long bar).
    /// - Message domain: fill grows with **danger** (high H_msg = long bar).
    public static func fillFraction(
        bits: Double,
        fullScale: Double = 12.0,
        domain: EntropyDomain = .tokenDistribution
    ) -> Double {
        guard bits.isFinite, fullScale.isFinite, fullScale > 0 else { return 0.04 }
        let t = min(max(bits / fullScale, 0), 1)
        // Both domains: longer bar = more "signal"; polarity is color-only.
        // Message high → more filled (danger); token high → more filled (healthy).
        return min(max(t, 0.04), 1.0)
    }

    /// Multi-stop continuous gradient over H, **domain-aware polarity**.
    ///
    /// Token (`.tokenDistribution`): low H → deep red (collapse), high → teal.
    /// Message (`.messageContent`): **inverted** — high H_msg → red (gate risk),
    /// low H_msg → teal (short/simple is fine).
    ///
    /// Non-current / stale readings desaturate toward neutral so they never
    /// look like a live health instrument.
    public static func colorRGB(
        bits: Double,
        fullScale: Double = 12.0,
        domain: EntropyDomain = .tokenDistribution,
        isCurrent: Bool = true
    ) -> EntropyColorRGB {
        guard bits.isFinite, fullScale.isFinite, fullScale > 0 else {
            return neutral
        }
        var t = min(max(bits / fullScale, 0), 1)
        // Invert message domain so high score maps to the red end of the ramp.
        if domain == .messageContent {
            t = 1 - t
        }
        let vivid = ramp(t)
        if isCurrent { return vivid }
        return desaturate(vivid, toward: neutral, amount: 0.55)
    }

    private static let neutral = EntropyColorRGB(r: 0.45, g: 0.48, b: 0.55)

    /// Shared multi-stop ramp: t=0 deep red … t=1 teal (token-collapse polarity).
    private static func ramp(_ t: Double) -> EntropyColorRGB {
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 0.92, 0.22, 0.28), // deep red
            (0.18, 0.95, 0.42, 0.22), // coral-orange
            (0.35, 0.98, 0.78, 0.28), // gold (less pure ask-amber)
            (0.50, 0.72, 0.88, 0.22), // chartreuse
            (0.70, 0.28, 0.86, 0.48), // spring green
            (0.88, 0.18, 0.78, 0.72), // sea green → cyan
            (1.00, 0.20, 0.72, 0.82), // teal cyan
        ]
        if t <= stops[0].0 {
            return EntropyColorRGB(r: stops[0].1, g: stops[0].2, b: stops[0].3)
        }
        for i in 1..<stops.count {
            let a = stops[i - 1], b = stops[i]
            if t <= b.0 {
                let span = b.0 - a.0
                let u = span > 0 ? (t - a.0) / span : 0
                return EntropyColorRGB(
                    r: a.1 + (b.1 - a.1) * u,
                    g: a.2 + (b.2 - a.2) * u,
                    b: a.3 + (b.3 - a.3) * u
                )
            }
        }
        let last = stops[stops.count - 1]
        return EntropyColorRGB(r: last.1, g: last.2, b: last.3)
    }

    private static func desaturate(
        _ c: EntropyColorRGB,
        toward n: EntropyColorRGB,
        amount: Double
    ) -> EntropyColorRGB {
        let a = min(max(amount, 0), 1)
        return EntropyColorRGB(
            r: c.r + (n.r - c.r) * a,
            g: c.g + (n.g - c.g) * a,
            b: c.b + (n.b - c.b) * a
        )
    }
}

// MARK: - Fluid gauge dynamics (pure)

/// One paint sample for a fluid Shannon H rail.
///
/// Driven by wall-clock phase when agents are attached and H is **measured
/// current**. Absent / stale / Reduce Motion never invent lively healthy motion.
public struct EntropyFluidSample: Sendable, Equatable {
    /// Fill 0…1 (may undulate slightly when `isLive`).
    public var fill: Double
    public var color: EntropyColorRGB
    /// Horizontal shimmer offset −1…1 for a secondary wave highlight.
    public var waveOffset: Double
    /// True only when UI may run a TimelineView fluid animation.
    public var isLive: Bool

    public init(fill: Double, color: EntropyColorRGB, waveOffset: Double, isLive: Bool) {
        self.fill = min(1, max(0, fill))
        self.color = color
        self.waveOffset = min(1, max(-1, waveOffset.isFinite ? waveOffset : 0))
        self.isLive = isLive
    }
}

/// Time-phased fluid dynamics on top of `EntropyGauge` fill/color.
///
/// Does **not** invent bits — when `bits` is nil / non-finite / not current /
/// no agent attached, returns a static sample (fill floor 0.04, neutral or
/// desaturated color, `isLive == false`).
public enum EntropyFluidGauge {
    /// Angular frequency of the primary undulation (rad/s).
    public static let omega: Double = 2.4
    /// Peak fill modulation as a fraction of remaining headroom (0…1).
    public static let amplitude: Double = 0.06
    /// Luminance breath amount on RGB (0…1).
    public static let colorBreath: Double = 0.08

    /// Whether fluid motion is allowed for this presentation context.
    public static func shouldAnimate(
        agentAttached: Bool,
        isMeasuredCurrent: Bool,
        bits: Double?,
        reduceMotion: Bool
    ) -> Bool {
        guard agentAttached, isMeasuredCurrent, !reduceMotion else { return false }
        guard let bits, bits.isFinite else { return false }
        return true
    }

    /// Sample the fluid gauge at `phaseSeconds` (wall time or TimelineView date).
    public static func sample(
        bits: Double?,
        domain: EntropyDomain = .tokenDistribution,
        isMeasuredCurrent: Bool,
        agentAttached: Bool,
        phaseSeconds: TimeInterval,
        reduceMotion: Bool = false
    ) -> EntropyFluidSample {
        let live = shouldAnimate(
            agentAttached: agentAttached,
            isMeasuredCurrent: isMeasuredCurrent,
            bits: bits,
            reduceMotion: reduceMotion
        )
        guard let bits, bits.isFinite else {
            return EntropyFluidSample(
                fill: 0.04,
                color: EntropyGauge.colorRGB(bits: .nan),
                waveOffset: 0,
                isLive: false
            )
        }
        let baseFill = EntropyGauge.fillFraction(bits: bits, domain: domain)
        let baseColor = EntropyGauge.colorRGB(
            bits: bits,
            domain: domain,
            isCurrent: isMeasuredCurrent
        )
        guard live else {
            return EntropyFluidSample(
                fill: baseFill,
                color: baseColor,
                waveOffset: 0,
                isLive: false
            )
        }
        let t = phaseSeconds.isFinite ? phaseSeconds : 0
        // Phase offset from bits so two agents don't breathe in lockstep.
        let phi = bits * 0.37
        let wave = sin(t * omega + phi)
        let headroom = max(0, 1 - baseFill)
        let fill = min(1, max(0.04, baseFill + amplitude * headroom * wave))
        let breath = 1 + colorBreath * 0.5 * (wave + 1) // 1…1+colorBreath
        let color = EntropyColorRGB(
            r: min(1, baseColor.r * breath),
            g: min(1, baseColor.g * breath),
            b: min(1, baseColor.b * breath)
        )
        return EntropyFluidSample(
            fill: fill,
            color: color,
            waveOffset: wave,
            isLive: true
        )
    }

    /// Convenience from a display value when agents are attached.
    public static func sample(
        display: EntropyDisplay?,
        agentAttached: Bool,
        phaseSeconds: TimeInterval,
        reduceMotion: Bool = false
    ) -> EntropyFluidSample {
        guard let display else {
            return sample(
                bits: nil,
                isMeasuredCurrent: false,
                agentAttached: agentAttached,
                phaseSeconds: phaseSeconds,
                reduceMotion: reduceMotion
            )
        }
        return sample(
            bits: display.bits,
            domain: display.domain,
            isMeasuredCurrent: display.isCurrent,
            agentAttached: agentAttached,
            phaseSeconds: phaseSeconds,
            reduceMotion: reduceMotion
        )
    }
}

// MARK: - The reading

/// The pill's entropy state. Three cases, and the absent one carries no number.
///
/// This type exists because the previous readout emitted a hardcoded sine
/// (`7.2 + 0.55*sin(2πt/6)`) with `collapsed: false` whenever no detector was
/// attached. A dead detector therefore rendered as a permanently healthy one,
/// parked in the safe band, structurally unable to trip the threshold. For a
/// deception monitor that is the worst possible failure direction, so absence
/// is now a first-class state that cannot hold a value.
public enum EntropyReading: Sendable, Equatable {
    /// A real measurement, from a source that can be current, inside the
    /// freshness budget.
    case measured(EntropyMeasurement)
    /// A real measurement that is too old (or from an agent that has hung up)
    /// to describe the present. Always carries its age so it cannot be
    /// presented as current.
    case stale(EntropyMeasurement, age: TimeInterval)
    /// Nothing measured anything.
    case absent(EntropyAbsence)

    // MARK: Provenance-preserving accessors

    /// The measurement behind this reading, `nil` when there is none. Carries
    /// its own `source` and `measuredAt`, so obtaining it *is* obtaining
    /// provenance.
    public var measurement: EntropyMeasurement? {
        switch self {
        case .measured(let m): return m
        case .stale(let m, _): return m
        case .absent: return nil
        }
    }

    /// Bits, but only when they describe *now*. `nil` for stale and absent.
    /// This is the accessor a health check should use.
    public var currentBits: Double? {
        if case .measured(let m) = self { return m.bits }
        return nil
    }

    /// Collapse as a tri-state. `nil` means nothing measured it — which is not
    /// `false`. A caller writing `if reading.collapsed == false` gets `nil`'s
    /// behaviour (no match) rather than a fabricated all-clear.
    public var collapsed: Bool? {
        if case .measured(let m) = self { return m.collapsed }
        return nil
    }

    public var isMeasured: Bool {
        if case .measured = self { return true }
        return false
    }

    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    public var isAbsent: Bool {
        if case .absent = self { return true }
        return false
    }

    public var absence: EntropyAbsence? {
        if case .absent(let a) = self { return a }
        return nil
    }

    /// Age of the underlying measurement, `nil` when absent. Takes `now`
    /// explicitly — a reading must never read the wall clock itself, or the same
    /// reading answers differently on two calls and tests stop being reproducible.
    public func age(at now: Date) -> TimeInterval? {
        switch self {
        case .measured(let m): return m.age(at: now)
        case .stale(let m, _): return m.age(at: now)
        case .absent: return nil
        }
    }

    /// The age recorded when the reading was resolved, for `.stale` only. This
    /// is what a "last measured 41m ago" label should use: it is fixed at
    /// resolution time and cannot drift while the value sits in a view.
    public var staleAge: TimeInterval? {
        if case .stale(_, let age) = self { return age }
        return nil
    }

    // MARK: Judgement

    /// The safety verdict. Stale and absent are `.unknown` under **every**
    /// policy — there is no configuration in which an unmeasured reading passes.
    ///
    /// Polarity is **domain-aware**:
    /// - **Token distribution** (bridge): low H → `.watch`; producer `collapsed`
    ///   → `.collapsed`. This is the eval-awareness / collapse monitor.
    /// - **Message content** (gate): high H → `.watch` (verbosity / gate
    ///   hard-block polarity). Low message scores are normal for short status
    ///   pings and must **never** paint as collapse.
    public func verdict(policy: EntropyPolicy = .current) -> EntropyVerdict {
        guard case .measured(let m) = self else { return .unknown }
        switch m.source.domain {
        case .tokenDistribution:
            if m.collapsed == true { return .collapsed }
            return m.bits < policy.warnBits ? .watch : .healthy
        case .messageContent:
            // Gate never asserts token collapse; ignore a stale collapsed flag
            // if one ever leaked onto a gate row.
            if m.bits >= policy.warnBits { return .watch }
            return .healthy
        }
    }

    public var verdict: EntropyVerdict { verdict(policy: .current) }

    // MARK: Display

    /// Whether numeric display is withheld.
    ///
    /// `.absent` is withheld in every mode (there is no number). `.stale` is
    /// withheld under `enforce` and shown, labelled, under `observe`.
    public func suppressesNumericDisplay(policy: EntropyPolicy = .current) -> Bool {
        switch self {
        case .measured: return false
        case .stale: return policy.mode == .enforce
        case .absent: return true
        }
    }

    /// What `enforce` would do, regardless of the configured mode. Log this
    /// alongside `suppressesNumericDisplay` to size the impact before switching
    /// a deployment over.
    public var wouldSuppressNumericDisplay: Bool {
        suppressesNumericDisplay(policy: EntropyPolicy(mode: .enforce))
    }

    /// The only path from a reading to a number meant for the screen. Always
    /// bundles source, age and currency; returns `nil` when there is nothing
    /// honest to show.
    public func display(at now: Date, policy: EntropyPolicy = .current) -> EntropyDisplay? {
        guard !suppressesNumericDisplay(policy: policy) else { return nil }
        guard let m = measurement else { return nil }
        return EntropyDisplay(
            bits: m.bits,
            source: m.source,
            age: m.age(at: now),
            isCurrent: isMeasured
        )
    }

    /// One line an operator can act on, for a tooltip or the log.
    public func explain(at now: Date, policy: EntropyPolicy = .current) -> String {
        switch self {
        case .measured(let m):
            let delta = m.deltaH.map { String(format: ", ΔH %+.2f", $0) } ?? ""
            let v = verdict(policy: policy)
            return String(
                format: "%@ %.2f bits%@ — %@ (source: %@, measured %@ ago)",
                m.source.domain.badge, m.bits, delta,
                v.label(for: m.source.domain), m.source.label,
                AgentActivitySnapshot.age(since: m.measuredAt, now: now)
            )
        case .stale(let m, let age):
            return String(
                format: "STALE — last measured %.0fs ago (H %.2f bits from %@). "
                    + "This is NOT a current reading; collapse detection may have stopped.",
                age, m.bits, m.source.label
            )
        case .absent(let a):
            return a.reason
        }
    }
}

// MARK: - Resolution

extension EntropyProvenance {

    /// Resolve the one reading the whole pill should agree on.
    ///
    /// Precedence, and the fail-closed behaviour of each path:
    ///
    /// 1. **Live bridge, real backend, valid number** → `.measured`.
    /// 2. **Live bridge, real backend, number fails validation** →
    ///    `.absent(.rejected)`. Deliberately does *not* fall through to the gate:
    ///    a connected detector emitting garbage is an active fault and hiding it
    ///    behind a different source would make it invisible.
    /// 3. **Live bridge, synthetic backend** (`demo`/`idle`/`unknown`/`absent`) →
    ///    falls through to the gate, and if the gate has nothing, reports
    ///    `.absent(.syntheticSource)` rather than the fabricated number.
    /// 4. **Gate rows** → newest measurement from a `.live` agent within
    ///    `policy.maxAge` is `.measured`; anything older, or from an agent the
    ///    gate knows has hung up, is `.stale` with its age attached.
    /// 5. **Nothing** → `.absent(.noDetector)`, or `.absent(.gateUnavailable)`
    ///    when the hub DB could not even be opened.
    ///
    /// Deterministic: `now` is a parameter, and gate rows are ordered by an
    /// explicit total order (live first, then newest, then agent id) so SQLite
    /// row order cannot change the answer.
    public static func resolve(
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gate: [EntropyMeasurement] = [],
        gateDBAvailable: Bool = true,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> EntropyReading {
        var syntheticBackend: String?

        if bridgeConnected, let status = bridgeStatus {
            let source = EntropySource.bridge(backend: status.backend)
            if !source.canBeCurrent {
                syntheticBackend = status.backend.trimmingCharacters(in: .whitespaces)
            } else if let m = EntropyIntegrity.accept(
                bits: status.entropy,
                deltaH: status.deltaH,
                collapsed: status.collapsed,
                source: source,
                measuredAt: now,
                now: now,
                policy: policy
            ) {
                return .measured(m)
            } else {
                return .absent(.rejected(
                    "backend '\(status.backend)' served H=\(status.entropy), "
                        + "outside the accepted range 0 < H <= \(policy.maxBits)"
                ))
            }
        }

        let ordered = gate
            .filter { EntropyIntegrity.isTrustedSource($0.source) }
            .sorted(by: Self.precedes)
        if let best = ordered.first {
            let age = best.age(at: now)
            if best.source.canBeCurrent, age <= policy.maxAge {
                return .measured(best)
            }
            return .stale(best, age: age)
        }

        if let syntheticBackend { return .absent(.syntheticSource(syntheticBackend)) }
        return .absent(gateDBAvailable ? .noDetector : .gateUnavailable)
    }

    /// Total order over gate measurements: usable-now first, then newest, then
    /// agent id. The final tiebreak exists so two rows with identical timestamps
    /// cannot resolve differently between polls.
    static func precedes(_ a: EntropyMeasurement, _ b: EntropyMeasurement) -> Bool {
        if a.source.canBeCurrent != b.source.canBeCurrent { return a.source.canBeCurrent }
        if a.measuredAt != b.measuredAt { return a.measuredAt > b.measuredAt }
        return a.source.label < b.source.label
    }

    // MARK: Per-agent resolution

    /// Resolve the entropy reading **for one agent**.
    ///
    /// Precedence for that agent only:
    ///
    /// 1. **Live bridge named for this agent** (`ShannonStatus.agent` matches
    ///    `agentId`, real backend, valid number) → `.measured`.
    /// 2. **Gate rows for this agent** → freshest usable measurement within
    ///    `policy.maxAge` is `.measured`; older / hung-up → `.stale`.
    /// 3. **Live bridge for a different agent, or unnamed fleet bridge** →
    ///    ignored for this agent (fleet-wide numbers stay on `resolve`, not
    ///    copied onto every row).
    /// 4. **Nothing for this agent** → `.absent` (synthetic fleet backends do
    ///    not invent a per-agent H either).
    ///
    /// Fail-closed: synthetic bridge backends never produce `.measured` for any
    /// agent; zero/default scores never construct an `EntropyMeasurement`.
    /// Canonical agent identity for provenance matching (claude ↔ claude_code).
    public static func agentIdentityKey(_ raw: String) -> String {
        let s = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch s {
        case "claude", "claudecode", "claude_code", "anthropic_claude":
            return "claude_code"
        case "cursor", "cursor_agent", "cursoragent", "cursor_cli":
            return "cursor"
        case "codex", "openai_codex", "openai-codex":
            return "codex"
        case "kimi", "kimi_code", "moonshot":
            return "kimi"
        case "opencode", "open_code", "oc":
            return "opencode"
        case "gemini", "gemini_cli", "google_gemini":
            return "gemini"
        case "science", "claude_science", "operon":
            return "science"
        case "grok", "grok_build", "supergrok":
            return "grok_build"
        default:
            return s
        }
    }

    /// True when bridge `status.agent` refers to `agentId` (aliases allowed).
    public static func bridgeNamesAgent(_ status: ShannonStatus, agentId: String) -> Bool {
        let named = (status.agent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !named.isEmpty else { return false }
        return agentIdentityKey(named) == agentIdentityKey(agentId)
    }

    public static func resolveForAgent(
        agentId: String,
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gate: [EntropyMeasurement] = [],
        gateDBAvailable: Bool = true,
        now: Date = Date(),
        policy: EntropyPolicy = .current,
        /// When true, an **unnamed** measured fleet bridge may attribute to this
        /// agent (sole live attach). Never invents H — bridge must already be
        /// measured non-synthetic. Multi-agent fleets leave this false.
        applyUnnamedFleetBridge: Bool = false
    ) -> EntropyReading {
        let id = agentId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            return .absent(gateDBAvailable ? .noDetector : .gateUnavailable)
        }

        // Bridge attaches when it names this agent (alias-aware), or when the
        // caller asserts sole-live fleet attribution for an unnamed stream.
        if bridgeConnected, let status = bridgeStatus {
            let named = (status.agent ?? "").trimmingCharacters(in: .whitespaces)
            let namedMatch = bridgeNamesAgent(status, agentId: id)
            let soleUnnamed = applyUnnamedFleetBridge && named.isEmpty
            if namedMatch || soleUnnamed {
                let source = EntropySource.bridge(backend: status.backend)
                if source.canBeCurrent {
                    // Integrity: only non-synthetic bridge backends may mint a
                    // measurement (EntropyIntegrity.accept enforces the same).
                    if let m = EntropyIntegrity.accept(
                        bits: status.entropy,
                        deltaH: status.deltaH,
                        collapsed: status.collapsed,
                        source: source,
                        measuredAt: now,
                        now: now,
                        policy: policy
                    ) {
                        return .measured(m)
                    }
                    return .absent(.rejected(
                        "backend '\(status.backend)' served H=\(status.entropy), "
                            + "outside the accepted range 0 < H <= \(policy.maxBits)"
                    ))
                }
                // Synthetic backend naming this agent: do not fall through to a
                // fabricated number; still allow a real gate row for the agent.
            }
        }

        // Drop untrusted sources before ranking — self-reports never carry
        // EntropySource.gate/bridge from a honest feed, but defence in depth.
        let forAgent = gate.filter { measurement in
            guard EntropyIntegrity.isTrustedSource(measurement.source) else { return false }
            guard let mid = measurement.source.agentId else { return false }
            return agentIdentityKey(mid) == agentIdentityKey(id)
        }.sorted(by: Self.precedes)

        if let best = forAgent.first {
            let age = best.age(at: now)
            if best.source.canBeCurrent, age <= policy.maxAge {
                return .measured(best)
            }
            return .stale(best, age: age)
        }

        // Named synthetic bridge for this agent with no gate score → honest absence.
        if bridgeConnected, let status = bridgeStatus {
            if bridgeNamesAgent(status, agentId: id) {
                let source = EntropySource.bridge(backend: status.backend)
                if !source.canBeCurrent {
                    return .absent(.syntheticSource(
                        status.backend.trimmingCharacters(in: .whitespaces)
                    ))
                }
            }
        }

        return .absent(gateDBAvailable ? .noDetector : .gateUnavailable)
    }

    /// Prefer a **currently measured** live resolve over memory that may be
    /// stale under enforce (display nil → "—" / "no H" despite attach bridge H).
    ///
    /// Order: measured live → measured memory → live (absent/stale) → memory.
    public static func preferredRowReading(
        live: EntropyReading,
        memory: EntropyReading?
    ) -> EntropyReading {
        if live.isMeasured { return live }
        guard let memory else { return live }
        if memory.isMeasured { return memory }
        if case .absent = live { return memory }
        return live
    }

    /// Resolve an independent reading for every listed agent id.
    ///
    /// Order of `agentIds` is preserved in the returned array of pairs; the map
    /// form is for O(1) lookup by id when binding UI rows.
    ///
    /// - Parameter liveAgentIds: agents currently **live** (gate or process
    ///   attach). When the bridge stream is measured but **unnamed**, and exactly
    ///   one listed id is live, that sole attach receives the fleet bridge H.
    public static func resolveAll(
        agentIds: [String],
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gate: [EntropyMeasurement] = [],
        gateDBAvailable: Bool = true,
        now: Date = Date(),
        policy: EntropyPolicy = .current,
        liveAgentIds: Set<String> = []
    ) -> [String: EntropyReading] {
        let liveKeys = Set(liveAgentIds.map { agentIdentityKey($0) })
        var soleLiveListed: String?
        if liveKeys.count == 1 {
            let key = liveKeys.first!
            soleLiveListed = agentIds.first { agentIdentityKey($0) == key }
        }

        var out: [String: EntropyReading] = [:]
        out.reserveCapacity(agentIds.count)
        for raw in agentIds {
            let id = raw.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, out[id] == nil else { continue }
            let applyFleet = soleLiveListed.map { agentIdentityKey($0) == agentIdentityKey(id) } ?? false
            out[id] = resolveForAgent(
                agentId: id,
                bridgeConnected: bridgeConnected,
                bridgeStatus: bridgeStatus,
                gate: gate,
                gateDBAvailable: gateDBAvailable,
                now: now,
                policy: policy,
                applyUnnamedFleetBridge: applyFleet
            )
        }
        return out
    }

    /// Ordered list of `(agentId, reading)` for stable UI iteration.
    public static func resolveOrdered(
        agentIds: [String],
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gate: [EntropyMeasurement] = [],
        gateDBAvailable: Bool = true,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> [(agentId: String, reading: EntropyReading)] {
        let map = resolveAll(
            agentIds: agentIds,
            bridgeConnected: bridgeConnected,
            bridgeStatus: bridgeStatus,
            gate: gate,
            gateDBAvailable: gateDBAvailable,
            now: now,
            policy: policy
        )
        var seen = Set<String>()
        var ordered: [(agentId: String, reading: EntropyReading)] = []
        for raw in agentIds {
            let id = raw.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !seen.contains(id), let reading = map[id] else { continue }
            seen.insert(id)
            ordered.append((id, reading))
        }
        return ordered
    }

    /// Per-agent entropy delta the companion board may react to.
    ///
    /// Only returns a value when that agent's reading is **measured** and
    /// either reports a finite `deltaH` or asserts collapse. Synthetic,
    /// stale, and absent readings never alarm a companion.
    public static func companionDeltaForAgent(
        agentId: String,
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gate: [EntropyMeasurement] = [],
        gateDBAvailable: Bool = true,
        now: Date = Date(),
        policy: EntropyPolicy = .current,
        applyUnnamedFleetBridge: Bool = false
    ) -> Double? {
        let reading = resolveForAgent(
            agentId: agentId,
            bridgeConnected: bridgeConnected,
            bridgeStatus: bridgeStatus,
            gate: gate,
            gateDBAvailable: gateDBAvailable,
            now: now,
            policy: policy,
            applyUnnamedFleetBridge: applyUnnamedFleetBridge
        )
        guard case .measured(let m) = reading else { return nil }
        if let d = m.deltaH, d.isFinite { return d }
        // Producer asserted collapse without a delta — still enough to wary.
        if m.collapsed == true { return -4.0 }
        return nil
    }

    /// Map of agent id → companion delta for every agent that has a trustworthy one.
    public static func companionDeltas(
        agentIds: [String],
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gate: [EntropyMeasurement] = [],
        gateDBAvailable: Bool = true,
        now: Date = Date(),
        policy: EntropyPolicy = .current,
        liveAgentIds: Set<String> = []
    ) -> [String: Double] {
        let map = resolveAll(
            agentIds: agentIds,
            bridgeConnected: bridgeConnected,
            bridgeStatus: bridgeStatus,
            gate: gate,
            gateDBAvailable: gateDBAvailable,
            now: now,
            policy: policy,
            liveAgentIds: liveAgentIds
        )
        var out: [String: Double] = [:]
        for (id, reading) in map {
            guard case .measured(let m) = reading else { continue }
            if let d = m.deltaH, d.isFinite {
                out[id] = d
            } else if m.collapsed == true {
                out[id] = -4.0
            }
        }
        return out
    }
}
