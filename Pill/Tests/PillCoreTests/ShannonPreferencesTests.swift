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
    }

    func testRoundTripSaveLoad() {
        var snap = ShannonPreferences.factoryDefaults
        snap.autoKeepAwakeWithAgents = false
        snap.expandPillOnLaunch = false
        snap.startWithMonitoringPaused = true
        snap.firstRunDone = true
        ShannonPreferences.save(snap, defaults: defaults)
        let loaded = ShannonPreferences.load(defaults: defaults)
        XCTAssertEqual(loaded, snap)
        XCTAssertFalse(ShannonPreferences.autoKeepAwakeWithAgents(defaults: defaults))
        XCTAssertTrue(ShannonPreferences.startWithMonitoringPaused(defaults: defaults))
        XCTAssertFalse(ShannonPreferences.expandPillOnLaunch(defaults: defaults))
        XCTAssertTrue(ShannonPreferences.firstRunDone(defaults: defaults))
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
    func testStoreResetTips() {
        let store = ShannonPreferencesStore(defaults: defaults)
        store.markFirstRunDone()
        XCTAssertTrue(store.firstRunDone)
        store.resetFirstRunCoach()
        XCTAssertFalse(store.firstRunDone)
        XCTAssertTrue(FirstRunCoach.shouldShow(defaults: defaults))
    }

    /// Keys the Settings UI claims are the keys the pure store actually writes.
    func testSettingsKeysAreHonoredKeys() {
        let keys = Set(ShannonPreferences.Key.allCases.map(\.rawValue))
        XCTAssertTrue(keys.contains("shannon.prefs.autoKeepAwakeWithAgents"))
        XCTAssertTrue(keys.contains("shannon.pill.firstRunDone"))
        XCTAssertTrue(keys.contains("shannon.prefs.expandPillOnLaunch"))
        XCTAssertTrue(keys.contains("shannon.prefs.startWithMonitoringPaused"))
        XCTAssertEqual(keys.count, 4)
    }
}
