import XCTest
@testable import ShannonPill
@testable import PillCore

/// Parity panel collection is off-main-safe and uses fixed helpers.
final class ParityRefreshOffMainTests: XCTestCase {

    /// Shipped collector runs without MainActor isolation and accepts an
    /// injected server discovery so the test never waits on real process scan.
    func testCollectParityPayloadIsOffMainSafe() {
        let payload = ParityPanelModel.collectParityPayload(
            gateAgents: [
                AgentActivitySnapshot(
                    id: "science", displayName: "Science", status: .idle,
                    lastTask: "", source: "gate", updatedAt: Date(),
                    resumable: false, historyCount: 0, presence: .live
                ),
            ],
            now: Date(),
            home: NSTemporaryDirectory(),
            includeArtifactReaders: false,
            discoverServers: { [] }
        )
        // Artifact sessions may be empty on a temp home — that is fine.
        XCTAssertTrue(payload.servers.isEmpty)
        // Routes catalog still returns paths for a home (may be missing).
        XCTAssertFalse(payload.routes.isEmpty, "panel routes keep missing paths")
    }

    /// Source contract: refresh schedules detached work (structural).
    func testRefreshSourceUsesTaskDetached() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #file)
                .deletingLastPathComponent() // ShannonPillTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // Pill
                .appendingPathComponent("Sources/ShannonPill/PanelSectionRegistry.swift")
        )
        XCTAssertTrue(
            src.contains("Task.detached(priority: .utility)"),
            "refresh must schedule discovery off MainActor"
        )
        XCTAssertTrue(
            src.contains("collectParityPayload"),
            "refresh must call the pure collector"
        )
        // ENH-002: hop via applyParityPayload — never `guard let self` in concurrent MainActor.run.
        XCTAssertTrue(
            src.contains("applyParityPayload"),
            "refresh must apply payload via MainActor method (Swift 6 Sendable-safe)"
        )
        XCTAssertFalse(
            src.contains("guard let self else"),
            "must not rebind self as var in concurrent Task.detached body"
        )
    }

    func testResourcesSectionStableRowOrderHelper() {
        let snap = SystemResourceSnapshot(
            cpuPercent: 10,
            cpuCores: [],
            gpuPercent: 20,
            ramPercent: 30,
            diskPercent: 40,
            thermal: nil
        )
        let hist = SystemResourceHistory()
        let rows = MenuBarResourcesSection.resourceRowsOrdered(snap: snap, hist: hist)
        XCTAssertEqual(rows.map(\.kind), [.cpu, .gpu, .ram, .disk, .thermal])
    }
}
