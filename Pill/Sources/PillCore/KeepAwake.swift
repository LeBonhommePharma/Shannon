import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
#endif

// MARK: - Native keep-awake (caffeinate-class)
//
// Primary path for “don’t sleep while agents are busy” — same job as
// `caffeinate -dims` / nohup session hold: prevent idle and display sleep
// while Shannon is monitoring work. Does **not** require Amphetamine.app.

/// Snapshot of the native keep-awake session.
public struct KeepAwakeSession: Sendable, Equatable {
    public var isActive: Bool
    /// Seconds remaining when finite; `nil` when inactive or indefinite.
    public var secondsRemaining: Int?
    public var isIndefinite: Bool
    /// Whether the display is held awake (caffeinate -d equivalent).
    public var displayHeld: Bool
    public var backend: Backend
    public var detail: String?

    public enum Backend: String, Sendable, Equatable {
        /// IOPMAssertion (preferred) or caffeinate subprocess.
        case native
        /// Amphetamine.app optional fallback.
        case amphetamine
        case unavailable
    }

    public init(
        isActive: Bool = false,
        secondsRemaining: Int? = nil,
        isIndefinite: Bool = false,
        displayHeld: Bool = true,
        backend: Backend = .native,
        detail: String? = nil
    ) {
        self.isActive = isActive
        self.secondsRemaining = secondsRemaining
        self.isIndefinite = isIndefinite
        self.displayHeld = displayHeld
        self.backend = backend
        self.detail = detail
    }

    /// Compact menu / popover label — lists the main feature (caffeinate hold).
    public var shortLabel: String {
        if backend == .unavailable {
            return "Keep awake: unavailable"
        }
        if !isActive {
            return "Keep awake: off"
        }
        if isIndefinite {
            return displayHeld ? "Keep awake: ∞ (no sleep/display)" : "Keep awake: ∞ (no idle sleep)"
        }
        if let s = secondsRemaining {
            return "Keep awake: \(AmphetamineSession.formatDuration(s))"
        }
        return "Keep awake: on"
    }
}

// MARK: - Pure policy (unit-tested)

public enum KeepAwakeLogic {
    /// Auto-start when agents become busy.
    public static func shouldAutoStart(
        agentsBusy: Bool,
        sessionActive: Bool,
        autoEnabled: Bool
    ) -> Bool {
        autoEnabled && agentsBusy && !sessionActive
    }

    /// Auto-end when agents go idle.
    public static func shouldAutoEnd(
        agentsBusy: Bool,
        sessionActive: Bool,
        autoEnabled: Bool
    ) -> Bool {
        autoEnabled && !agentsBusy && sessionActive
    }

    /// Remaining seconds for a timed session started at `startedAt` for `duration`.
    public static func secondsRemaining(
        startedAt: Date,
        duration: TimeInterval,
        now: Date = Date()
    ) -> Int? {
        guard duration > 0 else { return nil }
        let left = duration - now.timeIntervalSince(startedAt)
        return max(0, Int(left.rounded(.down)))
    }

    /// Whether a timed session has expired.
    public static func isExpired(
        startedAt: Date,
        duration: TimeInterval?,
        now: Date = Date()
    ) -> Bool {
        guard let duration, duration > 0 else { return false }
        return now.timeIntervalSince(startedAt) >= duration
    }
}

// MARK: - IOPM / caffeinate runner

/// Creates a system sleep assertion equivalent to `caffeinate -dims`.
public enum KeepAwakeRunner {
    public enum Error: Swift.Error, Equatable {
        case assertionFailed(Int32)
        case processFailed(String)
    }

    #if canImport(IOKit)
    /// Create NoIdleSleep (+ optional NoDisplaySleep). Same intent as
    /// `caffeinate -i` / `caffeinate -dims`.
    public static func createAssertions(
        holdDisplay: Bool = true,
        reason: String = "Shannon: agents busy"
    ) -> Result<(idle: UInt32, display: UInt32), Error> {
        var idleID: IOPMAssertionID = 0
        let reasonCF = reason as CFString
        let idleType = kIOPMAssertionTypeNoIdleSleep as CFString
        let level = IOPMAssertionLevel(kIOPMAssertionLevelOn)

        let r1 = IOPMAssertionCreateWithName(idleType, level, reasonCF, &idleID)
        guard r1 == kIOReturnSuccess else {
            return .failure(.assertionFailed(r1))
        }
        var displayID: IOPMAssertionID = 0
        if holdDisplay {
            let displayType = kIOPMAssertionTypeNoDisplaySleep as CFString
            let r2 = IOPMAssertionCreateWithName(displayType, level, reasonCF, &displayID)
            if r2 != kIOReturnSuccess {
                IOPMAssertionRelease(idleID)
                return .failure(.assertionFailed(r2))
            }
        }
        return .success((UInt32(idleID), UInt32(displayID)))
    }

    public static func releaseAssertions(idle: UInt32, display: UInt32) {
        if idle != 0 { IOPMAssertionRelease(IOPMAssertionID(idle)) }
        if display != 0 { IOPMAssertionRelease(IOPMAssertionID(display)) }
    }
    #endif

