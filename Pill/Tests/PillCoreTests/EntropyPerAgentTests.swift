import XCTest
@testable import PillCore

/// Per-agent entropy resolve/display path.
///
/// Pins the goal that gauges are **not** a single anonymous fleet H: two agents
/// with different measurements must resolve to independent readings, and
/// missing/stale/synthetic cases cannot masquerade as measured healthy H.
final class EntropyPerAgentTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let enforce = EntropyPolicy(maxAge: 120, warnBits: 5, maxBits: 64, mode: .enforce)
    private let observe = EntropyPolicy(maxAge: 120, warnBits: 5, maxBits: 64, mode: .observe)

    private func gate(
        agent: String,
        bits: Double,
        secondsAgo: TimeInterval = 5,
        presence: AgentPresence = .live,
        deltaH: Double? = nil,
        collapsed: Bool? = nil,
        policy: EntropyPolicy? = nil
    ) -> EntropyMeasurement {
        let m = EntropyMeasurement(
            bits: bits,
            deltaH: deltaH,
            collapsed: collapsed,
            source: .gate(agentId: agent, presence: presence),
            measuredAt: now.addingTimeInterval(-secondsAgo),
            now: now,
            policy: policy ?? enforce
        )
        guard let m else {
            XCTFail("gate fixture refused: agent=\(agent) bits=\(bits)")
            return EntropyMeasurement(
                bits: 1, source: .gate(agentId: agent, presence: .live),
                measuredAt: now, now: now
            )!
        }
        return m
    }

    private func status(
        entropy: Double = 7.2,
        deltaH: Double = -0.1,
        collapsed: Bool = false,
        backend: String,
        agent: String? = nil
    ) -> ShannonStatus {
        ShannonStatus(
            entropy: entropy, deltaH: deltaH, collapsed: collapsed,
            tokenCount: 10, backend: backend, agent: agent
        )
    }

    // MARK: Independent H per agent

    /// Two live agents with different H must each display their own bits.
    func testTwoAgentsResolveIndependentH() {
        let gateRows = [
            gate(agent: "claude_code", bits: 8.25),
            gate(agent: "codex", bits: 2.40),
        ]
        let map = EntropyProvenance.resolveAll(
            agentIds: ["claude_code", "codex"],
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: gateRows,
            gateDBAvailable: true,
            now: now,
            policy: enforce
        )

        XCTAssertEqual(map.count, 2)

        guard let claude = map["claude_code"], let codex = map["codex"] else {
            return XCTFail("both agents must resolve")
        }
        guard let claudeDisplay = claude.display(at: now, policy: enforce),
              let codexDisplay = codex.display(at: now, policy: enforce) else {
            return XCTFail("both agents must produce display values")
        }

        // Drive the shipped display path — not a reimplementation of fill math.
        XCTAssertEqual(claudeDisplay.bits, 8.25, accuracy: 1e-9)
        XCTAssertEqual(codexDisplay.bits, 2.40, accuracy: 1e-9)
        XCTAssertTrue(claude.isMeasured)
        XCTAssertTrue(codex.isMeasured)
        XCTAssertNotEqual(claudeDisplay.bits, codexDisplay.bits)

        // Fill fractions must track each agent's bits independently (domain-aware scale).
        let claudeFill = claudeDisplay.fillFraction()
        let codexFill = codexDisplay.fillFraction()
        XCTAssertGreaterThan(claudeFill, codexFill)
        XCTAssertEqual(
            claudeFill,
            EntropyGauge.fillFraction(
                bits: 8.25,
                fullScale: EntropyGauge.fullScale(for: claudeDisplay.domain),
                domain: claudeDisplay.domain
            ),
            accuracy: 1e-12
        )
        XCTAssertEqual(
            codexFill,
            EntropyGauge.fillFraction(
                bits: 2.40,
                fullScale: EntropyGauge.fullScale(for: codexDisplay.domain),
                domain: codexDisplay.domain
            ),
            accuracy: 1e-12
        )

        // Aggregate-only resolve is still available, but is not the only path.
        let fleet = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil,
            gate: gateRows, gateDBAvailable: true, now: now, policy: enforce
        )
        XCTAssertTrue(fleet.isMeasured)
        XCTAssertEqual(claude.currentBits ?? -1, 8.25, accuracy: 1e-9)
        XCTAssertEqual(codex.currentBits ?? -1, 2.40, accuracy: 1e-9)
    }

    func testResolveOrderedPreservesAgentIdentity() {
        let gateRows = [
            gate(agent: "science", bits: 6.1),
            gate(agent: "terminal", bits: 3.3),
        ]
        let ordered = EntropyProvenance.resolveOrdered(
            agentIds: ["terminal", "science", "terminal"],
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: gateRows,
            now: now,
            policy: enforce
        )
        XCTAssertEqual(ordered.map(\.agentId), ["terminal", "science"])
        XCTAssertEqual(ordered[0].reading.currentBits ?? -1, 3.3, accuracy: 1e-9)
        XCTAssertEqual(ordered[1].reading.currentBits ?? -1, 6.1, accuracy: 1e-9)
    }

    // MARK: Missing / stale / synthetic

    func testMissingAgentIsAbsentNotHealthy() {
        let reading = EntropyProvenance.resolveForAgent(
            agentId: "missing_agent",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "other", bits: 7.0)],
            gateDBAvailable: true,
            now: now,
            policy: enforce
        )
        XCTAssertTrue(reading.isAbsent)
        XCTAssertEqual(reading.verdict(policy: enforce), EntropyVerdict.unknown)
        XCTAssertNil(reading.currentBits)
        XCTAssertNil(reading.display(at: now, policy: enforce))
    }

    func testStaleAgentIsNotMeasuredUnderEnforce() {
        let reading = EntropyProvenance.resolveForAgent(
            agentId: "stale_bot",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "stale_bot", bits: 7.5, secondsAgo: 600)],
            now: now,
            policy: enforce
        )
        XCTAssertTrue(reading.isStale)
        XCTAssertFalse(reading.isMeasured)
        XCTAssertNil(reading.currentBits)
        XCTAssertNil(reading.display(at: now, policy: enforce))
        // Observe mode may still show the number, labelled not-current.
        guard let shown = reading.display(at: now, policy: observe) else {
            return XCTFail("observe mode must still display stale numbers")
        }
        XCTAssertEqual(shown.bits, 7.5, accuracy: 1e-9)
        XCTAssertFalse(shown.isCurrent)
        XCTAssertEqual(shown.badge, "H_msg⌛")
    }

    func testOfflineGateRowIsStaleEvenIfRecent() {
        let reading = EntropyProvenance.resolveForAgent(
            agentId: "gone",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "gone", bits: 4.2, secondsAgo: 2, presence: .offline)],
            now: now,
            policy: enforce
        )
        XCTAssertTrue(reading.isStale)
        XCTAssertNil(reading.display(at: now, policy: enforce))
    }

    func testSyntheticBridgeDoesNotPaintEveryAgent() {
        // Unnamed demo bridge must not assign its sine wave to every agent id.
        let demo = status(entropy: 8.0, deltaH: -2.0, collapsed: true, backend: "demo")
        let map = EntropyProvenance.resolveAll(
            agentIds: ["claude_code", "codex"],
            bridgeConnected: true,
            bridgeStatus: demo,
            gate: [],
            gateDBAvailable: true,
            now: now,
            policy: enforce
        )
        for (id, reading) in map {
            XCTAssertFalse(reading.isMeasured, "\(id) must not measure synthetic fleet bridge")
            XCTAssertNil(reading.currentBits)
            XCTAssertNil(reading.display(at: now, policy: enforce))
            XCTAssertNotEqual(reading.verdict(policy: enforce), EntropyVerdict.healthy)
            XCTAssertNotEqual(reading.verdict(policy: enforce), EntropyVerdict.collapsed)
        }
    }

    func testNamedSyntheticBridgeIsAbsentForThatAgent() {
        let demo = status(
            entropy: 8.0, deltaH: -2.0, collapsed: true,
            backend: "demo", agent: "claude_code"
        )
        let reading = EntropyProvenance.resolveForAgent(
            agentId: "claude_code",
            bridgeConnected: true,
            bridgeStatus: demo,
            gate: [],
            now: now,
            policy: enforce
        )
        XCTAssertTrue(reading.isAbsent)
        if case .absent(.syntheticSource(let b)) = reading {
            XCTAssertEqual(b, "demo")
        } else {
            XCTFail("expected syntheticSource absence, got \(reading)")
        }
    }

    func testNamedRealBridgeAttachesOnlyToNamedAgent() {
        let live = status(
            entropy: 9.1, deltaH: -0.2, collapsed: false,
            backend: "vllm", agent: "science"
        )
        let map = EntropyProvenance.resolveAll(
            agentIds: ["science", "codex"],
            bridgeConnected: true,
            bridgeStatus: live,
            gate: [gate(agent: "codex", bits: 3.0)],
            now: now,
            policy: enforce
        )
        XCTAssertEqual(map["science"]?.currentBits ?? -1, 9.1, accuracy: 1e-9)
        XCTAssertEqual(map["codex"]?.currentBits ?? -1, 3.0, accuracy: 1e-9)
        XCTAssertEqual(map["science"]?.measurement?.source, EntropySource.bridge(backend: "vllm"))
    }

    // MARK: Collapse / companion deltas per agent

    func testCollapseOnlyOnOwningAgent() {
        // Token-distribution collapse is bridge-only (low H / collapsed flag).
        // Gate message scores never claim `.collapsed` regardless of bits.
        let ok = EntropyProvenance.resolveForAgent(
            agentId: "ok",
            bridgeConnected: true,
            bridgeStatus: status(entropy: 8.0, collapsed: false, backend: "vllm", agent: "ok"),
            gate: [], now: now, policy: enforce
        )
        let bad = EntropyProvenance.resolveForAgent(
            agentId: "bad",
            bridgeConnected: true,
            bridgeStatus: status(
                entropy: 1.5, deltaH: -4.0, collapsed: true, backend: "vllm", agent: "bad"
            ),
            gate: [], now: now, policy: enforce
        )
        // Gate-only low H_msg is healthy (message score normal), not collapse.
        let gateLow = EntropyProvenance.resolveForAgent(
            agentId: "msg",
            bridgeConnected: false, bridgeStatus: nil,
            gate: [gate(agent: "msg", bits: 1.5)], now: now, policy: enforce
        )
        XCTAssertEqual(ok.verdict(policy: enforce), EntropyVerdict.healthy)
        XCTAssertEqual(bad.verdict(policy: enforce), EntropyVerdict.collapsed)
        XCTAssertEqual(gateLow.verdict(policy: enforce), EntropyVerdict.healthy)
        XCTAssertNotEqual(ok.collapsed, true)
        XCTAssertEqual(bad.collapsed, true)
    }

    func testCompanionDeltasArePerAgent() {
        let gateRows = [
            gate(agent: "calm", bits: 8.0, deltaH: -0.1),
            gate(agent: "spiky", bits: 2.0, deltaH: -5.0, collapsed: true),
        ]
        let deltas = EntropyProvenance.companionDeltas(
            agentIds: ["calm", "spiky", "missing"],
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: gateRows,
            now: now,
            policy: enforce
        )
        XCTAssertEqual(deltas["calm"] ?? 0, -0.1, accuracy: 1e-9)
        XCTAssertEqual(deltas["spiky"] ?? 0, -5.0, accuracy: 1e-9)
        XCTAssertNil(deltas["missing"])

        // End-to-end: only the collapsed agent goes wary.
        let summary = AgentActivitySummary(agents: [
            AgentActivitySnapshot(
                id: "calm", displayName: "Calm", status: .idle,
                lastTask: "", source: "test", updatedAt: now,
                resumable: false, historyCount: 1, presence: .live
            ),
            AgentActivitySnapshot(
                id: "spiky", displayName: "Spiky", status: .idle,
                lastTask: "", source: "test", updatedAt: now,
                resumable: false, historyCount: 1, presence: .live
            ),
        ], scannedAt: now)

        let roster = CompanionRoster.build(
            from: summary, now: now, entropyDeltas: deltas
        )
        let byId = Dictionary(uniqueKeysWithValues: roster.map { ($0.agent.id, $0.mood) })
        XCTAssertNotEqual(byId["calm"], CompanionMood.wary)
        XCTAssertEqual(byId["spiky"], CompanionMood.wary)
    }

    func testSharedFleetDeltaDoesNotOverridePerAgentMap() {
        let summary = AgentActivitySummary(agents: [
            AgentActivitySnapshot(
                id: "a", displayName: "A", status: .idle,
                lastTask: "", source: "test", updatedAt: now,
                resumable: false, historyCount: 0, presence: .live
            ),
            AgentActivitySnapshot(
                id: "b", displayName: "B", status: .idle,
                lastTask: "", source: "test", updatedAt: now,
                resumable: false, historyCount: 0, presence: .live
            ),
        ], scannedAt: now)
        // Shared legacy delta must not alarm every live pet when multi-agent:
        // only sole-live gets the fleet fallback (production attach path).
        // Per-agent map still alarms "b" independently.
        let roster = CompanionRoster.build(
            from: summary,
            now: now,
            entropyDeltas: ["b": -5.0],
            entropyDelta: -9.0
        )
        let byId = Dictionary(uniqueKeysWithValues: roster.map { ($0.agent.id, $0.mood) })
        XCTAssertNotEqual(byId["a"], CompanionMood.wary, "shared fleet delta must not multi-alarm")
        XCTAssertEqual(byId["b"], CompanionMood.wary)
    }

    func testPerAgentMapAloneDoesNotAlarmOthers() {
        let summary = AgentActivitySummary(agents: [
            AgentActivitySnapshot(
                id: "a", displayName: "A", status: .idle,
                lastTask: "", source: "test", updatedAt: now,
                resumable: false, historyCount: 0, presence: .live
            ),
            AgentActivitySnapshot(
                id: "b", displayName: "B", status: .idle,
                lastTask: "", source: "test", updatedAt: now,
                resumable: false, historyCount: 0, presence: .live
            ),
        ], scannedAt: now)
        let roster = CompanionRoster.build(
            from: summary,
            now: now,
            entropyDeltas: ["b": -5.0]
            // no shared entropyDelta
        )
        let byId = Dictionary(uniqueKeysWithValues: roster.map { ($0.agent.id, $0.mood) })
        XCTAssertNotEqual(byId["a"], CompanionMood.wary)
        XCTAssertEqual(byId["b"], CompanionMood.wary)
    }

    // MARK: Gauge geometry

    func testFillFractionTracksBits() {
        XCTAssertEqual(EntropyGauge.fillFraction(bits: 0), 0.04, accuracy: 1e-12)
        XCTAssertEqual(EntropyGauge.fillFraction(bits: 6), 0.5, accuracy: 1e-12)
        XCTAssertEqual(EntropyGauge.fillFraction(bits: 12), 1.0, accuracy: 1e-12)
        XCTAssertEqual(EntropyGauge.fillFraction(bits: 100), 1.0, accuracy: 1e-12)
        XCTAssertEqual(EntropyGauge.fillFraction(bits: .nan), 0.04, accuracy: 1e-12)
        // Monotonic over the usable range
        let a = EntropyGauge.fillFraction(bits: 2)
        let b = EntropyGauge.fillFraction(bits: 6)
        let c = EntropyGauge.fillFraction(bits: 11)
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }

    /// Message domain inverts: high H_msg is danger-red, low is teal.
    func testMessageDomainInvertsPolarity() {
        let highMsg = EntropyGauge.colorRGB(
            bits: 6.5, fullScale: 8, domain: .messageContent, isCurrent: true
        )
        let lowMsg = EntropyGauge.colorRGB(
            bits: 2.0, fullScale: 8, domain: .messageContent, isCurrent: true
        )
        // High message score → red-dominant (danger)
        XCTAssertGreaterThan(highMsg.r, highMsg.g)
        // Low message score → greener/teal (safe)
        XCTAssertGreaterThan(lowMsg.g, lowMsg.r)

        let lowToken = EntropyGauge.colorRGB(
            bits: 2.0, fullScale: 12, domain: .tokenDistribution, isCurrent: true
        )
        // Token low stays red (collapse) — opposite of message low.
        XCTAssertGreaterThan(lowToken.r, lowToken.g)
    }

    func testStaleDesaturatesTowardNeutral() {
        let live = EntropyGauge.colorRGB(bits: 2.0, domain: .tokenDistribution, isCurrent: true)
        let stale = EntropyGauge.colorRGB(bits: 2.0, domain: .tokenDistribution, isCurrent: false)
        // Stale should move closer to neutral mid-grey than live red.
        let neutral = EntropyColorRGB(r: 0.45, g: 0.48, b: 0.55)
        XCTAssertLessThan(stale.distance(to: neutral), live.distance(to: neutral))
        XCTAssertNotEqual(live, stale)
    }

    /// Continuous multi-stop gradient: mid H is not pure red / yellow / green.
    func testColorGradientIsContinuousMultiStop() {
        let low = EntropyGauge.colorRGB(bits: 1.5)   // collapse end
        let mid = EntropyGauge.colorRGB(bits: 6.0)   // chartreuse band
        let high = EntropyGauge.colorRGB(bits: 11.0) // healthy teal end
        let nanC = EntropyGauge.colorRGB(bits: .nan)

        // Low is red-dominant
        XCTAssertGreaterThan(low.r, low.g)
        XCTAssertGreaterThan(low.r, low.b)
        // High is green/cyan dominant (not pure red)
        XCTAssertGreaterThan(high.g, high.r)
        // Mid chartreuse: both R and G elevated, not a pure token
        XCTAssertGreaterThan(mid.g, 0.5)
        XCTAssertGreaterThan(mid.r, 0.4)
        XCTAssertNotEqual(mid, low)
        XCTAssertNotEqual(mid, high)

        // Pure solid RYG tokens (approximate) — mid must not match them.
        let pureRed = EntropyColorRGB(r: 1, g: 0, b: 0)
        let pureYellow = EntropyColorRGB(r: 1, g: 1, b: 0)
        let pureGreen = EntropyColorRGB(r: 0, g: 1, b: 0)
        XCTAssertGreaterThan(mid.distance(to: pureRed), 0.35)
        XCTAssertGreaterThan(mid.distance(to: pureYellow), 0.15)
        XCTAssertGreaterThan(mid.distance(to: pureGreen), 0.35)

        // Continuity: small bit steps move color smoothly (no huge jumps)
        var prev = EntropyGauge.colorRGB(bits: 0.5)
        for bits in stride(from: 1.0, through: 12.0, by: 0.5) {
            let cur = EntropyGauge.colorRGB(bits: bits)
            XCTAssertLessThan(
                prev.distance(to: cur), 0.35,
                "jump at H=\(bits) too large for continuous gradient"
            )
            prev = cur
        }

        // Non-finite → neutral greyish, not a traffic-light color
        XCTAssertLessThan(abs(nanC.r - nanC.g), 0.15)
        XCTAssertLessThan(abs(nanC.g - nanC.b), 0.15)
    }

    func testDisplayGaugeColorTracksBits() {
        let reading = EntropyProvenance.resolveForAgent(
            agentId: "grad",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "grad", bits: 6.0)],
            now: now,
            policy: enforce
        )
        guard let display = reading.display(at: now, policy: enforce) else {
            return XCTFail("must display")
        }
        let fromDisplay = display.gaugeColorRGB()
        let fromBits = EntropyGauge.colorRGB(
            bits: 6.0,
            fullScale: EntropyGauge.fullScale(for: display.domain),
            domain: display.domain,
            isCurrent: display.isCurrent
        )
        XCTAssertEqual(fromDisplay.r, fromBits.r, accuracy: 1e-12)
        XCTAssertEqual(fromDisplay.g, fromBits.g, accuracy: 1e-12)
        XCTAssertEqual(fromDisplay.b, fromBits.b, accuracy: 1e-12)
        XCTAssertEqual(
            display.fillFraction(),
            EntropyGauge.fillFraction(
                bits: 6.0,
                fullScale: EntropyGauge.fullScale(for: display.domain),
                domain: display.domain
            ),
            accuracy: 1e-12
        )
    }

    func testDisplayShortLabelUsesShippedBadge() {
        let measured = EntropyProvenance.resolveForAgent(
            agentId: "x",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "x", bits: 4.5)],
            now: now,
            policy: enforce
        )
        guard let display = measured.display(at: now, policy: enforce) else {
            return XCTFail("measured agent must display")
        }
        XCTAssertEqual(display.shortLabel, "H_msg 4.50")
        XCTAssertEqual(display.badge, "H_msg")
    }

    func testGateDBUnavailableIsDistinctAbsence() {
        let reading = EntropyProvenance.resolveForAgent(
            agentId: "any",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [],
            gateDBAvailable: false,
            now: now,
            policy: enforce
        )
        XCTAssertEqual(reading.absence, EntropyAbsence.gateUnavailable)
    }

    /// Responsive path: when the same agent receives a new H, display updates.
    func testDisplayTracksChangingHForSameAgent() {
        let early = EntropyProvenance.resolveForAgent(
            agentId: "agent",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "agent", bits: 7.0, secondsAgo: 10)],
            now: now,
            policy: enforce
        )
        let later = EntropyProvenance.resolveForAgent(
            agentId: "agent",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "agent", bits: 3.5, secondsAgo: 1)],
            now: now,
            policy: enforce
        )
        guard let earlyD = early.display(at: now, policy: enforce),
              let laterD = later.display(at: now, policy: enforce) else {
            return XCTFail("both snapshots must display")
        }
        XCTAssertEqual(earlyD.bits, 7.0, accuracy: 1e-9)
        XCTAssertEqual(laterD.bits, 3.5, accuracy: 1e-9)
        XCTAssertNotEqual(earlyD.fillFraction(), laterD.fillFraction())
    }
}
