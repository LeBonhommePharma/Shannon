import XCTest
@testable import PillCore

/// Pins the fail-closed honesty policies for expanded pill / popover chrome:
/// synthetic H never looks measured, battery "Calculating…" is not agent-busy
/// language when idle, dual-roster density drops empty "no H" strips, and
/// rail fill tracks the same display path as the H badge.
final class PopoverEntropyHonestyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let enforce = EntropyPolicy(maxAge: 120, warnBits: 5, maxBits: 64, mode: .enforce)

    private func status(
        entropy: Double = 8.7,
        deltaH: Double = 0.9,
        collapsed: Bool = false,
        backend: String
    ) -> ShannonStatus {
        ShannonStatus(
            entropy: entropy,
            deltaH: deltaH,
            collapsed: collapsed,
            tokenCount: 64,
            backend: backend
        )
    }

    private func measuredBridgeReading(
        bits: Double = 9.8,
        deltaH: Double = 1.8,
        backend: String = "vllm"
    ) -> EntropyReading {
        EntropyProvenance.resolve(
            bridgeConnected: true,
            bridgeStatus: status(entropy: bits, deltaH: deltaH, backend: backend),
            gate: [],
            gateDBAvailable: true,
            now: now,
            policy: enforce
        )
    }

    private func syntheticBridgeReading(backend: String = "demo") -> EntropyReading {
        EntropyProvenance.resolve(
            bridgeConnected: true,
            bridgeStatus: status(entropy: 8.7, deltaH: 0.9, backend: backend),
            gate: [],
            gateDBAvailable: true,
            now: now,
            policy: enforce
        )
    }

    // MARK: - Synthetic H strip (fail-closed)

    /// Screenshot defect: "H 8.7 ∇0.9" + footer "bridge demo · no measured H".
    func testSyntheticDemoNeverShowsMeasuredBadgeOrRail() {
        for backend in ShannonStatus.syntheticBackends {
            let reading = syntheticBridgeReading(backend: backend)
            let bridge = status(entropy: 8.7, deltaH: 0.9, backend: backend)

            XCTAssertFalse(
                EntropyStripPresentation.showsMeasuredBadge(
                    reading: reading, now: now, policy: enforce
                ),
                "backend \(backend) must not show measured H badge"
            )
            XCTAssertNil(
                EntropyStripPresentation.summaryLabel(
                    reading: reading,
                    bridgeStatus: bridge,
                    now: now,
                    policy: enforce
                ),
                "summaryLabel must not invent H from synthetic \(backend)"
            )
            XCTAssertFalse(
                EntropyStripPresentation.showsRail(
                    reading: reading, now: now, policy: enforce
                )
            )
            XCTAssertNil(
                EntropyStripPresentation.railFill(
                    reading: reading, now: now, policy: enforce
                )
            )
        }
    }

    func testSyntheticWatermarkDisclosesDemoBackend() {
        let demo = status(backend: "demo")
        let mark = EntropyStripPresentation.syntheticWatermark(
            bridgeConnected: true,
            bridgeStatus: demo
        )
        XCTAssertEqual(mark, "simulated · demo")

        let idle = EntropyStripPresentation.syntheticWatermark(
            bridgeConnected: true,
            bridgeStatus: status(backend: "idle")
        )
        XCTAssertEqual(idle, "simulated · idle")

        XCTAssertNil(
            EntropyStripPresentation.syntheticWatermark(
                bridgeConnected: false,
                bridgeStatus: demo
            )
        )
        XCTAssertNil(
            EntropyStripPresentation.syntheticWatermark(
                bridgeConnected: true,
                bridgeStatus: status(backend: "vllm")
            )
        )
    }

    func testMeasuredBridgeStillShowsHAndRail() {
        let reading = measuredBridgeReading(bits: 9.8, deltaH: 1.8)
        XCTAssertTrue(reading.isMeasured)
        XCTAssertTrue(
            EntropyStripPresentation.showsMeasuredBadge(
                reading: reading, now: now, policy: enforce
            )
        )
        let label = EntropyStripPresentation.summaryLabel(
            reading: reading,
            bridgeStatus: status(entropy: 9.8, deltaH: 1.8, backend: "vllm"),
            now: now,
            policy: enforce
        )
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("9.8") || label!.contains("9.80"), label ?? "nil")
        XCTAssertTrue(
            EntropyStripPresentation.showsRail(
                reading: reading, now: now, policy: enforce
            )
        )
        let fill = EntropyStripPresentation.railFill(
            reading: reading, now: now, policy: enforce
        )
        XCTAssertNotNil(fill)
        // H≈9.8 on token fullScale 12 → non-trivial fill (screenshot: empty rail fail).
        XCTAssertGreaterThan(fill!, 0.5, "high measured H must not paint an empty rail")
        XCTAssertLessThanOrEqual(fill!, 1.0)
    }

    /// Rail fill must use the same display bits as the badge (no second path).
    func testRailFillMatchesDisplayFillFraction() {
        let reading = measuredBridgeReading(bits: 8.0, deltaH: 0.5)
        guard let display = reading.display(at: now, policy: enforce) else {
            return XCTFail("measured reading must display")
        }
        guard let rail = EntropyStripPresentation.railFill(
            reading: reading, now: now, policy: enforce
        ) else {
            return XCTFail("railFill must match display path for measured H")
        }
        XCTAssertEqual(rail, display.fillFraction(), accuracy: 1e-12)
        XCTAssertEqual(
            rail,
            EntropyGauge.fillFraction(bits: display.bits, domain: .tokenDistribution),
            accuracy: 1e-12
        )
    }

    func testAbsentDetectorShowsNeitherBadgeNorWatermarkFromStatusFallback() {
        let reading = EntropyProvenance.resolve(
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [],
            gateDBAvailable: true,
            now: now,
            policy: enforce
        )
        XCTAssertNil(
            EntropyStripPresentation.summaryLabel(
                reading: reading,
                bridgeStatus: status(entropy: 8.0, backend: "demo"),
                now: now,
                policy: enforce
            ),
            "must never fall back to bridgeStatus.entropy when reading is absent"
        )
        XCTAssertFalse(
            EntropyStripPresentation.showsRail(
                reading: reading, now: now, policy: enforce
            )
        )
    }

    // MARK: - Battery Calculating… when idle

    func testIdleHubNeverShowsCalculatingWhenMinutesUnknown() {
        // Screenshot: hub ready · no agents busy + "Calculating…"
        let charging = BatteryChromePolicy.timeLabel(
            percentage: 80,
            isCharging: true,
            minutesToFull: nil,
            minutesToEmpty: nil,
            agentBusy: false
        )
        XCTAssertEqual(charging, "Charging")
        XCTAssertFalse(charging.contains("Calculating"))

        let onBattery = BatteryChromePolicy.timeLabel(
            percentage: 55,
            isCharging: false,
            minutesToFull: nil,
            minutesToEmpty: nil,
            agentBusy: false
        )
        XCTAssertEqual(onBattery, "On battery")
        XCTAssertFalse(onBattery.contains("Calculating"))
    }

    func testBusyAgentsMayShowCalculatingWhenEstimatePending() {
        XCTAssertEqual(
            BatteryChromePolicy.timeLabel(
                percentage: 40,
                isCharging: true,
                minutesToFull: nil,
                minutesToEmpty: nil,
                agentBusy: true
            ),
            "Calculating…"
        )
        XCTAssertEqual(
            BatteryChromePolicy.timeLabel(
                percentage: 40,
                isCharging: false,
                minutesToFull: nil,
                minutesToEmpty: nil,
                agentBusy: true
            ),
            "Calculating…"
        )
    }

    func testKnownMinutesStillPreferRealEstimate() {
        XCTAssertEqual(
            BatteryChromePolicy.timeLabel(
                percentage: 50,
                isCharging: true,
                minutesToFull: 80,
                minutesToEmpty: nil,
                agentBusy: false
            ),
            "\(BatterySnapshot.formatMinutes(80)) to full"
        )
        XCTAssertEqual(
            BatteryChromePolicy.timeLabel(
                percentage: 50,
                isCharging: false,
                minutesToFull: nil,
                minutesToEmpty: 185,
                agentBusy: false
            ),
            "\(BatterySnapshot.formatMinutes(185)) left"
        )
        XCTAssertEqual(
            BatteryChromePolicy.timeLabel(
                percentage: 100,
                isCharging: true,
                minutesToFull: nil,
                minutesToEmpty: nil,
                agentBusy: false
            ),
            "Charged"
        )
    }

    func testSnapshotConvenienceUsesBusyCount() {
        let snap = BatterySnapshot(
            percentage: 72,
            isCharging: true,
            minutesToFull: nil
        )
        // Raw snapshot still says Calculating… — policy gates on busyCount.
        XCTAssertEqual(snap.timeLabel, "Calculating…")
        XCTAssertEqual(
            BatteryChromePolicy.timeLabel(snapshot: snap, busyCount: 0),
            "Charging"
        )
        XCTAssertEqual(
            BatteryChromePolicy.timeLabel(snapshot: snap, busyCount: 2),
            "Calculating…"
        )
    }

    // MARK: - Dual roster / density (companion board vs entropy strip)

    /// Screenshot defect: companion rows + second "no H" Claude/Grok block.
    func testHidePerAgentStripWhenCompanionsVisibleAndNoMeasuredH() {
        XCTAssertFalse(
            ExpandedBoardDensity.showPerAgentEntropyStrip(
                companionBoardVisible: true,
                anyListedAgentHasMeasuredH: false
            )
        )
    }

    func testShowPerAgentStripWhenMeasuredHExists() {
        XCTAssertTrue(
            ExpandedBoardDensity.showPerAgentEntropyStrip(
                companionBoardVisible: true,
                anyListedAgentHasMeasuredH: true
            )
        )
    }

    func testShowPerAgentStripWithoutCompanionBoard() {
        // macOS 13 fallback uses agentRow only — strip is the roster surface.
        XCTAssertTrue(
            ExpandedBoardDensity.showPerAgentEntropyStrip(
                companionBoardVisible: false,
                anyListedAgentHasMeasuredH: false
            )
        )
    }

    func testAnyDisplayableHFromSyntheticReadingsIsFalse() {
        let demo = syntheticBridgeReading(backend: "demo")
        let map = [
            "claude_code": demo,
            "grok_build": demo,
        ]
        XCTAssertFalse(
            ExpandedBoardDensity.anyDisplayableH(
                readings: map, now: now, policy: enforce
            )
        )
        // With companions visible → suppress the second no-H strip.
        XCTAssertFalse(
            ExpandedBoardDensity.showPerAgentEntropyStrip(
                companionBoardVisible: true,
                anyListedAgentHasMeasuredH: ExpandedBoardDensity.anyDisplayableH(
                    readings: map, now: now, policy: enforce
                )
            )
        )
    }

    func testAnyDisplayableHTrueWhenOneAgentMeasured() {
        let map: [String: EntropyReading] = [
            "claude_code": syntheticBridgeReading(backend: "demo"),
            "grok_build": measuredBridgeReading(bits: 7.5),
        ]
        XCTAssertTrue(
            ExpandedBoardDensity.anyDisplayableH(
                readings: map, now: now, policy: enforce
            )
        )
    }

    /// Pulled-session dual list: same agentId on live roster must not reappear.
    func testPulledSessionsDropLiveRosterAgentIds() {
        let claude = AgentSession(
            id: "art:claude",
            agentId: "claude_code",
            displayName: "Claude Code",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: now,
            lastTask: "disk"
        )
        let codex = AgentSession(
            id: "art:codex",
            agentId: "codex",
            displayName: "Codex",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: now,
            lastTask: "other"
        )
        let filtered = SessionContentPresenter.sessionsExcludingLiveAgents(
            [claude, codex],
            liveAgentIds: ["claude_code", "grok_build"]
        )
        XCTAssertEqual(filtered.map(\.agentId), ["codex"])
        let cards = SessionContentPresenter.cards(
            sessions: [claude, codex],
            now: now,
            liveAgentIds: ["claude_code", "grok_build"]
        )
        XCTAssertEqual(cards.map(\.agentId), ["codex"])
    }
}
