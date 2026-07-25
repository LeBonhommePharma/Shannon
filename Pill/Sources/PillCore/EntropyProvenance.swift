import Foundation

extension ShannonStatus {
    /// Backends that FABRICATE their numbers rather than measuring anything.
    ///
    /// - `demo`  — `python -m shannon.pill_bridge --demo`. `_DemoDetector`
    ///   (python/shannon/pill_bridge.py:219) returns `8.0 + 2.0*sin(n/12)`, and
    ///   `--demo` is the only standalone mode the bridge supports (:250).
    /// - `idle`  — `IdleTelemetry`, the local placeholder sine used when no
    ///   bridge is connected at all.
    /// - `unknown` — the bridge's fallback when a detector exposes no `backend`
    ///   attribute (:91). Provenance cannot be established, so it is not
    ///   trusted. A deception monitor must fail closed.
    public static let syntheticBackends: Set<String> = ["demo", "idle", "unknown", ""]

    /// True when this reading is a placeholder, not a measurement.
    public var isSynthetic: Bool {
        Self.syntheticBackends.contains(
            backend.trimmingCharacters(in: .whitespaces).lowercased()
        )
    }
}

/// The pill's single provenance rule, in one place so every consumer applies it.
///
/// Provenance used to be re-derived at each call site, and the derivations
/// drifted: the header, the border, the `~H` badge and the tooltip all asked
/// "is this measured?", while the companion board asked only "is the socket
/// up?". `--demo` opens a real socket and serves real-looking numbers, so the
/// companions went alarmed over a reading the rest of the pill was, at the same
/// instant, labelling "simulated". Anything that reacts to an entropy number
/// goes through here.
public enum EntropyProvenance {
    /// True when the number on screen came from a real detector rather than the
    /// local placeholder waveform.
    ///
    /// Connectivity is NOT provenance — see `ShannonStatus.syntheticBackends`.
    /// - Parameters:
    ///   - connected: whether the bridge socket is up.
    ///   - displayed: the status actually being rendered, i.e. the live bridge
    ///     status when there is one and the idle placeholder otherwise.
    public static func isMeasured(connected: Bool, displayed: ShannonStatus?) -> Bool {
        guard let displayed else { return false }
        return connected && !displayed.isSynthetic
    }

    /// The entropy delta the companion board is allowed to react to, or `nil`
    /// when the reading is not trustworthy enough to alarm anyone.
    ///
    /// - Parameters:
    ///   - connected: whether the bridge socket is up.
    ///   - status: the **live bridge** status (`nil` when the pill is showing
    ///     the idle placeholder, which is never a reason to alarm).
    ///
    /// Deliberately the same test as `isMeasured`, not a looser one. The pill
    /// must never be alarmed about a number it is simultaneously marking fake.
    public static func companionDelta(connected: Bool, status: ShannonStatus?) -> Double? {
        guard isMeasured(connected: connected, displayed: status) else { return nil }
        return status?.deltaH
    }
}
