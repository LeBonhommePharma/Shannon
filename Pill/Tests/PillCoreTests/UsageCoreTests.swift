import XCTest
@testable import UsageCore
@testable import PillCore
@testable import AgentReaders

/// ENH-014: UsageCore owns UsageSnapshot; Claude reader wires UsageBridge.
final class UsageCoreTests: XCTestCase {

    func testUsageBridgeFromTokensFailClosed() {
        XCTAssertNil(UsageBridge.fromTokens(input: nil, output: nil))
        XCTAssertNil(UsageBridge.fromTokens(input: 0, output: 0))
        XCTAssertNil(UsageBridge.fromTokens(input: -1, output: nil))
    }

    func testUsageBridgeSumsPositiveTokens() {
        let snap = UsageBridge.fromTokens(input: 100, output: 40)
        XCTAssertEqual(snap?.tokensUsed, 140)
        XCTAssertEqual(snap?.shortLabel, "140 tok")
    }

    func testAgentUsageSnapshotIsUsageSnapshotTypealias() {
        let a: AgentUsageSnapshot = UsageSnapshot(contextPercent: 22)
        XCTAssertEqual(a.shortLabel, "ctx 22%")
        let b: UsageSnapshot = AgentUsageSnapshot(tokensUsed: 10, tokensLimit: 100)
        XCTAssertEqual(b.shortLabel, "10/100")
    }

    func testClaudeReaderWiresUsageBridge() {
        let fromReader = ClaudeCodeSessionReader.usageSnapshot(tokensIn: 50, tokensOut: 10)
        let fromBridge = UsageBridge.fromTokens(input: 50, output: 10)
        XCTAssertEqual(fromReader, fromBridge)
        XCTAssertEqual(fromReader?.tokensUsed, 60)

        XCTAssertNil(ClaudeCodeSessionReader.usageSnapshot(tokensIn: nil, tokensOut: nil))
    }

    func testSessionPresenterUsesUsageBridge() {
        let session = AgentSession(
            id: "claude_code:s1",
            agentId: "claude_code",
            displayName: "Claude Code",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: Date(),
            tokensIn: 12,
            tokensOut: 3
        )
        let viaPresenter = SessionContentPresenter.usageFromSession(session)
        let viaBridge = UsageBridge.fromTokens(input: 12, output: 3)
        XCTAssertEqual(viaPresenter, viaBridge)
        XCTAssertEqual(viaPresenter?.tokensUsed, 15)
    }

    func testModuleName() {
        XCTAssertEqual(UsageCore.moduleName, "UsageCore")
    }
}
