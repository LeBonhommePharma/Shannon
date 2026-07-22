import XCTest
@testable import PillCore

final class BatteryTests: XCTestCase {

    // MARK: Parsing IOKit descriptions

    func testParsesPercentageFromDeviceUnits() throws {
        // IOKit reports raw capacity units, not percent.
        let desc: [String: Any] = [
            PowerSourceKey.currentCapacity: 4_100,
            PowerSourceKey.maxCapacity: 8_200,
            PowerSourceKey.isCharging: false,
            PowerSourceKey.isPresent: true,
            PowerSourceKey.timeToEmpty: 185,
        ]
        let snap = try XCTUnwrap(BatterySnapshot(powerSourceDescription: desc))
        XCTAssertEqual(snap.percentage, 50)
        XCTAssertFalse(snap.isCharging)
        XCTAssertEqual(snap.minutesToEmpty, 185)
        XCTAssertNil(snap.minutesToFull)
    }

    func testRejectsDescriptionWithoutCapacity() {
        XCTAssertNil(BatterySnapshot(powerSourceDescription: [PowerSourceKey.isCharging: true]))
        // Guard against divide-by-zero on a malformed max capacity.
        XCTAssertNil(BatterySnapshot(powerSourceDescription: [
            PowerSourceKey.currentCapacity: 10,
            PowerSourceKey.maxCapacity: 0,
        ]))
    }

    func testCalculatingTimeEstimateBecomesNil() throws {
        let desc: [String: Any] = [
            PowerSourceKey.currentCapacity: 50,
            PowerSourceKey.maxCapacity: 100,
            PowerSourceKey.isCharging: true,
            PowerSourceKey.timeToFull: kTimeEstimateCalculating,
        ]
        let snap = try XCTUnwrap(BatterySnapshot(powerSourceDescription: desc))
        XCTAssertNil(snap.minutesToFull)
        XCTAssertEqual(snap.timeLabel, "Calculating…")
    }

    func testFallsBackToPowerSourceStateWhenIsChargingAbsent() throws {
        let desc: [String: Any] = [
            PowerSourceKey.currentCapacity: 90,
            PowerSourceKey.maxCapacity: 100,
            PowerSourceKey.powerSourceState: "AC Power",
        ]
        let snap = try XCTUnwrap(BatterySnapshot(powerSourceDescription: desc))
        XCTAssertTrue(snap.isCharging)
    }

    // MARK: Alert levels

    func testAlertLevelThresholds() {
        func level(_ pct: Int, charging: Bool = false) -> BatteryAlertLevel {
            BatterySnapshot(percentage: pct, isCharging: charging).alertLevel
        }
        XCTAssertEqual(level(100), .normal)
        XCTAssertEqual(level(21), .normal)
        XCTAssertEqual(level(20), .low)      // boundary is inclusive
        XCTAssertEqual(level(11), .low)
        XCTAssertEqual(level(10), .critical) // boundary is inclusive
        XCTAssertEqual(level(3), .critical)
    }

    func testChargingSuppressesAlerts() {
        // On the cable at 5% is recovering, not in trouble.
        XCTAssertEqual(BatterySnapshot(percentage: 5, isCharging: true).alertLevel, .normal)
    }

    func testFillFractionClampsOutOfRangeValues() {
        XCTAssertEqual(BatterySnapshot(percentage: 150, isCharging: false).fillFraction, 1.0)
        XCTAssertEqual(BatterySnapshot(percentage: -5, isCharging: false).fillFraction, 0.0)
    }

    func testTimeLabelFormatting() {
        XCTAssertEqual(BatterySnapshot.formatMinutes(185), "3:05")
        XCTAssertEqual(BatterySnapshot.formatMinutes(60), "1:00")
        XCTAssertEqual(BatterySnapshot.formatMinutes(7), "0:07")

        XCTAssertEqual(
            BatterySnapshot(percentage: 40, isCharging: false, minutesToEmpty: 95).timeLabel,
            "1:35 left"
        )
        XCTAssertEqual(
            BatterySnapshot(percentage: 40, isCharging: true, minutesToFull: 20).timeLabel,
            "0:20 to full"
        )
        XCTAssertEqual(
            BatterySnapshot(percentage: 100, isCharging: true).timeLabel,
            "Charged"
        )
    }

    // MARK: Edge-triggered alerts

    func testAlertFiresOnceOnEnteringLow() {
        var tracker = BatteryAlertTracker()
        XCTAssertNil(tracker.consume(BatterySnapshot(percentage: 55, isCharging: false)))
        XCTAssertEqual(
            tracker.consume(BatterySnapshot(percentage: 19, isCharging: false)),
            .enteredLow(19)
        )
        // Still low on the next poll — must not re-alert.
        XCTAssertNil(tracker.consume(BatterySnapshot(percentage: 17, isCharging: false)))
        XCTAssertNil(tracker.consume(BatterySnapshot(percentage: 15, isCharging: false)))
    }

    func testCriticalFiresAfterLowAndDoesNotRegressOnRecovery() {
        var tracker = BatteryAlertTracker()
        _ = tracker.consume(BatterySnapshot(percentage: 18, isCharging: false))
        XCTAssertEqual(
            tracker.consume(BatterySnapshot(percentage: 9, isCharging: false)),
            .enteredCritical(9)
        )
        // Crossing back up from critical into low should stay quiet.
        XCTAssertNil(tracker.consume(BatterySnapshot(percentage: 14, isCharging: false)))
    }

    func testFullAlertFiresOnceAndRearmsAfterDraining() {
        var tracker = BatteryAlertTracker()
        XCTAssertEqual(
            tracker.consume(BatterySnapshot(name: "AirPods", percentage: 100, isCharging: true)),
            .reachedFull("AirPods")
        )
        XCTAssertNil(tracker.consume(BatterySnapshot(name: "AirPods", percentage: 100, isCharging: true)))

        // Drain below the re-arm threshold, charge back to full: alert again.
        _ = tracker.consume(BatterySnapshot(name: "AirPods", percentage: 80, isCharging: false))
        XCTAssertEqual(
            tracker.consume(BatterySnapshot(name: "AirPods", percentage: 100, isCharging: true)),
            .reachedFull("AirPods")
        )
    }

    func testAbsentSourceProducesNoAlerts() {
        var tracker = BatteryAlertTracker()
        XCTAssertNil(tracker.consume(
            BatterySnapshot(percentage: 2, isCharging: false, isPresent: false)
        ))
    }

    // MARK: Monitor

    @MainActor
    func testMonitorPublishesPolledSnapshot() {
        final class FakeProvider: BatteryProviding {
            var snapshots: [BatterySnapshot] = []
            func currentSnapshots() -> [BatterySnapshot] { snapshots }
        }
        let provider = FakeProvider()
        provider.snapshots = [BatterySnapshot(percentage: 64, isCharging: true, minutesToFull: 42)]

        let monitor = BatteryMonitor(provider: provider)
        monitor.poll()
        XCTAssertEqual(monitor.snapshot?.percentage, 64)
        XCTAssertEqual(monitor.snapshot?.timeLabel, "0:42 to full")

        provider.snapshots = []
        monitor.poll()
        XCTAssertNil(monitor.snapshot)
    }
}
