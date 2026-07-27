import XCTest
@testable import PillCore

/// Shipped preference store — defaults, round-trip, missing-key fallbacks.
final class ShannonPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "shannon.prefs.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFactoryDefaultsWhenEmpty() {
        let snap = ShannonPreferences.load(defaults: defaults)
        XCTAssertEqual(snap, ShannonPreferences.factoryDefaults)
        XCTAssertTrue(snap.autoKeepAwakeWithAgents)
        XCTAssertFalse(snap.firstRunDone)
        XCTAssertTrue(snap.expandPillOnLaunch)
        XCTAssertFalse(snap.startWithMonitoringPaused)
        // E2: desktop companion is opt-in (always-on-top pet was too invasive).
        XCTAssertFalse(snap.showDesktopCompanion)
        XCTAssertFalse(ShannonPreferences.showDesktopCompanion(defaults: defaults))
        // E1: desktop pet package defaults to shannon.
        XCTAssertEqual(snap.desktopPetId, PetPackageResolver.defaultPetId)
        XCTAssertEqual(ShannonPreferences.desktopPetId(defaults: defaults), "shannon")
        // UX-058: floating glance is opt-in (default off).
        XCTAssertFalse(snap.showFloatingGlance)
        XCTAssertFalse(ShannonPreferences.showFloatingGlance(defaults: defaults))
        // ENH-030: voice callouts opt-in (default off).
        XCTAssertFalse(snap.voiceCalloutsEnabled)
        XCTAssertFalse(ShannonPreferences.voiceCalloutsEnabled(defaults: defaults))
    }

    func testRoundTripSaveLoad() {
        var snap = ShannonPreferences.factoryDefaults
        snap.autoKeepAwakeWithAgents = false
        snap.expandPillOnLaunch = false
        snap.startWithMonitoringPaused = true
        snap.firstRunDone = true
        snap.showDesktopCompanion = false
        snap.desktopPetId = "firebear"
        snap.showFloatingGlance = true
        snap.voiceCalloutsEnabled = true
        ShannonPreferences.save(snap, defaults: defaults)
        let loaded = ShannonPreferences.load(defaults: defaults)
        XCTAssertEqual(loaded, snap)
        XCTAssertFalse(ShannonPreferences.autoKeepAwakeWithAgents(defaults: defaults))
        XCTAssertTrue(ShannonPreferences.startWithMonitoringPaused(defaults: defaults))
        XCTAssertFalse(ShannonPreferences.expandPillOnLaunch(defaults: defaults))
        XCTAssertTrue(ShannonPreferences.firstRunDone(defaults: defaults))
        XCTAssertFalse(ShannonPreferences.showDesktopCompanion(defaults: defaults))
        XCTAssertTrue(ShannonPreferences.showFloatingGlance(defaults: defaults))
        XCTAssertTrue(ShannonPreferences.voiceCalloutsEnabled(defaults: defaults))
    }

    /// E2: show desktop companion is opt-in; missing key defaults to hidden.
    func testShowDesktopCompanionDefaultAndToggle() {
        XCTAssertFalse(ShannonPreferences.showDesktopCompanion(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: ShannonPreferences.Key.showDesktopCompanion.rawValue))

        ShannonPreferences.setShowDesktopCompanion(true, defaults: defaults)
        XCTAssertNotNil(defaults.object(forKey: ShannonPreferences.Key.showDesktopCompanion.rawValue))
        XCTAssertTrue(ShannonPreferences.showDesktopCompanion(defaults: defaults))

        ShannonPreferences.setShowDesktopCompanion(false, defaults: defaults)
        XCTAssertFalse(ShannonPreferences.showDesktopCompanion(defaults: defaults))
    }


    /// E1: blank / whitespace desktop pet id normalizes to default package.
    func testDesktopPetIdNormalizeAndPersist() {
        XCTAssertEqual(ShannonPreferences.normalizeDesktopPetId(nil), "shannon")
        XCTAssertEqual(ShannonPreferences.normalizeDesktopPetId(""), "shannon")
        XCTAssertEqual(ShannonPreferences.normalizeDesktopPetId("  "), "shannon")
        XCTAssertEqual(ShannonPreferences.normalizeDesktopPetId(" grok "), "grok")

        ShannonPreferences.setDesktopPetId("  bonhomme  ", defaults: defaults)
        XCTAssertEqual(ShannonPreferences.desktopPetId(defaults: defaults), "bonhomme")
        XCTAssertEqual(
            defaults.string(forKey: ShannonPreferences.Key.desktopPetId.rawValue),
            "bonhomme"
        )

        ShannonPreferences.setDesktopPetId("", defaults: defaults)
        XCTAssertEqual(ShannonPreferences.desktopPetId(defaults: defaults), "shannon")
    }

    func testExplicitFalseIsNotMissingFallback() {
        ShannonPreferences.setAutoKeepAwakeWithAgents(false, defaults: defaults)
        // bool(forKey:) alone would be false either way — object exists must stick.
        XCTAssertNotNil(defaults.object(forKey: ShannonPreferences.Key.autoKeepAwakeWithAgents.rawValue))
        XCTAssertFalse(ShannonPreferences.autoKeepAwakeWithAgents(defaults: defaults))
    }

    func testResetFirstRunCoach() {
        ShannonPreferences.setFirstRunDone(true, defaults: defaults)
        XCTAssertTrue(FirstRunCoach.shouldShow(defaults: defaults) == false)
        ShannonPreferences.resetFirstRunCoach(defaults: defaults)
        XCTAssertTrue(FirstRunCoach.shouldShow(defaults: defaults))
        XCTAssertFalse(ShannonPreferences.firstRunDone(defaults: defaults))
    }

    func testFirstRunCoachMarkDoneUsesSharedKey() {
        XCTAssertTrue(FirstRunCoach.shouldShow(defaults: defaults))
        FirstRunCoach.markDone(defaults: defaults)
        XCTAssertTrue(ShannonPreferences.firstRunDone(defaults: defaults))
        XCTAssertFalse(FirstRunCoach.shouldShow(defaults: defaults))
    }

    @MainActor
    func testStorePersistsAutoKeepAwake() {
        let store = ShannonPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.autoKeepAwakeWithAgents)
        store.autoKeepAwakeWithAgents = false
        XCTAssertFalse(ShannonPreferences.autoKeepAwakeWithAgents(defaults: defaults))
        let store2 = ShannonPreferencesStore(defaults: defaults)
        XCTAssertFalse(store2.autoKeepAwakeWithAgents)
    }

    @MainActor
    func testStorePersistsShowDesktopCompanionToggle() {
        let store = ShannonPreferencesStore(defaults: defaults)
        XCTAssertFalse(store.showDesktopCompanion)
        var callbackValues: [Bool] = []
        store.onShowDesktopCompanionChanged = { callbackValues.append($0) }
        store.showDesktopCompanion = true
        XCTAssertTrue(ShannonPreferences.showDesktopCompanion(defaults: defaults))
        XCTAssertEqual(callbackValues, [true])
        let store2 = ShannonPreferencesStore(defaults: defaults)
        XCTAssertTrue(store2.showDesktopCompanion)
        store2.showDesktopCompanion = false
        XCTAssertFalse(ShannonPreferences.showDesktopCompanion(defaults: defaults))
    }

    @MainActor
    func testStorePersistsDesktopPetId() {
        let store = ShannonPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.desktopPetId, "shannon")
        var callbackValues: [String] = []
        store.onDesktopPetIdChanged = { callbackValues.append($0) }
        store.desktopPetId = "firebear"
        XCTAssertEqual(ShannonPreferences.desktopPetId(defaults: defaults), "firebear")
        XCTAssertEqual(callbackValues, ["firebear"])
        let store2 = ShannonPreferencesStore(defaults: defaults)
        XCTAssertEqual(store2.desktopPetId, "firebear")
        store2.desktopPetId = "  grok  "
        XCTAssertEqual(store2.desktopPetId, "grok")
        XCTAssertEqual(ShannonPreferences.desktopPetId(defaults: defaults), "grok")
    }

    @MainActor
    func testStoreResetTips() {
        let store = ShannonPreferencesStore(defaults: defaults)
        store.markFirstRunDone()
        XCTAssertTrue(store.firstRunDone)
        store.resetFirstRunCoach()
        XCTAssertFalse(store.firstRunDone)
        XCTAssertTrue(FirstRunCoach.shouldShow(defaults: defaults))
    }

    /// UX-058: floating glance default off; toggle persists.
    func testShowFloatingGlanceDefaultAndToggle() {
        XCTAssertFalse(ShannonPreferences.showFloatingGlance(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: ShannonPreferences.Key.showFloatingGlance.rawValue))

        ShannonPreferences.setShowFloatingGlance(true, defaults: defaults)
        XCTAssertNotNil(defaults.object(forKey: ShannonPreferences.Key.showFloatingGlance.rawValue))
        XCTAssertTrue(ShannonPreferences.showFloatingGlance(defaults: defaults))

        ShannonPreferences.setShowFloatingGlance(false, defaults: defaults)
        XCTAssertFalse(ShannonPreferences.showFloatingGlance(defaults: defaults))
    }

    @MainActor
    func testStorePersistsShowFloatingGlanceToggle() {
        let store = ShannonPreferencesStore(defaults: defaults)
        XCTAssertFalse(store.showFloatingGlance)
        var callbackValues: [Bool] = []
        store.onShowFloatingGlanceChanged = { callbackValues.append($0) }
        store.showFloatingGlance = true
        XCTAssertTrue(ShannonPreferences.showFloatingGlance(defaults: defaults))
        XCTAssertEqual(callbackValues, [true])
        let store2 = ShannonPreferencesStore(defaults: defaults)
        XCTAssertTrue(store2.showFloatingGlance)
        store2.showFloatingGlance = false
        XCTAssertFalse(ShannonPreferences.showFloatingGlance(defaults: defaults))
    }

    /// Keys the Settings UI claims are the keys the pure store actually writes.
    func testSettingsKeysAreHonoredKeys() {
        let keys = Set(ShannonPreferences.Key.allCases.map(\.rawValue))
        XCTAssertTrue(keys.contains("shannon.prefs.autoKeepAwakeWithAgents"))
        XCTAssertTrue(keys.contains("shannon.pill.firstRunDone"))
        XCTAssertTrue(keys.contains("shannon.prefs.expandPillOnLaunch"))
        XCTAssertTrue(keys.contains("shannon.prefs.startWithMonitoringPaused"))
        XCTAssertTrue(keys.contains("shannon.prefs.showDesktopCompanion"))
        XCTAssertTrue(keys.contains("shannon.prefs.desktopPetId"))
        XCTAssertTrue(keys.contains("shannon.prefs.showFloatingGlance"))
        XCTAssertTrue(keys.contains("shannon.prefs.voiceCalloutsEnabled"))
        XCTAssertEqual(keys.count, 8)
    }

    /// ENH-030: voice callouts default off; store round-trip.
    @MainActor
    func testVoiceCalloutsDefaultOffAndRoundTrip() {
        XCTAssertFalse(ShannonPreferences.voiceCalloutsEnabled(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: ShannonPreferences.Key.voiceCalloutsEnabled.rawValue))

        ShannonPreferences.setVoiceCalloutsEnabled(true, defaults: defaults)
        XCTAssertNotNil(defaults.object(forKey: ShannonPreferences.Key.voiceCalloutsEnabled.rawValue))
        XCTAssertTrue(ShannonPreferences.voiceCalloutsEnabled(defaults: defaults))

        ShannonPreferences.setVoiceCalloutsEnabled(false, defaults: defaults)
        XCTAssertFalse(ShannonPreferences.voiceCalloutsEnabled(defaults: defaults))

        let store = ShannonPreferencesStore(defaults: defaults)
        XCTAssertFalse(store.voiceCalloutsEnabled)
        store.voiceCalloutsEnabled = true
        XCTAssertTrue(ShannonPreferences.voiceCalloutsEnabled(defaults: defaults))
        XCTAssertTrue(store.snapshot.voiceCalloutsEnabled)
    }
}
