import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

/// Detects the quick upward wrist rotation of checking the time, so Shannon
/// can jump back to its face without a tap.
///
/// Deliberately conservative: the watch is on a moving arm all day, and a
/// false positive here yanks the user away from whatever they were reading.
/// The gesture must be a fast roll-rate spike followed by a settle, and it is
/// rate-limited to once every few seconds.
@MainActor
public final class WristMotionMonitor {
    public var onFlick: (() -> Void)?

    /// Roll rate, radians/second. Ordinary arm movement sits well below this.
    private let rateThreshold: Double = 3.2
    private let minimumInterval: TimeInterval = 4
    private var lastFiredAt = Date.distantPast

    #if canImport(CoreMotion)
    private let manager = CMMotionManager()
    #endif

    public init() {}

    public var isAvailable: Bool {
        #if canImport(CoreMotion)
        return manager.isDeviceMotionAvailable
        #else
        return false
        #endif
    }

    public func start() {
        #if canImport(CoreMotion)
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        // 20 Hz is enough to catch a flick and an order of magnitude cheaper
        // than the 100 Hz default.
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.consume(rotationRate: motion.rotationRate)
        }
        #endif
    }

    public func stop() {
        #if canImport(CoreMotion)
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        #endif
    }

    #if canImport(CoreMotion)
    private func consume(rotationRate: CMRotationRate) {
        // A raise rotates mostly about the forearm axis; requiring that axis
        // to dominate rejects general arm swing while walking.
        let dominant = abs(rotationRate.y)
        let others = max(abs(rotationRate.x), abs(rotationRate.z))
        guard dominant >= rateThreshold, dominant > others * 1.4 else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFiredAt) >= minimumInterval else { return }
        lastFiredAt = now
        onFlick?()
    }
    #endif
}
