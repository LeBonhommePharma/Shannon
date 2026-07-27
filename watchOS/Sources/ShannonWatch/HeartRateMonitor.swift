import Foundation
import Observation
import ShannonCore
#if canImport(HealthKit)
import HealthKit
#endif

/// Optional ambient biofeedback + research SCI path (NATURaL / HealthKit).
///
/// Deliberately constrained:
///  * **Off by default.** Nothing is read until `enable()` is called from a
///    control LP taps himself (never at launch).
///  * **Never uploaded.** Samples stay on-device. No HR / RR / SCI is written
///    to CloudKit agent sync, snapshot cache, or phone relay.
///  * **Relative elevation.** Session baseline only; absolute resting rates vary.
///  * **SCI:** BPM stream → RR (ms) → `NaturalSCI` when ≥ 4 samples (fixed 300–1500 ms).
@available(watchOS 10.0, *)
@MainActor
@Observable
public final class HeartRateMonitor {
    public private(set) var isEnabled = false
    public private(set) var isAuthorized = false
    /// Most recent sample, beats per minute. Displayed nowhere by default.
    public private(set) var currentBPM: Double?
    /// True while the rate sits meaningfully above baseline.
    public private(set) var isElevated = false
    /// Latest NATURaL SCI from rolling BPM→RR series (nil until enough samples).
    public private(set) var latestSCI: NaturalSCIResult?
    /// Rolling RR intervals (ms) derived from BPM for research SCI.
    public private(set) var recentRRMilliseconds: [Double] = []

    /// How far above baseline counts as elevated.
    private let elevationThreshold: Double = 12
    private var baseline: Double?
    /// Exponential smoothing keeps a single noisy sample from flipping state.
    private let smoothing = 0.1
    private let maxRRWindow = 64
    private let sci = NaturalSCI()

    #if canImport(HealthKit)
    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    #endif

    public init() {}

    public var isAvailable: Bool {
        #if canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    /// Requests read-only heart-rate access. Called only from an explicit
    /// opt-in, never at launch. Does **not** require clinical medication consent
    /// (ambient HR only); clinical meds remain consent-gated elsewhere.
    public func enable() async {
        #if canImport(HealthKit)
        guard isAvailable, let type = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            return
        }
        do {
            // Read-only: Shannon never writes to HealthKit.
            try await store.requestAuthorization(toShare: [], read: [type])
            isAuthorized = true
            isEnabled = true
            startQuery(type)
        } catch {
            isAuthorized = false
        }
        #endif
    }

    public func disable() {
        isEnabled = false
        isElevated = false
        currentBPM = nil
        baseline = nil
        latestSCI = nil
        recentRRMilliseconds = []
        #if canImport(HealthKit)
        if let query { store.stop(query) }
        query = nil
        #endif
    }

    #if canImport(HealthKit)
    private func startQuery(_ type: HKQuantityType) {
        let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?,
                                HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else { return }
            let unit = HKUnit.count().unitDivided(by: .minute())
            let values = samples.map { $0.quantity.doubleValue(for: unit) }
            Task { @MainActor in self?.consume(values) }
        }

        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: nil,
            anchor: nil,
            limit: HKObjectQueryNoLimit,
            resultsHandler: handler
        )
        query.updateHandler = handler
        store.execute(query)
        self.query = query
    }
    #endif

    /// Ingest BPM samples (HealthKit or tests). Updates elevation + SCI window.
    public func consume(_ values: [Double]) {
        guard let latest = values.last else { return }
        currentBPM = latest

        // Research path: BPM → RR ms → rolling SCI (fixed domain via NaturalSCI).
        for bpm in values {
            if let rr = HealthResearchSamples.rrMilliseconds(fromBPM: bpm) {
                recentRRMilliseconds.append(rr)
            }
        }
        if recentRRMilliseconds.count > maxRRWindow {
            recentRRMilliseconds = Array(recentRRMilliseconds.suffix(maxRRWindow))
        }
        if let result = sci.analyze(rrIntervalsMs: recentRRMilliseconds) {
            latestSCI = result
        }

        guard let current = baseline else {
            // First sample establishes the baseline; nothing is "elevated"
            // relative to a baseline that does not exist yet.
            baseline = latest
            return
        }
        baseline = current + (latest - current) * smoothing
        isElevated = latest - (baseline ?? latest) > elevationThreshold
    }
}
