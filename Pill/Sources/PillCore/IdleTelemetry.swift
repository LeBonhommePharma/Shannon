import Foundation

/// Pure decoration for the idle pill. Emits **no** entropy, no bits, and no
/// verdict.
///
/// ## What this used to be, and why it changed
///
/// This type used to synthesise `7.2 + 0.55*sin(2πt/6)` — a number in the
/// 6.65–7.75 bit range, tagged `collapsed: false` — whenever no detector was
/// attached. That meant a **dead** detector rendered as a permanently **healthy**
/// one: parked in the safe band, breathing convincingly, and structurally unable
/// to trip the collapse threshold no matter what the monitored agent did. For a
/// deception monitor that is the worst possible failure direction, so the
/// waveform no longer produces bits at all.
///
/// What survives is the part that was actually worth keeping: the notch pill is
/// an `LSUIElement` with no dock icon, and a completely static surface got
/// reported as "does nothing". `breath(at:)` keeps that surface alive with a
/// **unit-free** value in `0...1` — an opacity, a glow radius, a scale factor.
/// It is not a quantity of anything, it is never labelled with a unit, and it
/// must not reach any code that makes a safety judgement. `EntropyReading` is
/// the only thing allowed to feed those.
public struct IdleTelemetry: Sendable, Equatable {
    /// Breath period in seconds.
    public var period: TimeInterval
    /// Deterministic phase offset so two launches don't lock-step.
    public var phase: Double

    public init(period: TimeInterval = 6.0, phase: Double = 0) {
        self.period = max(period, 0.5)
        self.phase = phase
    }

    /// Unit-free animation value in `0...1` at absolute time `t`.
    ///
    /// Deliberately normalised: any consumer that tried to render this as a
    /// bit-count would produce an obviously wrong sub-1-bit figure rather than a
    /// plausible one, which is the point. There is no scale, offset or baseline
    /// parameter that could move it back into the plausible-entropy band.
    public func breath(at t: TimeInterval) -> Double {
        let omega = 2.0 * Double.pi / period
        return (sin(omega * t + phase) + 1.0) / 2.0
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

    /// Legacy wire-shaped sentinel for call sites still typed on
    /// `ShannonStatus`. **Not a reading** — see `IdleTelemetryPublisher.status`.
    ///
    /// `entropy` is `0`, which is not a plausible measurement and which every
    /// existing renderer already guards against (`if entropy.entropy > 0`), and
    /// `backend` is `"absent"`, which is in `ShannonStatus.syntheticBackends`.
    /// The consequence is that `measuredCollapsed` is `nil` and
    /// `EntropyProvenance.resolve` maps this to `.absent`, so the `collapsed:
    /// false` the struct is obliged to carry can never be read as a verdict.
    public static let absentStatus = ShannonStatus(
        entropy: 0,
        deltaH: 0,
        collapsed: false,
        tokenCount: 0,
        backend: "absent",
        agent: nil
    )
}

/// Publishes the idle *decoration* on a timer for SwiftUI, plus the explicit
/// "no detector attached" reading.
///
/// Nothing here measures anything, and nothing here can be mistaken for a
/// measurement: `reading` is always `.absent(.noDetector)`, which carries no
/// number by construction.
@MainActor
public final class IdleTelemetryPublisher: ObservableObject {
    /// Unit-free animation value in `0...1`. Decoration only.
    @Published public private(set) var breath: Double

    /// Always `.absent(.noDetector)`. Present so a view can bind to the honest
    /// state directly instead of inferring it from a placeholder number.
    public let reading: EntropyReading = .absent(.noDetector)

    /// Legacy compatibility shim for call sites still typed on `ShannonStatus`.
    ///
    /// Constant, and deliberately **not** `@Published`: there is no telemetry
    /// here to publish. It returns `IdleTelemetry.absentStatus`, so a caller
    /// doing `bridge.status ?? idle.status` gets an explicitly synthetic,
    /// zero-valued sentinel rather than a fabricated healthy reading. New code
    /// must use `reading` (or `EntropyProvenance.resolve`) — this exists only so
    /// the remaining view call site keeps compiling while it migrates.
    public var status: ShannonStatus { IdleTelemetry.absentStatus }

    private let telemetry: IdleTelemetry
    private var timer: Timer?
    private let interval: TimeInterval

    public init(telemetry: IdleTelemetry = .defaultSeeded(), interval: TimeInterval = 1.0) {
        self.telemetry = telemetry
        self.interval = interval
        self.breath = telemetry.breath(at: Date().timeIntervalSinceReferenceDate)
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
        breath = telemetry.breath(at: Date().timeIntervalSinceReferenceDate)
    }
}
