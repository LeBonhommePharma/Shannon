import Foundation

// MARK: - NATURaL SCI / HRV entropy (pure)
//
// Port of BonhommeCore `EntropyCalculator` + `HRVAnalyzer` SCI path from
// https://github.com/LeBonhommePharma/NATURaL — no HealthKit, Accel, or UI.
//
// Fixed RR domain 300–1500 ms keeps histograms session-comparable; concentrated
// RR → low H → high SCI; near-uniform → high H → low SCI.

/// Reusable histogram Shannon entropy (NATURaL / FlexAIDdS kinship).
public struct NaturalEntropyCalculator: Sendable {
    /// Histogram bins (default 32 → max H = 5 bits).
    public let binCount: Int

    public init(binCount: Int = 32) {
        self.binCount = max(1, binCount)
    }

    /// Theoretical maximum entropy for this bin count: log₂(binCount).
    public var maxEntropyBits: Double { log2(Double(binCount)) }

    /// Adaptive-domain Shannon entropy: bins over [min, max] of the sample.
    ///
    /// H = −Σ pᵢ log₂(pᵢ). Non-finite values filtered. Empty / single / zero-range → 0.
    public func shannonEntropy(_ values: [Double]) -> Double {
        let clean = values.filter(\.isFinite)
        guard clean.count >= 2 else { return 0 }
        guard let minVal = clean.min(), let maxVal = clean.max() else { return 0 }
        let range = maxVal - minVal
        guard range > 0 else { return 0 }

        let binWidth = range / Double(binCount)
        var bins = [Int](repeating: 0, count: binCount)
        for value in clean {
            var idx = Int((value - minVal) / binWidth)
            if idx < 0 { idx = 0 }
            if idx >= binCount { idx = binCount - 1 }
            bins[idx] += 1
        }
        return Self.entropyBits(bins: bins, total: clean.count)
    }

    /// Fixed-domain Shannon entropy (values clamped into [domainMin, domainMax]).
    ///
    /// Used by the SCI path so identical shapes yield identical H across sessions.
    public func shannonEntropy(
        _ values: [Double],
        domainMin: Double,
        domainMax: Double
    ) -> Double {
        let clean = values.filter(\.isFinite)
        guard clean.count >= 2 else { return 0 }
        let range = domainMax - domainMin
        guard range > 0 else { return 0 }

        let binWidth = range / Double(binCount)
        var bins = [Int](repeating: 0, count: binCount)
        for value in clean {
            let clamped = max(domainMin, min(domainMax, value))
            var idx = Int((clamped - domainMin) / binWidth)
            if idx < 0 { idx = 0 }
            if idx >= binCount { idx = binCount - 1 }
            bins[idx] += 1
        }
        return Self.entropyBits(bins: bins, total: clean.count)
    }

    /// Circular Shannon entropy for torsional angles in degrees, fixed [-180, 180).
    public func circularShannonEntropy(_ angles: [Double]) -> Double {
        let clean = angles.filter(\.isFinite)
        guard clean.count >= 2 else { return 0 }

        let binWidth = 360.0 / Double(binCount)
        var bins = [Int](repeating: 0, count: binCount)
        for angle in clean {
            var a = angle.truncatingRemainder(dividingBy: 360.0)
            if a > 180.0 { a -= 360.0 }
            if a < -180.0 { a += 360.0 }
            var idx = Int((a + 180.0) / binWidth)
            if idx < 0 { idx = 0 }
            if idx >= binCount { idx = binCount - 1 }
            bins[idx] += 1
        }
        return Self.entropyBits(bins: bins, total: clean.count)
    }

    /// Map entropy (bits) → coherence score in [0, 1] (1 = zero entropy).
    public func entropyToScore(_ entropy: Double) -> Double {
        entropyToScore(entropy, maxEntropy: maxEntropyBits)
    }

    public func entropyToScore(_ entropy: Double, maxEntropy: Double) -> Double {
        guard maxEntropy > 0 else { return 1.0 }
        let clamped = max(0, min(maxEntropy, entropy))
        return 1.0 - (clamped / maxEntropy)
    }

    /// Entropy + score, or nil if fewer than 2 finite samples.
    public func analyze(_ values: [Double]) -> (entropy: Double, score: Double)? {
        let clean = values.filter(\.isFinite)
        guard clean.count >= 2 else { return nil }
        let h = shannonEntropy(clean)
        return (h, entropyToScore(h))
    }

    private static func entropyBits(bins: [Int], total: Int) -> Double {
        let n = Double(total)
        guard n > 0 else { return 0 }
        var entropy = 0.0
        for count in bins where count > 0 {
            let p = Double(count) / n
            entropy -= p * log2(p)
        }
        return entropy
    }
}

