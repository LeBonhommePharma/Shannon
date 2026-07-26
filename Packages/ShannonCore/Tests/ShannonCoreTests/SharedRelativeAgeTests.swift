import XCTest
@testable import ShannonCore

/// UX-008 — Mac `signatureAge` 15 s buckets in ShannonCore for widget glance.
final class SharedRelativeAgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBucketedMatchesMacSignatureAgeSemantics() {
        XCTAssertEqual(
            SharedRelativeAge.bucketed(since: now.addingTimeInterval(-3), now: now),
            "now"
        )
        XCTAssertEqual(
            SharedRelativeAge.bucketed(since: now.addingTimeInterval(-14.9), now: now),
            "now"
        )
        let t22 = now.addingTimeInterval(-22)
        XCTAssertEqual(SharedRelativeAge.bucketed(since: t22, now: now), "15s")
        XCTAssertEqual(
            SharedRelativeAge.bucketed(since: t22, now: now.addingTimeInterval(10)),
            "30s"
        )
        XCTAssertEqual(
            SharedRelativeAge.bucketed(since: now.addingTimeInterval(-44), now: now),
            "30s"
        )
        XCTAssertEqual(
            SharedRelativeAge.bucketed(since: now.addingTimeInterval(-45), now: now),
            "45s"
        )
        XCTAssertEqual(
            SharedRelativeAge.bucketed(since: now.addingTimeInterval(-59), now: now),
            "45s"
        )
        XCTAssertEqual(
            SharedRelativeAge.bucketed(since: now.addingTimeInterval(-120), now: now),
            "2m"
        )
        XCTAssertEqual(
            SharedRelativeAge.bucketed(since: now.addingTimeInterval(-3 * 3600), now: now),
            "3h"
        )
        XCTAssertEqual(
            SharedRelativeAge.bucketed(since: now.addingTimeInterval(-2 * 86_400), now: now),
            "2d"
        )
        XCTAssertEqual(
            SharedRelativeAge.bucketed(since: .distantPast, now: now),
            "never"
        )
    }

    func testBucketedStableWithin15sWindow() {
        let since = now.addingTimeInterval(-20)
        let a = SharedRelativeAge.bucketed(since: since, now: now)
        let b = SharedRelativeAge.bucketed(since: since, now: now.addingTimeInterval(5))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "15s")
        let c = SharedRelativeAge.bucketed(since: since, now: now.addingTimeInterval(16))
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(c, "30s")
    }

    func testBucketConstantIs15Seconds() {
        XCTAssertEqual(SharedRelativeAge.bucketSeconds, 15)
    }

    func testFineIsSecondResolutionUnderAMinute() {
        XCTAssertEqual(
            SharedRelativeAge.fine(since: now.addingTimeInterval(-3), now: now),
            "now"
        )
        XCTAssertEqual(
            SharedRelativeAge.fine(since: now.addingTimeInterval(-20), now: now),
            "20s"
        )
        XCTAssertEqual(
            SharedRelativeAge.fine(since: now.addingTimeInterval(-20), now: now.addingTimeInterval(5)),
            "25s"
        )
        XCTAssertEqual(
            SharedRelativeAge.fine(since: now.addingTimeInterval(-8 * 60), now: now),
            "8m"
        )
        XCTAssertEqual(
            SharedRelativeAge.fine(since: .distantPast, now: now),
            "never"
        )
    }

    func testGlanceReferenceUsesFreshestAgentOrDocking() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(
                    id: "old",
                    name: "Old",
                    activity: .idle,
                    updatedAt: now.addingTimeInterval(-600)
                ),
                AgentState(
                    id: "new",
                    name: "New",
                    activity: .running,
                    updatedAt: now.addingTimeInterval(-22)
                ),
            ],
            capturedAt: now.addingTimeInterval(-120)
        )
        XCTAssertEqual(
            SharedRelativeAge.glanceReferenceDate(in: snap),
            now.addingTimeInterval(-22)
        )
        XCTAssertEqual(SharedRelativeAge.glanceBucketed(in: snap, now: now), "15s")

        let dockOnly = ShannonSnapshot(
            docking: [
                DockingProgress(
                    id: "astex",
                    benchmarkName: "Astex",
                    targetsComplete: 1,
                    targetsTotal: 10,
                    updatedAt: now.addingTimeInterval(-90)
                ),
            ],
            capturedAt: now.addingTimeInterval(-300)
        )
        XCTAssertEqual(
            SharedRelativeAge.glanceBucketed(in: dockOnly, now: now),
            "1m"
        )
    }

    func testGlanceFallsBackToCapturedAt() {
        let snap = ShannonSnapshot(capturedAt: now.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(SharedRelativeAge.glanceBucketed(in: snap, now: now), "3h")
    }

    func testWidgetWiresSharedRelativeAge() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let widget = (try? String(
            contentsOf: root.appendingPathComponent(
                "iOS/Sources/ShannonWidget/ShannonWidget.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            widget.contains("SharedRelativeAge"),
            "ShannonWidget must use SharedRelativeAge for glance age"
        )
        XCTAssertTrue(
            widget.contains("glanceBucketed") || widget.contains("bucketed"),
            "widget must use bucketed (not fine) relative age"
        )
    }
}
