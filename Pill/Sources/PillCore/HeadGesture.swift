import Foundation

/// One attitude sample from a head-tracked device, in radians.
///
/// Timestamps are supplied by the caller rather than read from the clock, so
/// the detector is deterministic under test.
public struct HeadAttitudeSample: Sendable, Equatable {
    public var pitch: Double
    public var yaw: Double
    public var roll: Double
    public var timestamp: TimeInterval

    public init(pitch: Double, yaw: Double, roll: Double = 0, timestamp: TimeInterval) {
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
        self.timestamp = timestamp
    }
}

public enum HeadGesture: String, Sendable, Equatable {
    case nod    // pitch excursion and back -> confirm
    case shake  // yaw excursion and back   -> deny
}

public struct HeadGestureConfig: Sendable, Equatable {
    /// Excursion required to start a candidate gesture.
    public var thresholdRadians: Double
    /// Must return inside this band of neutral to complete the gesture.
    public var returnBandRadians: Double
    /// Maximum time from leaving neutral to returning.
    public var maxDuration: TimeInterval
    /// Silence after a fired gesture, so one nod cannot answer two prompts.
    public var lockout: TimeInterval

    public init(
        thresholdDegrees: Double = 15,
        returnBandFraction: Double = 0.4,
        maxDuration: TimeInterval = 0.8,
        lockout: TimeInterval = 2.0
    ) {
        let threshold = thresholdDegrees * .pi / 180
        self.thresholdRadians = threshold
        self.returnBandRadians = threshold * returnBandFraction
        self.maxDuration = maxDuration
        self.lockout = lockout
    }

    public static let `default` = HeadGestureConfig()
}

/// Recognises a single nod or shake from a stream of head-attitude samples.
///
/// Two design points that matter:
///
///  * **Relative, not absolute.** A user's head is rarely level, and AirPods
///    report attitude against their own reference frame. Neutral is captured
///    when the detector is armed, and every excursion is measured against
///    that, so a head tilted 20° down at rest does not read as a permanent nod.
///  * **Disarmed by default.** `arm()` is called only while the pill is
///    actually awaiting an answer. Samples fed while disarmed are dropped, so
///    ordinary head movement can never fire a confirmation.
public struct HeadGestureDetector: Sendable {

    private enum Phase: Sendable, Equatable {
        case disarmed
        case neutral
        /// Left the neutral band on `axis` at `startedAt`.
        case excursion(axis: HeadGesture, startedAt: TimeInterval, peak: Double)
    }

    public let config: HeadGestureConfig
    private var phase: Phase = .disarmed
    private var reference: HeadAttitudeSample?
    private var lockoutUntil: TimeInterval = -.infinity

    public init(config: HeadGestureConfig = .default) {
        self.config = config
    }

    public var isArmed: Bool { phase != .disarmed }

    /// Begin listening. The next sample establishes the neutral reference.
    public mutating func arm() {
        phase = .neutral
        reference = nil
    }

    /// Stop listening and forget any in-flight excursion.
    public mutating func disarm() {
        phase = .disarmed
        reference = nil
    }

    /// Feed one sample. Returns a gesture only on the completing sample.
    public mutating func process(_ sample: HeadAttitudeSample) -> HeadGesture? {
        guard phase != .disarmed else { return nil }

        // First sample after arming defines neutral.
        guard let reference else {
            self.reference = sample
            return nil
        }

        // Debounce window: keep tracking neutral but never fire.
        if sample.timestamp < lockoutUntil {
            phase = .neutral
            return nil
        }

        let dPitch = Self.angleDelta(sample.pitch, reference.pitch)
        let dYaw = Self.angleDelta(sample.yaw, reference.yaw)

        switch phase {
        case .disarmed:
            return nil

        case .neutral:
            let pitchOut = abs(dPitch) >= config.thresholdRadians
            let yawOut = abs(dYaw) >= config.thresholdRadians
            guard pitchOut || yawOut else { return nil }
            // Ambiguous movement resolves to whichever axis moved further,
            // so a nod with a little sway still reads as a nod.
            let axis: HeadGesture = abs(dPitch) >= abs(dYaw) ? .nod : .shake
            let peak = axis == .nod ? abs(dPitch) : abs(dYaw)
            phase = .excursion(axis: axis, startedAt: sample.timestamp, peak: peak)
            return nil

        case .excursion(let axis, let startedAt, let peak):
            let current = axis == .nod ? abs(dPitch) : abs(dYaw)

            // Too slow to be a deliberate gesture: abandon and re-baseline.
            if sample.timestamp - startedAt > config.maxDuration {
                phase = .neutral
                return nil
            }

            if current <= config.returnBandRadians {
                phase = .neutral
                lockoutUntil = sample.timestamp + config.lockout
                return axis
            }

            phase = .excursion(axis: axis, startedAt: startedAt, peak: max(peak, current))
            return nil
        }
    }

    /// Shortest signed difference between two angles, wrapped to (-pi, pi].
    /// Without this a yaw crossing the +/-pi seam reads as a full-circle jump.
    static func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }
}

// MARK: - Motion source

public protocol HeadphoneMotionProviding: AnyObject {
    /// False when no head-tracking device is connected, the OS is too old, or
    /// the user declined motion access.
    var isAvailable: Bool { get }
    var authorizationDescription: String { get }
    func start(onSample: @escaping (HeadAttitudeSample) -> Void)
    func stop()
}

/// Deterministic source for tests and `--demo`.
public final class StubHeadphoneMotionProvider: HeadphoneMotionProviding {
    private var handler: ((HeadAttitudeSample) -> Void)?
    public var isAvailable: Bool = true
    public var authorizationDescription: String { "stub" }
    public private(set) var isRunning = false

    public init() {}

    public func start(onSample: @escaping (HeadAttitudeSample) -> Void) {
        handler = onSample
        isRunning = true
    }

    public func stop() {
        handler = nil
        isRunning = false
    }

    public func emit(_ sample: HeadAttitudeSample) { handler?(sample) }
}
