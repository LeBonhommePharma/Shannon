import XCTest

/// Structural: watchOS HealthKit path stays opt-in and feeds NaturalSCI.
final class WatchHealthKitWiringTests: XCTestCase {

    func testHeartRateMonitorIsOptInAndFeedsSCI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ShannonCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ShannonCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo
        let path = root.appendingPathComponent(
            "watchOS/Sources/ShannonWatch/HeartRateMonitor.swift"
        )
        let src = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(src.contains("canImport(HealthKit)"), "HealthKit must be compile-gated")
        XCTAssertTrue(src.contains("func enable()"), "enable() opt-in required")
        XCTAssertTrue(
            src.contains("Off by default") || src.contains("never at launch"),
            "must document no launch-time scrape"
        )
        XCTAssertTrue(src.contains("NaturalSCI") || src.contains("HealthResearchSamples"))
        XCTAssertTrue(src.contains("latestSCI") || src.contains("sci.analyze"))
        // Never write HR to CloudKit in this file.
        XCTAssertFalse(src.contains("CloudKitSyncBackend"))
        XCTAssertTrue(src.contains("Never uploaded") || src.contains("never writes"))
    }

    func testResearchHealthShippedInCore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("Sources/ShannonCore/ResearchHealth.swift")
        let src = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(src.contains("ClinicalConsent"))
        XCTAssertTrue(src.contains("ResearchSurveyBridge"))
        XCTAssertTrue(src.contains("MedicationResearch"))
        XCTAssertTrue(src.contains("HealthResearchSamples"))
    }
}
