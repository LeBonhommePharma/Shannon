import XCTest
import ShannonTheme
@testable import PillCore

/// AgentNotch-class collapsed island peeks: quiet idle, ranked attention,
/// dual-HUD chrome roles, minimal trailing chips.
final class CollapsedIslandPeekTests: XCTestCase {

    // MARK: - Chrome role dual-HUD map

    func testChromeRoleMapsAttentionOneToOne() {
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(for: AgentLiveAttention.needsYou),
            .needsYou
        )
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(for: AgentLiveAttention.working),
            .working
        )
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(for: AgentLiveAttention.finished),
            .finished
        )
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(for: AgentLiveAttention.idle),
            .idle
        )
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(for: AgentLiveAttention.unknown),
            .unknown
        )
    }

    func testCollapseAlarmOverridesAttentionRole() {
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(
                collapseAlarm: true,
                attention: AgentLiveAttention.working
            ),
            .collapse
        )
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(
                collapseAlarm: false,
                attention: AgentLiveAttention.needsYou
            ),
            .needsYou
        )
    }

    func testBadgeWashNeedsYouDistinctFromCollapse() {
        let needs = AgentNotchChrome.badgeWash(
            for: CollapsedIslandPeek.chromeRole(for: AgentLiveAttention.needsYou)
        )
        let collapse = AgentNotchChrome.badgeWash(
            for: CollapsedIslandPeek.chromeRole(
                collapseAlarm: true,
                attention: AgentLiveAttention.idle
            )
        )
        XCTAssertNotEqual(String(describing: needs), String(describing: collapse))
    }

    // MARK: - Quiet idle + peek rank

    func testQuietIdleWhenNothingActionable() {
        XCTAssertTrue(
            CollapsedIslandPeek.isQuietIdle(
                collapseAlarm: false, pendingAsk: false, activeCount: 0
            )
        )
        XCTAssertFalse(
            CollapsedIslandPeek.isQuietIdle(
                collapseAlarm: false, pendingAsk: true, activeCount: 0
            )
        )
        XCTAssertFalse(
            CollapsedIslandPeek.isQuietIdle(
                collapseAlarm: false, pendingAsk: false, activeCount: 2
            )
        )
        XCTAssertFalse(
            CollapsedIslandPeek.isQuietIdle(
                collapseAlarm: true, pendingAsk: false, activeCount: 0
            )
        )
    }

    func testPrimaryPeekPriorityCollapseThenNeedsYouThenWorking() {
        XCTAssertEqual(
            CollapsedIslandPeek.primaryPeek(
                collapseAlarm: true, pendingAsk: true, workingCount: 3, finishedPrimary: true
            ),
            CollapsedIslandPeek.PeekKind.collapse
        )
        XCTAssertEqual(
            CollapsedIslandPeek.primaryPeek(
                collapseAlarm: false, pendingAsk: true, workingCount: 3, finishedPrimary: true
            ),
            CollapsedIslandPeek.PeekKind.needsYou
        )
        XCTAssertEqual(
            CollapsedIslandPeek.primaryPeek(
                collapseAlarm: false, pendingAsk: false, workingCount: 2, finishedPrimary: true
            ),
            CollapsedIslandPeek.PeekKind.working
        )
        XCTAssertEqual(
            CollapsedIslandPeek.primaryPeek(
                collapseAlarm: false, pendingAsk: false, workingCount: 0, finishedPrimary: true
            ),
            CollapsedIslandPeek.PeekKind.finished
        )
        XCTAssertEqual(
            CollapsedIslandPeek.primaryPeek(
                collapseAlarm: false, pendingAsk: false, workingCount: 0, finishedPrimary: false
            ),
            CollapsedIslandPeek.PeekKind.quiet
        )
    }

    func testPeekChromeRolesMatchAgentNotchAttention() {
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(for: CollapsedIslandPeek.PeekKind.collapse),
            .collapse
        )
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(for: CollapsedIslandPeek.PeekKind.needsYou),
            .needsYou
        )
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(for: CollapsedIslandPeek.PeekKind.working),
            .working
        )
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(for: CollapsedIslandPeek.PeekKind.finished),
            .finished
        )
        XCTAssertEqual(
            CollapsedIslandPeek.chromeRole(for: CollapsedIslandPeek.PeekKind.quiet),
            .idle
        )
    }

    // MARK: - Chip density

    func testMultiAgentCountChipOnlyWhenFleetWorkingAndNoHigherPeek() {
        XCTAssertTrue(
            CollapsedIslandPeek.showsMultiAgentCountChip(
                activeCount: 3,
                collapseAlarm: false,
                pendingAsk: false,
                hasUsageChip: false
            )
        )
        XCTAssertFalse(
            CollapsedIslandPeek.showsMultiAgentCountChip(
                activeCount: 1,
                collapseAlarm: false,
                pendingAsk: false,
                hasUsageChip: false
            )
        )
        XCTAssertFalse(
            CollapsedIslandPeek.showsMultiAgentCountChip(
                activeCount: 4,
                collapseAlarm: true,
                pendingAsk: false,
                hasUsageChip: false
            )
        )
        XCTAssertFalse(
            CollapsedIslandPeek.showsMultiAgentCountChip(
                activeCount: 4,
                collapseAlarm: false,
                pendingAsk: true,
                hasUsageChip: false
            )
        )
        XCTAssertFalse(
            CollapsedIslandPeek.showsMultiAgentCountChip(
                activeCount: 4,
                collapseAlarm: false,
                pendingAsk: false,
                hasUsageChip: true
            )
        )
    }

    func testMeasuredEntropyChipFailClosed() {
        XCTAssertTrue(CollapsedIslandPeek.showsMeasuredEntropyChip(label: "H 8.2"))
        XCTAssertTrue(CollapsedIslandPeek.showsMeasuredEntropyChip(label: "H 3.1"))
        XCTAssertFalse(CollapsedIslandPeek.showsMeasuredEntropyChip(label: nil))
        XCTAssertFalse(CollapsedIslandPeek.showsMeasuredEntropyChip(label: ""))
        XCTAssertFalse(CollapsedIslandPeek.showsMeasuredEntropyChip(label: "  "))
        XCTAssertFalse(CollapsedIslandPeek.showsMeasuredEntropyChip(label: "simulated · demo"))
        XCTAssertFalse(CollapsedIslandPeek.showsMeasuredEntropyChip(label: "no detector"))
    }

    func testRecessiveLabelWhenQuietAndNothingToSay() {
        XCTAssertTrue(
            CollapsedIslandPeek.isRecessiveLabel(quietIdle: true, hasSomethingToSay: false)
        )
        XCTAssertFalse(
            CollapsedIslandPeek.isRecessiveLabel(quietIdle: true, hasSomethingToSay: true)
        )
        XCTAssertFalse(
            CollapsedIslandPeek.isRecessiveLabel(quietIdle: false, hasSomethingToSay: false)
        )
    }

    // MARK: - Reduce Motion morph (shipped spring scale)

    func testIslandSpringReduceMotionIsNearInstant() {
        let spring = ShannonMotion.islandSpring(reduceMotion: true)
        XCTAssertEqual(spring.response, 0.001, accuracy: 1e-12)
        XCTAssertEqual(spring.dampingFraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(
            ShannonMotion.panelMorphDuration(reduceMotion: true),
            0,
            accuracy: 1e-12
        )
        let live = ShannonMotion.islandSpring(reduceMotion: false)
        XCTAssertEqual(live, AgentNotchChrome.islandSpring)
        XCTAssertEqual(live.response, 0.40, accuracy: 1e-12)
        XCTAssertFalse(ShannonMotion.allowsForeverPulse(reduceMotion: true))
        XCTAssertTrue(ShannonMotion.allowsForeverPulse(reduceMotion: false))
    }
}
