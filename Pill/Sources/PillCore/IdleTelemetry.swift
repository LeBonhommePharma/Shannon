import Foundation

/// Self-contained entropy-style readout used when the Python bridge is offline.
///
/// The notch pill is an agent app (`LSUIElement`) with no dock icon. Without a
/// live socket it used to collapse to the static label "Shannon" on a near-
/// invisible translucent slab — users reported "does nothing". Idle telemetry
/// keeps a calm, breathing H readout so the surface is always alive and the
/// menu-bar status item can show the same number.
public struct IdleTelemetry: Sendable, Equatable {
    /// Base entropy bits when fully at rest (calm, mid-vocab baseline).
    public var baseEntropy: Double
    /// Peak-to-peak amplitude of the slow breath (bits).
    public var amplitude: Double
    /// Breath period in seconds.
    public var period: TimeInterval
    /// Deterministic phase offset so two launches don't lock-step.
    public var phase: Double

    public init(
        baseEntropy: Double = 7.2,
        amplitude: Double = 0.55,
        period: TimeInterval = 6.0,
        phase: Double = 0
    ) {
        self.baseEntropy = baseEntropy
        self.amplitude = amplitude
        self.period = max(period, 0.5)
        self.phase = phase
    }

    /// Entropy at absolute time `t` (seconds since reference date).
    public func entropy(at t: TimeInterval) -> Double {
        let omega = 2.0 * Double.pi / period
        let wave = sin(omega * t + phase)
        return baseEntropy + amplitude * wave
    }

    /// Finite difference delta over one second of the breath.
    public func deltaH(at t: TimeInterval) -> Double {
        entropy(at: t) - entropy(at: t - 1.0)
    }

    /// Project into the same wire schema the live bridge uses.
    public func status(at t: TimeInterval = Date().timeIntervalSinceReferenceDate) -> ShannonStatus {
        let h = entropy(at: t)
        let d = deltaH(at: t)
        return ShannonStatus(
            entropy: h,
            deltaH: d,
            collapsed: false,
            tokenCount: 0,
            backend: "idle",
            agent: "local"
        )
    }

    /// Seed phase from a stable machine identifier so restarts feel continuous.
    public static func defaultSeeded() -> IdleTelemetry {
        var hasher = Hasher()
        hasher.combine(ProcessInfo.processInfo.hostName)
        hasher.combine("shannon-pill-idle")
        let hash = hasher.finalize()
        let phase = Double(abs(hash % 1000)) / 1000.0 * 2.0 * Double.pi
        return IdleTelemetry(phase: phase)
    }
}

/// Publishes idle telemetry on a timer for SwiftUI. Stopped automatically when
/// the live bridge connects so the real agent takes over.
@MainActor
public final class IdleTelemetryPublisher: ObservableObject {
    @Published public private(set) var status: ShannonStatus

    private let telemetry: IdleTelemetry
    private var timer: Timer?
    private let interval: TimeInterval

    public init(telemetry: IdleTelemetry = .defaultSeeded(), interval: TimeInterval = 1.0) {
        self.telemetry = telemetry
        self.interval = interval
        self.status = telemetry.status()
    }

    public func start() {
        tick()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        status = telemetry.status()
    }
}