// MARK: - Shannon Collapse Index (SCI) from RR intervals

/// NATURaL SCI over fixed physiological RR domain 300–1500 ms.
public struct NaturalSCI: Sendable {
    public static let rrDomainMinMs: Double = 300
    public static let rrDomainMaxMs: Double = 1500
    /// Default collapse threshold (bits) used by NATURaL HRVAnalyzer for “focused”.
    public static let defaultCollapseThresholdBits: Double = 3.2

    public let calculator: NaturalEntropyCalculator
    public let collapseThresholdBits: Double

    public init(binCount: Int = 32, collapseThresholdBits: Double = 3.2) {
        self.calculator = NaturalEntropyCalculator(binCount: binCount)
        self.collapseThresholdBits = collapseThresholdBits
    }

    /// Shannon entropy of RR intervals (ms) on the fixed 300–1500 ms domain.
    public func shannonEntropy(rrIntervalsMs: [Double]) -> Double {
        calculator.shannonEntropy(
            rrIntervalsMs,
            domainMin: Self.rrDomainMinMs,
            domainMax: Self.rrDomainMaxMs
        )
    }

    /// SCI score in [0, 1]: high = concentrated RR (focused / low entropy).
    public func score(rrIntervalsMs: [Double]) -> Double? {
        let clean = rrIntervalsMs.filter(\.isFinite)
        guard clean.count >= 4 else { return nil }
        let h = shannonEntropy(rrIntervalsMs: clean)
        return calculator.entropyToScore(h)
    }

    /// Full SCI result for operator / tests.
    public func analyze(rrIntervalsMs: [Double]) -> NaturalSCIResult? {
        let clean = rrIntervalsMs.filter(\.isFinite)
        guard clean.count >= 4 else { return nil }
        let h = shannonEntropy(rrIntervalsMs: clean)
        let s = calculator.entropyToScore(h)
        let collapsed = h < collapseThresholdBits
        return NaturalSCIResult(
            entropyBits: h,
            sciScore: s,
            sampleCount: clean.count,
            isCollapsed: collapsed,
            domainMinMs: Self.rrDomainMinMs,
            domainMaxMs: Self.rrDomainMaxMs
        )
    }
}

/// Snapshot of one SCI analysis pass.
public struct NaturalSCIResult: Sendable, Equatable {
    public let entropyBits: Double
    /// 0…1 coherence (1 = fully concentrated).
    public let sciScore: Double
    public let sampleCount: Int
    public let isCollapsed: Bool
    public let domainMinMs: Double
    public let domainMaxMs: Double

    public init(
        entropyBits: Double,
        sciScore: Double,
        sampleCount: Int,
        isCollapsed: Bool,
        domainMinMs: Double,
        domainMaxMs: Double
    ) {
        self.entropyBits = entropyBits
        self.sciScore = sciScore
        self.sampleCount = sampleCount
        self.isCollapsed = isCollapsed
        self.domainMinMs = domainMinMs
        self.domainMaxMs = domainMaxMs
    }

    /// Percent presentation: 0…100.
    public var sciPercent: Double { sciScore * 100 }

    public var statusLine: String {
        String(
            format: "SCI %.0f%% · H=%.2f bits (%d RR · %.0f–%.0f ms)%@",
            sciPercent,
            entropyBits,
            sampleCount,
            domainMinMs,
            domainMaxMs,
            isCollapsed ? " · collapse" : ""
        )
    }
}

// MARK: - Mac hub query surface

/// Thin query helpers for Pill / CLI (no sensors).
public enum NaturalSCIHub: Sendable {
    /// Demo concentrated RR series (high SCI).
    public static func demoConcentratedRR(count: Int = 64, centerMs: Double = 800) -> [Double] {
        Array(repeating: centerMs, count: max(4, count))
    }

    /// Demo wide RR series spanning the SCI domain (low SCI).
    public static func demoWideRR(count: Int = 40) -> [Double] {
        let n = max(4, count)
        return (0..<n).map { 300.0 + Double($0) * (1200.0 / Double(n - 1)) }
    }

    public static func demoStatusLine() -> String {
        let sci = NaturalSCI()
        guard let concentrated = sci.analyze(rrIntervalsMs: demoConcentratedRR()),
              let wide = sci.analyze(rrIntervalsMs: demoWideRR())
        else { return "SCI: insufficient data" }
        return "NATURaL SCI · focused \(String(format: "%.0f", concentrated.sciPercent))% vs spread \(String(format: "%.0f", wide.sciPercent))%"
    }
}
