import Foundation
import ShannonCore
#if canImport(CoreMotion)
import CoreMotion
#endif

/// AirPods head-tracking source for the iPhone, feeding the same
/// `HeadGestureDetector` (and therefore the same thresholds and 2 s debounce)
/// that the Mac pill uses.
///
/// Nod confirms, shake denies. The manager is only started while a question is
/// pending: CoreMotion updates cost battery, and a detector running in the
/// background is exactly how false positives happen.
@MainActor
public final class HeadGestureListener {
    #if canImport(CoreMotion)
    private let manager = CMHeadphoneMotionManager()
    #endif
    private var detector = HeadGestureDetector()
    private var onGesture: ((HeadGesture) -> Void)?

    public init() {}

    public var isAvailable: Bool {
        #if canImport(CoreMotion)
        return manager.isDeviceMotionAvailable
        #else
        return false
        #endif
    }

    /// True when the user has denied motion access, so the UI can explain why
    /// nodding does nothing rather than appearing broken.
    public var isDenied: Bool {
        #if canImport(CoreMotion)
        return CMHeadphoneMotionManager.authorizationStatus() == .denied
        #else
        return false
        #endif
    }

    public private(set) var isArmed = false

    public func arm(_ handler: @escaping (HeadGesture) -> Void) {
        guard isAvailable, !isArmed else { return }
        onGesture = handler
        detector = HeadGestureDetector()
        detector.arm()
        isArmed = true

        #if canImport(CoreMotion)
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let attitude = motion.attitude
            let sample = HeadAttitudeSample(
                pitch: attitude.pitch,
                yaw: attitude.yaw,
                roll: attitude.roll,
                timestamp: motion.timestamp
            )
            if let gesture = self.detector.process(sample) {
                self.onGesture?(gesture)
            }
        }
        #endif
    }

    public func disarm() {
        guard isArmed else { return }
        isArmed = false
        detector.disarm()
        onGesture = nil
        #if canImport(CoreMotion)
        manager.stopDeviceMotionUpdates()
        #endif
    }
}
