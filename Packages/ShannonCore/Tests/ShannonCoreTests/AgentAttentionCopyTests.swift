import XCTest
@testable import ShannonCore

/// UX-001 — shared attention / badge wording for Mac · phone · pad · watch.
final class AgentAttentionCopyTests: XCTestCase {

    func testCanonicalTokens() {
        XCTAssertEqual(AgentAttentionCopy.needsYou, "needs you")
        XCTAssertEqual(AgentAttentionCopy.working, "working")
        XCTAssertEqual(AgentAttentionCopy.done, "done")
        XCTAssertEqual(AgentAttentionCopy.live, "live")
    }

    func testBadgeLabelByKind() {
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(kind: .needsYou, fallback: "x"),
            "needs you"
        )
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(kind: .working, toolKindRaw: nil, fallback: "x"),
            "working"
        )
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(kind: .working, toolKindRaw: "none", fallback: "x"),
            "working"
        )
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(kind: .working, toolKindRaw: "edit", fallback: "x"),
            "edit"
        )
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(kind: .finished, fallback: "x"),
            "done"
        )
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(kind: .idle, fallback: "x"),
            "live"
        )
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(kind: .unknown, fallback: "seen 2m ago"),
            "seen 2m ago"
        )
    }

    func testAgentActivityMapsToSharedBadges() {
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(for: .blocked),
            "needs you"
        )
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(for: .running),
            "working"
        )
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(for: .finished),
            "done"
        )
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(for: .idle),
            "live"
        )
        // Pending confirmation elevates any activity to needs-you.
        XCTAssertEqual(
            AgentAttentionCopy.badgeLabel(for: .idle, hasPendingConfirmation: true),
            "needs you"
        )
        XCTAssertEqual(
            AgentAttentionCopy.kind(for: .errored),
            .unknown
        )
    }

    func testActivityLabelAgreesWithBadgeTokens() {
        XCTAssertEqual(AgentAttentionCopy.activityLabel(for: .blocked), "needs you")
        XCTAssertEqual(AgentAttentionCopy.activityLabel(for: .running), "working")
        XCTAssertEqual(AgentAttentionCopy.activityLabel(for: .finished), "done")
        XCTAssertEqual(AgentAttentionCopy.activityLabel(for: .idle), "live")
        XCTAssertEqual(AgentAttentionCopy.activityLabel(for: .errored), "errored")
    }

    func testNeedsYouFocusAndNotifyTitles() {
        XCTAssertEqual(
            AgentAttentionCopy.needsYouFocusLine(agentDisplayName: "Claude Code"),
            "Needs you · Claude Code"
        )
        XCTAssertEqual(
            AgentAttentionCopy.needsYouFocusLine(agentDisplayName: "  "),
            "Needs you"
        )
        XCTAssertEqual(
            AgentAttentionCopy.needsYouNotifyTitle(agentID: "claude_code"),
            "claude_code needs you"
        )
        XCTAssertEqual(
            AgentAttentionCopy.needsYouNotifyTitle(agentID: nil),
            "Approval needed"
        )
    }

    func testGlobalNotifyUsesSharedCopy() {
        let pending = PendingConfirmation(
            id: "c1",
            question: "Run migrate?",
            agentID: "science",
            createdAt: Date()
        )
        let content = GlobalNotifyResponse.content(for: pending)
        XCTAssertEqual(content.title, "science needs you")
        XCTAssertTrue(content.title.contains(AgentAttentionCopy.needsYou))
    }
}
