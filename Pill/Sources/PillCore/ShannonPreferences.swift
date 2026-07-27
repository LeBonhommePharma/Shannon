import Foundation

// MARK: - Shannon preferences (pure store)

/// Product preferences the menubar Settings window and live monitors share.
///
/// Pure load/save over injectable `UserDefaults` so unit tests never need
/// AppKit. Only keys the app actually honors are exposed — no decorative
/// toggles that do nothing.
public enum ShannonPreferences {
    public enum Key: String, Sendable, CaseIterable {
        /// Auto IOPM keep-awake while any agent is busy.
        case autoKeepAwakeWithAgents = "shannon.prefs.autoKeepAwakeWithAgents"
        /// When true, first-run coach was dismissed (same key as FirstRunCoach).
        case firstRunDone = "shannon.pill.firstRunDone"
        /// Show the expanded notch board briefly on launch (hello flash).
        case expandPillOnLaunch = "shannon.prefs.expandPillOnLaunch"
        /// Pause agent monitoring after launch (user must resume).
        case startWithMonitoringPaused = "shannon.prefs.startWithMonitoringPaused"
        /// Floating desktop companion (pet + bubble). Default on; menu/Settings can hide.
        case showDesktopCompanion = "shannon.prefs.showDesktopCompanion"
        /// Codex package id for the floating desktop companion (default "shannon").
        case desktopPetId = "shannon.prefs.desktopPetId"
        /// Floating fleet/usage glance panel (UX-058). Default **off** (opt-in).
        case showFloatingGlance = "shannon.prefs.showFloatingGlance"
        /// Mac voice callouts for needs-you / task_complete (ENH-030). Default **off**.
        case voiceCalloutsEnabled = "shannon.prefs.voiceCalloutsEnabled"
    }

    /// Snapshot of all product preferences (value type for UI + tests).
    public struct Snapshot: Sendable, Equatable {
        public var autoKeepAwakeWithAgents: Bool
        public var firstRunDone: Bool
        public var expandPillOnLaunch: Bool
        public var startWithMonitoringPaused: Bool
        public var showDesktopCompanion: Bool
        /// Package id used by the desktop companion surface.
        public var desktopPetId: String
        /// Pref-gated Mac floating fleet/usage glance (UX-058). Default off.
        public var showFloatingGlance: Bool
        /// Pref-gated Mac voice callouts (ENH-030). Default off (noise-safe).
        public var voiceCalloutsEnabled: Bool

        public init(
            autoKeepAwakeWithAgents: Bool = true,
            firstRunDone: Bool = false,
            expandPillOnLaunch: Bool = true,
            startWithMonitoringPaused: Bool = false,
            // Default off — always-on-top pet is opt-in (was too invasive on first run).
            showDesktopCompanion: Bool = false,
            desktopPetId: String = PetPackageResolver.defaultPetId,
            showFloatingGlance: Bool = false,
            voiceCalloutsEnabled: Bool = false
        ) {
            self.autoKeepAwakeWithAgents = autoKeepAwakeWithAgents
            self.firstRunDone = firstRunDone
            self.expandPillOnLaunch = expandPillOnLaunch
            self.startWithMonitoringPaused = startWithMonitoringPaused
            self.showDesktopCompanion = showDesktopCompanion
            self.desktopPetId = ShannonPreferences.normalizeDesktopPetId(desktopPetId)
            self.showFloatingGlance = showFloatingGlance
            self.voiceCalloutsEnabled = voiceCalloutsEnabled
        }
    }

    /// Factory defaults when a key has never been written.
    public static let factoryDefaults = Snapshot()

    /// Empty / whitespace → default package id (`shannon`).
    public static func normalizeDesktopPetId(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PetPackageResolver.defaultPetId : trimmed
    }


    // MARK: Load / save

    public static func load(defaults: UserDefaults = .standard) -> Snapshot {
        Snapshot(
            autoKeepAwakeWithAgents: bool(
                defaults,
                key: .autoKeepAwakeWithAgents,
                fallback: factoryDefaults.autoKeepAwakeWithAgents
            ),
            firstRunDone: defaults.bool(forKey: Key.firstRunDone.rawValue),
            expandPillOnLaunch: bool(
                defaults,
                key: .expandPillOnLaunch,
                fallback: factoryDefaults.expandPillOnLaunch
            ),
            startWithMonitoringPaused: bool(
                defaults,
                key: .startWithMonitoringPaused,
                fallback: factoryDefaults.startWithMonitoringPaused
            ),
            showDesktopCompanion: bool(
                defaults,
                key: .showDesktopCompanion,
                fallback: factoryDefaults.showDesktopCompanion
            ),
            desktopPetId: string(
                defaults,
                key: .desktopPetId,
                fallback: factoryDefaults.desktopPetId
            ),
            showFloatingGlance: bool(
                defaults,
                key: .showFloatingGlance,
                fallback: factoryDefaults.showFloatingGlance
            ),
            voiceCalloutsEnabled: bool(
                defaults,
                key: .voiceCalloutsEnabled,
                fallback: factoryDefaults.voiceCalloutsEnabled
            )
        )
    }

