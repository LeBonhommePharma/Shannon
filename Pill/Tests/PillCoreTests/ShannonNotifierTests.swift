import XCTest
@testable import PillCore

final class ShannonNotifierTests: XCTestCase {

    func testAskDefaults() {
        let c = ShannonNotifier.notificationContent(kind: .ask)
        XCTAssertEqual(c.title, "Approval needed")
        XCTAssertFalse(c.body.isEmpty)
    }

    func testCollapseDefaults() {
        let c = ShannonNotifier.notificationContent(kind: .collapse)
        XCTAssertEqual(c.title, "Entropy collapse")
        XCTAssertTrue(c.body.lowercased().contains("entropy") || c.body.lowercased().contains("collapse"))
    }

    func testOverrides() {
        let c = ShannonNotifier.notificationContent(
            kind: .ask,
            title: "Claude",
            body: "Write to disk?"
        )
        XCTAssertEqual(c.title, "Claude")
        XCTAssertEqual(c.body, "Write to disk?")
    }

    func testCollapseOverrideBody() {
        let c = ShannonNotifier.notificationContent(
            kind: .collapse,
            title: nil,
            body: "H 2.1 collapsed (bridge:numpy)"
        )
        XCTAssertEqual(c.title, "Entropy collapse")
        XCTAssertTrue(c.body.contains("2.1"))
    }

    func testContentEquality() {
        let a = ShannonNotifier.notificationContent(kind: .ask, title: "A", body: "B")
        let b = ShannonNotificationContent(title: "A", body: "B")
        XCTAssertEqual(a, b)
    }
}
