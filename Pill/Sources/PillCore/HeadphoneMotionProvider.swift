import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

/// Head-tracking source backed by AirPods via CoreMotion.
///
/// Availability notes, both verified against the macOS 27 SDK:
///
///  * `CMHeadphoneMotionManager` is `API_AVAILABLE(macos(14.0), ios(14.0),
///    watchos(7.0))` — **macOS 14 Sonoma**, not macOS 11. The pill targets
///    macOS 13, so this whole type is `@available`-gated and the app falls
///    back to `UnavailableHeadphoneMotionProvider` on Ventura.
///  * It needs **no special entitlement**. Access is ordinary TCC consent
///    reported through `CMAuthorizationStatus`, driven by the
///    `NSMotionUsageDescription` key in Info.plist. (Within CoreMotion only
///    `CMFallDetectionManager` requires an Apple-granted entitlement.)
///
/// Requires AirPods (Pro / 3rd gen / Max) or Beats with the H1/H2 chip,
/// connected and in-ear. `isAvailable` covers all of those failure modes.
@available(macOS 14.0, *)
public final class HeadphoneMotionProvider: NSObject, HeadphoneMotionProviding {
    #if canImport(CoreMotion)
    private let manager = CMHeadphoneMotionManager()
    #endif
    private let queue = OperationQueue()

    public override init() {
        super.init()
        queue.name = "com.lebonhomme.shannon.pill.headmotion"
        queue.maxConcurrentOperationCount = 1
    }

    public var isAvailable: Bool {
        #if canImport(CoreMotion)
        guard CMHeadphoneMotionManager.authorizationStatus() != .denied,
              CMHeadphoneMotionManager.authorizationStatus() != .restricted
        else { return false }
        return manager.isDeviceMotionAvailable
        #else
        return false
        #endif
    }

    public var authorizationDescription: String {
        #if canImport(CoreMotion)
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .notDetermined: return "motion access not yet requested"
        case .restricted:    return "motion access restricted by policy"
        case .denied:        return "motion access denied in System Settings > Privacy & Security > Motion & Fitness"
        case .authorized:    return manager.isDeviceMotionAvailable
                                    ? "authorized"
                                    : "authorized, but no head-tracking headphones connected"
        @unknown default:    return "unknown authorization state"
        }
        #else
        return "CoreMotion unavailable"
        #endif
    }

    public func start(onSample: @escaping (HeadAttitudeSample) -> Void) {
        #if canImport(CoreMotion)
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: queue) { motion, _ in
            guard let motion else { return }
            let attitude = motion.attitude
            onSample(HeadAttitudeSample(
                pitch: attitude.pitch,
                yaw: attitude.yaw,
                roll: attitude.roll,
                timestamp: motion.timestamp
            ))
        }
        #endif
    }

    public func stop() {
        #if canImport(CoreMotion)
        if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
        #endif
    }
}

/// Stand-in on macOS 13, where `CMHeadphoneMotionManager` does not exist.
public final class UnavailableHeadphoneMotionProvider: HeadphoneMotionProviding {
    public var isAvailable: Bool { false }
    public var authorizationDescription: String {
        "head gestures require macOS 14 Sonoma or later"
    }
    public init() {}
    public func start(onSample: @escaping (HeadAttitudeSample) -> Void) {}
    public func stop() {}
}

/// Picks the best available source for the running OS.
public func makeHeadphoneMotionProvider() -> HeadphoneMotionProviding {
    if #available(macOS 14.0, *) {
        return HeadphoneMotionProvider()
    }
    return UnavailableHeadphoneMotionProvider()
}
