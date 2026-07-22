import Foundation
import Observation
#if canImport(HealthKit)
import HealthKit
#endif

/// Optional ambient biofeedback: when LP's heart rate rises well above his own
/// recent baseline during a docking run, the Shannon Face accent pulses.
///
/// Deliberately constrained:
///  * **Off by default.** Nothing is read until `enable()` is called from a
///    control LP taps himself.
///  * **Never uploaded.** Samples are read, compared to a rolling baseline,
///    and discarded. No heart-rate value is written to CloudKit, relayed to
///    the phone, or persisted to the snapshot cache.
///  * **Relative, not absolute.** A resting rate of 48 and one of 72 are both
///    normal for different people; only the deviation from this session's own
///    baseline is meaningful.
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

    /// How far above baseline counts as elevated.
    private let elevationThreshold: Double = 12
    private var baseline: Double?
    /// Exponential smoothing keeps a single noisy sample from flipping state.
    private let smoothing = 0.1

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
    /// opt-in, never at launch.
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

    func consume(_ values: [Double]) {
        guard let latest = values.last else { return }
        currentBPM = latest

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
