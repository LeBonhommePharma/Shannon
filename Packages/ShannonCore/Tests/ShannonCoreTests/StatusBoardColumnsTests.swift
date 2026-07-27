import XCTest
@testable import ShannonCore

/// UX-057 — status board columns (needs-you / working / done).
final class StatusBoardColumnsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Column resolution

    func testColumnFromActivityAndPending() {
        XCTAssertEqual(
            StatusBoardColumns.column(activity: .blocked),
            .needsYou
        )
        XCTAssertEqual(
            StatusBoardColumns.column(activity: .idle, hasPendingConfirmation: true),
            .needsYou
        )
        XCTAssertEqual(
            StatusBoardColumns.column(activity: .running),
            .working
        )
        XCTAssertEqual(
            StatusBoardColumns.column(activity: .finished),
            .done
        )
        XCTAssertNil(StatusBoardColumns.column(activity: .idle))
        XCTAssertNil(StatusBoardColumns.column(activity: .errored))
    }

    func testColumnFromAttentionKind() {
        XCTAssertEqual(StatusBoardColumns.column(for: .needsYou), .needsYou)
        XCTAssertEqual(StatusBoardColumns.column(for: .working), .working)
        XCTAssertEqual(StatusBoardColumns.column(for: .finished), .done)
        XCTAssertNil(StatusBoardColumns.column(for: .idle))
        XCTAssertNil(StatusBoardColumns.column(for: .unknown))
    }

    // MARK: Titles share attention vocabulary

    func testTitlesMatchAttentionCopyFamily() {
        XCTAssertEqual(StatusBoardColumns.title(for: .needsYou), "Needs you")
        XCTAssertEqual(StatusBoardColumns.title(for: .working), "Working")
        XCTAssertEqual(StatusBoardColumns.title(for: .done), "Done")
        XCTAssertTrue(
            StatusBoardColumns.title(for: .needsYou)
                .lowercased()
                .contains(AgentAttentionCopy.needsYou)
        )
        XCTAssertEqual(
            StatusBoardColumns.title(for: .working).lowercased(),
            AgentAttentionCopy.working
        )
        XCTAssertEqual(
            StatusBoardColumns.title(for: .done).lowercased(),
            AgentAttentionCopy.done
        )
    }

    func testDisplayOrderIsNeedsYouWorkingDone() {
        XCTAssertEqual(
            StatusBoardColumns.displayOrder,
            [.needsYou, .working, .done]
        )
        XCTAssertTrue(StatusBoardColumn.needsYou < StatusBoardColumn.working)
        XCTAssertTrue(StatusBoardColumn.working < StatusBoardColumn.done)
    }

    // MARK: Bucket

    func testBucketGroupsAndPreservesRankOrder() {
        let agents = [
            AgentState(id: "idle", name: "Idle", activity: .idle, updatedAt: now),
            AgentState(id: "run-old", name: "RunOld", activity: .running,
                       updatedAt: now.addingTimeInterval(-60)),
            AgentState(id: "done", name: "Done", activity: .finished, updatedAt: now),
            AgentState(id: "run-new", name: "RunNew", activity: .running, updatedAt: now),
            AgentState(id: "ask", name: "Ask", activity: .idle, updatedAt: now),
            AgentState(id: "block", name: "Block", activity: .blocked, updatedAt: now),
        ]
        let buckets = StatusBoardColumns.bucket(
            agents: agents,
            pendingAgentIDs: ["ask"]
        )
        // needs-you: block + ask (rank: both p0; recency then id)
        XCTAssertEqual(buckets.needsYou.map(\.id), ["ask", "block"])
        // working: run-new before run-old (recency within same priority)
        XCTAssertEqual(buckets.working.map(\.id), ["run-new", "run-old"])
        XCTAssertEqual(buckets.done.map(\.id), ["done"])
        XCTAssertEqual(buckets.other.map(\.id), ["idle"])
        XCTAssertTrue(buckets.hasColumnContent)
    }

    func testBucketFromSnapshotElevatesPending() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(id: "a", name: "A", activity: .running, updatedAt: now),
                AgentState(id: "b", name: "B", activity: .idle, updatedAt: now),
            ],
            confirmations: [
                PendingConfirmation(
                    id: "c1", question: "Ship?", agentID: "b",
                    createdAt: now, expiresAt: now.addingTimeInterval(300)
                ),
            ],
            capturedAt: now
        )
        let buckets = StatusBoardColumns.bucket(snapshot: snap, now: now)
        XCTAssertEqual(buckets.needsYou.map(\.id), ["b"])
        XCTAssertEqual(buckets.working.map(\.id), ["a"])
        XCTAssertTrue(buckets.done.isEmpty)
        XCTAssertTrue(buckets.other.isEmpty)
    }

    func testBucketIgnoresExpiredConfirmation() {
        let snap = ShannonSnapshot(
            agents: [
                AgentState(id: "b", name: "B", activity: .idle, updatedAt: now),
            ],
            confirmations: [
                PendingConfirmation(
                    id: "stale", question: "Old?", agentID: "b",
                    createdAt: now.addingTimeInterval(-3_600),
                    expiresAt: now.addingTimeInterval(-1)
                ),
            ],
            capturedAt: now
        )
        let buckets = StatusBoardColumns.bucket(snapshot: snap, now: now)
        XCTAssertTrue(buckets.needsYou.isEmpty)
        XCTAssertEqual(buckets.other.map(\.id), ["b"])
    }

    func testPartitionGenericPreservesOrder() {
        let items = ["n1", "w1", "d1", "n2", "x", "w2"]
        let buckets = StatusBoardColumns.partition(items) { id -> StatusBoardColumn? in
            if id.hasPrefix("n") { return .needsYou }
            if id.hasPrefix("w") { return .working }
            if id.hasPrefix("d") { return .done }
            return nil
        }
        XCTAssertEqual(buckets.needsYou, ["n1", "n2"])
        XCTAssertEqual(buckets.working, ["w1", "w2"])
        XCTAssertEqual(buckets.done, ["d1"])
        XCTAssertEqual(buckets.other, ["x"])
    }

    func testEmptyBoard() {
        let empty = StatusBoardColumns.bucket(agents: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(empty.hasColumnContent)
    }

    // MARK: Structural wiring — Mac CompanionBoard

    func testMacCompanionBoardWiresStatusBoardColumns() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let pet = (try? String(contentsOf: root.appendingPathComponent(
            "Pill/Sources/PillCore/PetPillView.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(
            pet.contains("StatusBoardColumns"),
            "CompanionBoardView must use StatusBoardColumns for section headers"
        )
        XCTAssertTrue(
            pet.contains("statusBoard.needsYou")
                || pet.contains("accessibilityIdentifier(for:"),
            "CompanionBoardView must expose status-board a11y identities"
        )
        XCTAssertTrue(
            pet.contains("StatusBoardColumns.title")
                || pet.contains("title(for:"),
            "CompanionBoardView must use shared column titles"
        )
    }
}
