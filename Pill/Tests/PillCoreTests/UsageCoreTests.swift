import XCTest
@testable import UsageCore
@testable import PillCore
@testable import AgentReaders

/// ENH-014 / ENH-026: UsageCore owns UsageSnapshot + multi-window fields.
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
        XCTAssertTrue(snap?.windows.isEmpty == true)
    }

    func testFromTokensNeverInventWindows() {
        // Token totals alone must not produce quota windows or percentages.
        let snap = UsageBridge.fromTokens(input: 50_000, output: 2_000)
        XCTAssertEqual(snap?.tokensUsed, 52_000)
        XCTAssertTrue(snap?.windows.isEmpty == true)
        XCTAssertNil(snap?.windowsLabel)
        XCTAssertNil(snap?.contextPercent)
        XCTAssertEqual(snap?.shortLabel, "52000 tok")
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
        XCTAssertTrue(viaPresenter?.windows.isEmpty == true)
    }

    // MARK: - ENH-026 multi-window

    func testCodexRateLimitsWindowsPresent() {
        let rl: [String: Any] = [
            "primary": [
                "used_percent": 26.0,
                "window_minutes": 300,
                "resets_at": 1_780_850_194,
            ],
            "secondary": [
                "used_percent": 94.0,
                "window_minutes": 10_080,
                "resets_at": 1_781_195_134,
            ],
            "plan_type": "plus",
        ]
        let windows = UsageBridge.windowsFromCodexRateLimits(rl)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].kind, .fiveHour)
        XCTAssertEqual(windows[0].usedPercent, 26)
        XCTAssertEqual(windows[0].windowMinutes, 300)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_780_850_194))
        XCTAssertEqual(windows[1].kind, .sevenDay)
        XCTAssertEqual(windows[1].usedPercent, 94)
        XCTAssertEqual(UsageBridge.planLabelFromCodexRateLimits(rl), "plus")

        let snap = UsageBridge.snapshot(
            tokensIn: 1000,
            tokensOut: 40,
            windows: windows,
            planLabel: UsageBridge.planLabelFromCodexRateLimits(rl)
        )
        XCTAssertEqual(snap?.tokensUsed, 1040)
        XCTAssertEqual(snap?.windows.count, 2)
        XCTAssertEqual(snap?.planLabel, "plus")
        XCTAssertEqual(snap?.windowsLabel, "5h 26% · 7d 94%")
        // Multi-window label wins over raw token shortLabel.
        XCTAssertEqual(snap?.shortLabel, "5h 26% · 7d 94%")
    }

    func testCodexRateLimitsNullOrEmptyFailClosed() {
        XCTAssertTrue(UsageBridge.windowsFromCodexRateLimits(nil).isEmpty)
        XCTAssertTrue(UsageBridge.windowsFromCodexRateLimits([:]).isEmpty)
        XCTAssertTrue(UsageBridge.windowsFromCodexRateLimits([
            "primary": NSNull(),
            "secondary": NSNull(),
        ]).isEmpty)
        // primary present but no usable fields
        XCTAssertTrue(UsageBridge.windowsFromCodexRateLimits([
            "primary": ["used_percent": "nope"],
        ]).isEmpty)
        XCTAssertNil(UsageBridge.planLabelFromCodexRateLimits(nil))
        XCTAssertNil(UsageBridge.planLabelFromCodexRateLimits(["plan_type": ""]))
        XCTAssertNil(UsageBridge.planLabelFromCodexRateLimits(["plan_type": "   "]))
    }

    func testCodexRateLimitsPrimaryOnly() {
        let windows = UsageBridge.windowsFromCodexRateLimits([
            "primary": [
                "used_percent": 12,
                "window_minutes": 300,
                "resets_at": 1_800_000_000,
            ],
            "secondary": NSNull(),
        ])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].kind, .fiveHour)
        XCTAssertEqual(windows[0].shortLabel, "5h 12%")
    }

    func testClaudeUsageStyleWindowPresentAndAbsent() {
        let w = UsageBridge.windowFromProvider(
            kind: .fiveHour,
            percentUsed: 42.7,
            resetsAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
        XCTAssertEqual(w?.kind, .fiveHour)
        XCTAssertEqual(w?.usedPercent ?? -1, 42.7, accuracy: 0.001)
        XCTAssertEqual(w?.shortLabel, "5h 43%")

        // No percent and no label+reset → nil (never invent 0%).
        XCTAssertNil(UsageBridge.windowFromProvider(kind: .sevenDay, percentUsed: nil))
        XCTAssertNil(UsageBridge.windowFromProvider(kind: .monthly, percentUsed: .nan))
    }

    func testSnapshotWithWindowsOnlyNoTokens() {
        let w = UsageWindow(kind: .sevenDay, usedPercent: 100)
        let snap = UsageBridge.snapshot(windows: [w])
        XCTAssertNotNil(snap)
        XCTAssertNil(snap?.tokensUsed)
        XCTAssertEqual(snap?.shortLabel, "7d 100%")
        XCTAssertTrue(snap?.hasAny == true)
    }

    func testEmptySnapshotStillNil() {
        XCTAssertNil(UsageBridge.snapshot())
        XCTAssertNil(UsageBridge.snapshot(tokensIn: 0, tokensOut: 0, windows: []))
    }

    func testKindFromWindowMinutesExact() {
        XCTAssertEqual(UsageBridge.kind(fromWindowMinutes: 300), .fiveHour)
        XCTAssertEqual(UsageBridge.kind(fromWindowMinutes: 10_080), .sevenDay)
        XCTAssertEqual(UsageBridge.kind(fromWindowMinutes: 43_200), .monthly)
        XCTAssertEqual(UsageBridge.kind(fromWindowMinutes: 999, preferred: .fiveHour), .fiveHour)
        XCTAssertEqual(UsageBridge.kind(fromWindowMinutes: nil), .other)
    }

    func testSessionPresenterSurfacesWindows() {
        let windows = [
            UsageWindow(kind: .fiveHour, usedPercent: 26, windowMinutes: 300),
            UsageWindow(kind: .sevenDay, usedPercent: 94, windowMinutes: 10_080),
        ]
        let session = AgentSession(
            id: "codex:s1",
            agentId: "codex",
            displayName: "Codex",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: Date(),
            tokensIn: 1000,
            tokensOut: 40,
            usageWindows: windows,
            usagePlanLabel: "plus"
        )
        let usage = SessionContentPresenter.usageFromSession(session)
        XCTAssertEqual(usage?.windows.count, 2)
        XCTAssertEqual(usage?.planLabel, "plus")
        XCTAssertEqual(usage?.shortLabel, "5h 26% · 7d 94%")

        // No tokens, no windows → nil
        let empty = AgentSession(
            id: "codex:empty",
            agentId: "codex",
            displayName: "Codex",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: Date()
        )
        XCTAssertNil(SessionContentPresenter.usageFromSession(empty))
    }

    func testCollapsedUsageChipShowsWindows() {
        let agent = AgentActivitySnapshot(
            id: "codex",
            displayName: "Codex",
            status: .midTask,
            lastTask: "working",
            source: "artifact",
            updatedAt: Date(),
            resumable: true,
            historyCount: 1,
            presence: .live
        )
        let usage: [String: AgentUsageSnapshot] = [
            "codex": UsageSnapshot(
                tokensUsed: 1040,
                windows: [
                    UsageWindow(kind: .fiveHour, usedPercent: 26),
                    UsageWindow(kind: .sevenDay, usedPercent: 94),
                ]
            ),
        ]
        let chip = SessionContentPresenter.collapsedUsageChip(
            agents: [agent],
            usageByAgent: usage
        )
        XCTAssertEqual(chip, "5h 26% · 7d 94%")
    }

    func testCodexReaderUsageSnapshotWiresWindows() {
        let rl: [String: Any] = [
            "primary": ["used_percent": 10.0, "window_minutes": 300, "resets_at": 1_800_000_000],
            "plan_type": "plus",
        ]
        let snap = CodexSessionReader.usageSnapshot(
            tokensIn: 100,
            tokensOut: 5,
            rateLimits: rl
        )
        XCTAssertEqual(snap?.tokensUsed, 105)
        XCTAssertEqual(snap?.windows.count, 1)
        XCTAssertEqual(snap?.planLabel, "plus")
        XCTAssertEqual(snap?.shortLabel, "5h 10%")

        XCTAssertNil(CodexSessionReader.usageSnapshot(
            tokensIn: nil,
            tokensOut: nil,
            rateLimits: nil
        ))
    }

    func testModuleName() {
        XCTAssertEqual(UsageCore.moduleName, "UsageCore")
    }
}