    public static func save(_ snap: Snapshot, defaults: UserDefaults = .standard) {
        defaults.set(snap.autoKeepAwakeWithAgents, forKey: Key.autoKeepAwakeWithAgents.rawValue)
        defaults.set(snap.firstRunDone, forKey: Key.firstRunDone.rawValue)
        defaults.set(snap.expandPillOnLaunch, forKey: Key.expandPillOnLaunch.rawValue)
        defaults.set(snap.startWithMonitoringPaused, forKey: Key.startWithMonitoringPaused.rawValue)
        defaults.set(snap.showDesktopCompanion, forKey: Key.showDesktopCompanion.rawValue)
        defaults.set(
            normalizeDesktopPetId(snap.desktopPetId),
            forKey: Key.desktopPetId.rawValue
        )
        defaults.set(snap.showFloatingGlance, forKey: Key.showFloatingGlance.rawValue)
        defaults.set(snap.voiceCalloutsEnabled, forKey: Key.voiceCalloutsEnabled.rawValue)
    }

    // MARK: Individual accessors (monitors call these)

    public static func autoKeepAwakeWithAgents(defaults: UserDefaults = .standard) -> Bool {
        bool(defaults, key: .autoKeepAwakeWithAgents, fallback: factoryDefaults.autoKeepAwakeWithAgents)
    }

    public static func setAutoKeepAwakeWithAgents(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: Key.autoKeepAwakeWithAgents.rawValue)
    }

    public static func expandPillOnLaunch(defaults: UserDefaults = .standard) -> Bool {
        bool(defaults, key: .expandPillOnLaunch, fallback: factoryDefaults.expandPillOnLaunch)
    }

    public static func setExpandPillOnLaunch(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: Key.expandPillOnLaunch.rawValue)
    }

    public static func startWithMonitoringPaused(defaults: UserDefaults = .standard) -> Bool {
        bool(
            defaults,
            key: .startWithMonitoringPaused,
            fallback: factoryDefaults.startWithMonitoringPaused
        )
    }

    public static func setStartWithMonitoringPaused(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: Key.startWithMonitoringPaused.rawValue)
    }

    public static func showDesktopCompanion(defaults: UserDefaults = .standard) -> Bool {
        bool(
            defaults,
            key: .showDesktopCompanion,
            fallback: factoryDefaults.showDesktopCompanion
        )
    }

    public static func setShowDesktopCompanion(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: Key.showDesktopCompanion.rawValue)
    }

    public static func desktopPetId(defaults: UserDefaults = .standard) -> String {
        string(defaults, key: .desktopPetId, fallback: factoryDefaults.desktopPetId)
    }

    public static func setDesktopPetId(_ value: String, defaults: UserDefaults = .standard) {
        defaults.set(normalizeDesktopPetId(value), forKey: Key.desktopPetId.rawValue)
    }

    public static func showFloatingGlance(defaults: UserDefaults = .standard) -> Bool {
        bool(
            defaults,
            key: .showFloatingGlance,
            fallback: factoryDefaults.showFloatingGlance
        )
    }

    public static func setShowFloatingGlance(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: Key.showFloatingGlance.rawValue)
    }

    public static func voiceCalloutsEnabled(defaults: UserDefaults = .standard) -> Bool {
        bool(
            defaults,
            key: .voiceCalloutsEnabled,
            fallback: factoryDefaults.voiceCalloutsEnabled
        )
    }

    public static func setVoiceCalloutsEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: Key.voiceCalloutsEnabled.rawValue)
    }

    public static func firstRunDone(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.firstRunDone.rawValue)
    }

    public static func setFirstRunDone(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: Key.firstRunDone.rawValue)
    }

    /// Reset first-run coach so tips show again (Settings “Reset tips”).
    public static func resetFirstRunCoach(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: Key.firstRunDone.rawValue)
    }

    // MARK: - Internals

    /// `UserDefaults.bool` returns false for missing keys — distinguish missing
    /// from explicit false via `object(forKey:)`.
    private static func bool(
        _ defaults: UserDefaults,
        key: Key,
        fallback: Bool
    ) -> Bool {
        if defaults.object(forKey: key.rawValue) == nil { return fallback }
        return defaults.bool(forKey: key.rawValue)
    }


    /// Missing / blank string → fallback (normalized package id).
    private static func string(
        _ defaults: UserDefaults,
        key: Key,
        fallback: String
    ) -> String {
        guard let raw = defaults.string(forKey: key.rawValue) else {
            return normalizeDesktopPetId(fallback)
        }
        return normalizeDesktopPetId(raw)
    }
}
