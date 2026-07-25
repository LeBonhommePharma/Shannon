import XCTest
@testable import PillCore

final class FirstRunCoachTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "shannon.pill.tests.firstRun.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testShouldShowUntilMarkedDone() {
        XCTAssertTrue(FirstRunCoach.shouldShow(defaults: defaults))
        FirstRunCoach.markDone(defaults: defaults)
        XCTAssertFalse(FirstRunCoach.shouldShow(defaults: defaults))
    }

    func testMarkDoneIsIdempotent() {
        FirstRunCoach.markDone(defaults: defaults)
        FirstRunCoach.markDone(defaults: defaults)
        XCTAssertFalse(FirstRunCoach.shouldShow(defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: FirstRunCoach.defaultsKey))
    }

    func testStepsOrder() {
        XCTAssertEqual(
            FirstRunCoach.steps.map(\.rawValue),
            ["watch", "attach", "permissions"]
        )
    }

    func testTipCopyMentionsAttachHotkey() {
        let attach = FirstRunCoach.tip(for: .attach)
        XCTAssertTrue(attach.contains("⌘D"), attach)
    }

    func testWatchTipTeachesAmberAskVsRedCollapse() {
        let watch = FirstRunCoach.tip(for: .watch).lowercased()
        XCTAssertTrue(watch.contains("amber"), watch)
        XCTAssertTrue(watch.contains("red"), watch)
        XCTAssertTrue(watch.contains("collapse") || watch.contains("approval"), watch)
        // Same legend string as expanded pill chrome.
        XCTAssertTrue(
            FirstRunCoach.tip(for: .watch).contains(PillChromePolicy.statusLegend)
                || watch.contains("approval") && watch.contains("collapse"),
            FirstRunCoach.tip(for: .watch)
        )
    }

    func testDefaultsKeyStable() {
        XCTAssertEqual(FirstRunCoach.defaultsKey, "shannon.pill.firstRunDone")
    }
}
