import Foundation
import Combine

// MARK: - Live preferences store (ObservableObject)

/// Main-actor store the Settings UI binds to. Persists on every change via
/// `ShannonPreferences` pure helpers.
@MainActor
public final class ShannonPreferencesStore: ObservableObject {
    @Published public var autoKeepAwakeWithAgents: Bool {
        didSet {
            guard autoKeepAwakeWithAgents != oldValue else { return }
            ShannonPreferences.setAutoKeepAwakeWithAgents(autoKeepAwakeWithAgents, defaults: defaults)
            onAutoKeepAwakeChanged?(autoKeepAwakeWithAgents)
        }
    }

    @Published public var expandPillOnLaunch: Bool {
        didSet {
            guard expandPillOnLaunch != oldValue else { return }
            ShannonPreferences.setExpandPillOnLaunch(expandPillOnLaunch, defaults: defaults)
        }
    }

    @Published public var startWithMonitoringPaused: Bool {
        didSet {
            guard startWithMonitoringPaused != oldValue else { return }
            ShannonPreferences.setStartWithMonitoringPaused(startWithMonitoringPaused, defaults: defaults)
        }
    }

    /// Codex package id for the floating desktop companion.
    @Published public var desktopPetId: String {
        didSet {
            let normalized = ShannonPreferences.normalizeDesktopPetId(desktopPetId)
            if normalized != desktopPetId {
                desktopPetId = normalized
                return
            }
            guard desktopPetId != oldValue else { return }
            ShannonPreferences.setDesktopPetId(desktopPetId, defaults: defaults)
            onDesktopPetIdChanged?(desktopPetId)
        }
    }

    @Published public var showDesktopCompanion: Bool {
        didSet {
            guard showDesktopCompanion != oldValue else { return }
            ShannonPreferences.setShowDesktopCompanion(showDesktopCompanion, defaults: defaults)
            onShowDesktopCompanionChanged?(showDesktopCompanion)
        }
    }

    /// UX-058: floating fleet/usage glance panel (default off).
    @Published public var showFloatingGlance: Bool {
        didSet {
            guard showFloatingGlance != oldValue else { return }
            ShannonPreferences.setShowFloatingGlance(showFloatingGlance, defaults: defaults)
            onShowFloatingGlanceChanged?(showFloatingGlance)
        }
    }

    /// ENH-030: Mac voice callouts for needs-you / task_complete (default off).
    @Published public var voiceCalloutsEnabled: Bool {
        didSet {
            guard voiceCalloutsEnabled != oldValue else { return }
            ShannonPreferences.setVoiceCalloutsEnabled(voiceCalloutsEnabled, defaults: defaults)
        }
    }

    @Published public private(set) var firstRunDone: Bool

    /// Optional sink so KeepAwakeMonitor stays in sync without polling.
    public var onAutoKeepAwakeChanged: ((Bool) -> Void)?
    /// Optional sink so desktop companion re-resolves package on picker change.
    public var onDesktopPetIdChanged: ((String) -> Void)?
    /// Optional sink so the floating desktop companion show/hide tracks Settings/menu.
    public var onShowDesktopCompanionChanged: ((Bool) -> Void)?
    /// Optional sink so the floating fleet/usage glance show/hide tracks Settings.
    public var onShowFloatingGlanceChanged: ((Bool) -> Void)?

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let snap = ShannonPreferences.load(defaults: defaults)
        self.autoKeepAwakeWithAgents = snap.autoKeepAwakeWithAgents
        self.expandPillOnLaunch = snap.expandPillOnLaunch
        self.startWithMonitoringPaused = snap.startWithMonitoringPaused
        self.desktopPetId = snap.desktopPetId
        self.showDesktopCompanion = snap.showDesktopCompanion
        self.showFloatingGlance = snap.showFloatingGlance
        self.voiceCalloutsEnabled = snap.voiceCalloutsEnabled
        self.firstRunDone = snap.firstRunDone
    }

    public func reload() {
        let snap = ShannonPreferences.load(defaults: defaults)
        autoKeepAwakeWithAgents = snap.autoKeepAwakeWithAgents
        expandPillOnLaunch = snap.expandPillOnLaunch
        startWithMonitoringPaused = snap.startWithMonitoringPaused
        desktopPetId = snap.desktopPetId
        showDesktopCompanion = snap.showDesktopCompanion
        showFloatingGlance = snap.showFloatingGlance
        voiceCalloutsEnabled = snap.voiceCalloutsEnabled
        firstRunDone = snap.firstRunDone
    }

    public func resetFirstRunCoach() {
        ShannonPreferences.resetFirstRunCoach(defaults: defaults)
        firstRunDone = false
    }

    public func markFirstRunDone() {
        ShannonPreferences.setFirstRunDone(true, defaults: defaults)
        firstRunDone = true
    }

    /// Snapshot for tests / export.
    public var snapshot: ShannonPreferences.Snapshot {
        ShannonPreferences.Snapshot(
            autoKeepAwakeWithAgents: autoKeepAwakeWithAgents,
            firstRunDone: firstRunDone,
            expandPillOnLaunch: expandPillOnLaunch,
            startWithMonitoringPaused: startWithMonitoringPaused,
            showDesktopCompanion: showDesktopCompanion,
            desktopPetId: desktopPetId,
            showFloatingGlance: showFloatingGlance,
            voiceCalloutsEnabled: voiceCalloutsEnabled
        )
    }
}