    /// Fallback: spawn `/usr/bin/caffeinate -dims` until killed.
    public static func startCaffeinateProcess() -> Result<Process, Error> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -d display, -i idle, -m disk, -s system (when on AC)
        p.arguments = ["-dims"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            return .success(p)
        } catch {
            return .failure(.processFailed(error.localizedDescription))
        }
    }
}

// MARK: - Live monitor (primary keep-awake)

@MainActor
public final class KeepAwakeMonitor: ObservableObject {
    @Published public private(set) var session = KeepAwakeSession()
    /// Auto-hold while any agent is busy (same role as Amphetamine auto toggle).
    @Published public var autoKeepAwakeWithAgents: Bool = true

    private var idleAssertion: UInt32 = 0
    private var displayAssertion: UInt32 = 0
    private var caffeinateProcess: Process?
    private var startedAt: Date?
    private var duration: TimeInterval?
    private var timer: Timer?
    private var hadAgentsBusy = false

    public init() {}

    public func start(interval: TimeInterval = 5.0) {
        refresh()
        let t = Timer(timeInterval: max(2, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = interval * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        endSession()
    }

    public func refresh() {
        if session.isActive,
           KeepAwakeLogic.isExpired(startedAt: startedAt ?? .distantPast, duration: duration) {
            endSession()
            return
        }
        if session.isActive, let start = startedAt, let dur = duration, dur > 0 {
            let left = KeepAwakeLogic.secondsRemaining(startedAt: start, duration: dur)
            // Publish every second-boundary change so shortLabel (formatDuration
            // with "m s") stays honest through the last minute. Layout thrash is
            // suppressed in the popover/pill transaction layer — do not freeze
            // the countdown here (minute bucketing left e.g. "1m 30s" stuck at 61s).
            if session.secondsRemaining != left {
                session.secondsRemaining = left
            }
        }
    }

    private func tick() {
        refresh()
    }

    /// Start a timed or indefinite keep-awake session (native first).
    public func startSession(durationHours: Double? = 2.0, holdDisplay: Bool = true) {
        endSession()
        #if canImport(IOKit)
        switch KeepAwakeRunner.createAssertions(holdDisplay: holdDisplay) {
        case .success(let ids):
            idleAssertion = ids.idle
            displayAssertion = ids.display
            startedAt = Date()
            if let h = durationHours, h > 0 {
                duration = h * 3600
                session = KeepAwakeSession(
                    isActive: true,
                    secondsRemaining: Int(h * 3600),
                    isIndefinite: false,
                    displayHeld: holdDisplay,
                    backend: .native,
                    detail: "IOPMAssertion ≈ caffeinate -dims"
                )
            } else {
                duration = nil
                session = KeepAwakeSession(
                    isActive: true,
                    isIndefinite: true,
                    displayHeld: holdDisplay,
                    backend: .native,
                    detail: "IOPMAssertion ≈ caffeinate -dims"
                )
            }
            return
        case .failure:
            break
        }
        #endif
        // Fallback: caffeinate subprocess
        switch KeepAwakeRunner.startCaffeinateProcess() {
        case .success(let proc):
            caffeinateProcess = proc
            startedAt = Date()
            if let h = durationHours, h > 0 {
                duration = h * 3600
                session = KeepAwakeSession(
                    isActive: true,
                    secondsRemaining: Int(h * 3600),
                    isIndefinite: false,
                    displayHeld: true,
                    backend: .native,
                    detail: "caffeinate -dims"
                )
            } else {
                duration = nil
                session = KeepAwakeSession(
                    isActive: true,
                    isIndefinite: true,
                    displayHeld: true,
                    backend: .native,
                    detail: "caffeinate -dims"
                )
            }
        case .failure(let err):
            session = KeepAwakeSession(
                isActive: false,
                backend: .unavailable,
                detail: String(describing: err)
            )
        }
    }

    public func endSession() {
        #if canImport(IOKit)
        if idleAssertion != 0 || displayAssertion != 0 {
            KeepAwakeRunner.releaseAssertions(idle: idleAssertion, display: displayAssertion)
            idleAssertion = 0
            displayAssertion = 0
        }
        #endif
        if let p = caffeinateProcess, p.isRunning {
            p.terminate()
        }
        caffeinateProcess = nil
        startedAt = nil
        duration = nil
        session = KeepAwakeSession(isActive: false, backend: .native)
    }

    /// Auto keep-awake while agents busy (no Amphetamine required).
    public func syncWithAgents(busyCount: Int) {
        let busy = busyCount > 0
        if KeepAwakeLogic.shouldAutoStart(
            agentsBusy: busy,
            sessionActive: session.isActive,
            autoEnabled: autoKeepAwakeWithAgents
        ) {
            startSession(durationHours: 2.0, holdDisplay: true)
        } else if KeepAwakeLogic.shouldAutoEnd(
            agentsBusy: busy,
            sessionActive: session.isActive,
            autoEnabled: autoKeepAwakeWithAgents
        ), hadAgentsBusy {
            endSession()
        }
        hadAgentsBusy = busy
    }
}
