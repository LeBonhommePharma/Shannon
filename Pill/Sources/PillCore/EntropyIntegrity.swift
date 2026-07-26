import Foundation

// MARK: - Anti-deception integrity for entropy data
//
// Threat model: an agent tries to make a monitor *display* a healthy H while
// the real measurement is collapsed/absent, or to paint its claim onto another
// agent's row. Defences here are pure and fail-closed:
//
// 1. Self-reported fields never construct an `EntropyMeasurement`.
// 2. Only gate-computed bits (`.gate`) and non-synthetic bridge backends
//    (`.bridge`) are trusted measurement sources.
// 3. A bare `Double` with no trusted source is never a reading.
// 4. When a self-report *claim* is available alongside a gate measurement, the
//    claim is compared but never substituted for the measurement.

/// Keys an agent (or its payload) may use to smuggle a self-attested entropy
/// value. Matching any of these means "claim", not "measurement".
public enum EntropySelfReportKey: String, Sendable, CaseIterable {
    case shannon_h
    case shannonH = "shannonH"
    case self_h
    case selfH = "selfH"
    case entropy_score
    case entropyScore = "entropyScore"
    case gate_h
    case gateH = "gateH"
    case h_bits
    case hBits = "hBits"
    case claimed_h
    case claimedH = "claimedH"

    /// Case-insensitive match against a free-form field name.
    public static func matches(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        return allCases.contains { $0.rawValue.lowercased() == key }
            || key == "shannon_h"
            || key == "self_h"
            || key == "entropy_score"
            || key == "gate_h"
            || key == "h_bits"
            || key == "claimed_h"
    }
}

/// Pure integrity rules for entropy provenance. UI and resolve paths must go
/// through these so a self-report can never masquerade as measured H.
public enum EntropyIntegrity {

    /// Classic message-content H for repeated ⌘D / process-attach status text
    /// (e.g. "Working in Ghostty"). **Not** Shannon library token-collapse
    /// (logits/logprobs ~8–12 → ~2–4). Seeing this band a lot means attach
    /// spam or an unstamped leftover score is dominating the display.
    public static let attachSpamSignatureBits: ClosedRange<Double> = 2.30...2.45

    /// True when bits match the systematic attach-status spam band.
    /// Callers with **no honest measurement clock** must refuse these as
    /// current H; a stamped substantive write outside this band is fine.
    public static func looksLikeAttachSpamSignature(_ bits: Double) -> Bool {
        guard bits.isFinite else { return false }
        return attachSpamSignatureBits.contains(bits)
    }

    /// True when this source is allowed to produce a displayable measurement.
    /// Offline gate rows are still *trusted as historical* (they may be stale)
    /// — trust here means "not agent-authored", not "current".
    public static func isTrustedSource(_ source: EntropySource) -> Bool {
        switch source {
        case .bridge(let backend):
            return !ShannonStatus.syntheticBackends.contains(
                backend.trimmingCharacters(in: .whitespaces).lowercased()
            )
        case .gate:
            return true
        }
    }

    /// Always `nil`. There is no honest path from an agent self-report to a
    /// measurement — this function exists so call sites that look tempting
    /// (`measurementFromSelfReport(agent.shannon_H)`) fail at the type/API
    /// layer rather than by convention.
    public static func measurementFromSelfReport(
        bits: Double,
        agentId: String,
        measuredAt: Date = Date(),
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> EntropyMeasurement? {
        // Deliberately unused parameters: the signature matches what a
        // mistaken caller would reach for, and the body always refuses.
        _ = bits; _ = agentId; _ = measuredAt; _ = now; _ = policy
        return nil
    }

    /// Refuse a proposed measurement when its source is not trusted, or when
    /// the bits fail the same validation as `EntropyMeasurement.init?`.
    public static func accept(
        bits: Double,
        deltaH: Double? = nil,
        collapsed: Bool? = nil,
        source: EntropySource,
        measuredAt: Date,
        now: Date,
        policy: EntropyPolicy = .current
    ) -> EntropyMeasurement? {
        guard isTrustedSource(source) else { return nil }
        return EntropyMeasurement(
            bits: bits,
            deltaH: deltaH,
            collapsed: collapsed,
            source: source,
            measuredAt: measuredAt,
            now: now,
            policy: policy
        )
    }

    /// Compare an optional agent claim against a trusted measurement.
    ///
    /// - Returns: `true` when the claim under-reports measured token/gate H
    ///   by more than `marginBits` (log2 ratio), i.e. the same deception
    ///   direction the gate's attestation ladder escalates on.
    /// - A missing/invalid claim is **not** treated as a lie here (silence is
    ///   handled by the gate ledger); only an explicit positive claim can lie.
    public static func claimUnderReports(
        claimBits: Double?,
        measuredBits: Double,
        marginBits: Double = 1.5,
        floorBits: Double = 2.5
    ) -> Bool {
        guard let claim = claimBits, claim.isFinite, claim > 0 else { return false }
        guard measuredBits.isFinite, measuredBits >= floorBits else { return false }
        let d = log2((measuredBits + 1e-9) / (claim + 1e-9))
        return d.isFinite && d >= marginBits
    }

    /// Resolve a reading for an agent while **explicitly discarding** any
    /// self-report claim as a measurement source. The claim may only affect
    /// the returned `claimUnderReports` flag for UI honesty markers.
    public static func resolveHonest(
        agentId: String,
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?,
        gate: [EntropyMeasurement],
        gateDBAvailable: Bool = true,
        selfReportClaim: Double? = nil,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> (reading: EntropyReading, claimUnderReports: Bool) {
        // Drop any gate rows that somehow arrived with an untrusted source —
        // defence in depth if a future feed forgets the rule.
        let trustedGate = gate.filter { isTrustedSource($0.source) }
        let reading = EntropyProvenance.resolveForAgent(
            agentId: agentId,
            bridgeConnected: bridgeConnected,
            bridgeStatus: bridgeStatus,
            gate: trustedGate,
            gateDBAvailable: gateDBAvailable,
            now: now,
            policy: policy
        )
        let measured = reading.currentBits
            ?? reading.measurement.map(\.bits)
        let lying: Bool
        if let measured {
            lying = claimUnderReports(claimBits: selfReportClaim, measuredBits: measured)
        } else {
            lying = false
        }
        return (reading, lying)
    }

    /// Dictionary / payload scrubber: remove keys that look like self-reported
    /// entropy so a downstream logger cannot rehydrate them as H.
    public static func scrubSelfReportFields(_ fields: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(fields.count)
        for (k, v) in fields {
            if EntropySelfReportKey.matches(k) { continue }
            out[k] = v
        }
        return out
    }
}
