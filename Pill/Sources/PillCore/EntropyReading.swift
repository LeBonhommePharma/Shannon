import Foundation

// MARK: - Where a number came from

/// Attribution for one entropy value. There is no "anonymous" case: every
/// `EntropyMeasurement` names either a live detector socket or a specific agent
/// row in the hub DB, so a bare bit-count with nothing behind it cannot be
/// constructed in the first place.
public enum EntropySource: Sendable, Equatable {
    /// A live detector reached over `shannon.pill_bridge`, tagged with the
    /// backend string that detector reported.
    case bridge(backend: String)
    /// Gate-computed output entropy (`decision.computed_H`) for one agent,
    /// read back from `agents.entropy_score` in `agent_hub.db`.
    case gate(agentId: String, presence: AgentPresence)

    /// Short attribution for a tooltip or log line.
    public var label: String {
        switch self {
        case .bridge(let backend):
            let b = backend.trimmingCharacters(in: .whitespaces)
            return "bridge:\(b.isEmpty ? "?" : b)"
        case .gate(let agentId, let presence):
            return "gate:\(agentId) (\(presence.label))"
        }
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
/// | `SHANNON_PILL_ENTROPY_WARN_BITS` | `5.0` | Measured H below this reads `.watch` instead of `.healthy`. Mirrors the gate's own block threshold. Clamped to `0 ... maxBits`. |
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

    /// `H` for a current reading, `H⌛` for one being shown under observe mode.
    public var badge: String { isCurrent ? "H" : "H⌛" }
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
    public func verdict(policy: EntropyPolicy = .current) -> EntropyVerdict {
        guard case .measured(let m) = self else { return .unknown }
        if m.collapsed == true { return .collapsed }
        return m.bits < policy.warnBits ? .watch : .healthy
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
            return String(
                format: "H %.2f bits%@ — %@ (source: %@, measured %@ ago)",
                m.bits, delta, verdict(policy: policy).label, m.source.label,
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
            } else if let m = EntropyMeasurement(
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

        let ordered = gate.sorted(by: Self.precedes)
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
}
