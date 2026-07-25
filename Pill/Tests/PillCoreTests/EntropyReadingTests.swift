import XCTest
@testable import PillCore

/// Regression cover for the pill's entropy provenance.
///
/// The defect these lock down: the readout used to synthesise
/// `7.2 + 0.55*sin(2πt/6)` with `collapsed: false` whenever no detector was
/// attached, so a DEAD detector rendered as a permanently HEALTHY one — parked
/// in the safe band and structurally unable to trip the threshold. Every test
/// below exists to make that state unreachable rather than merely unlikely.
final class EntropyReadingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let enforce = EntropyPolicy(maxAge: 120, warnBits: 5, maxBits: 64, mode: .enforce)
    private let observe = EntropyPolicy(maxAge: 120, warnBits: 5, maxBits: 64, mode: .observe)

    private func gateMeasurement(
        agent: String = "claude_code",
        bits: Double = 2.86,
        secondsAgo: TimeInterval = 5,
        presence: AgentPresence = .live,
        policy: EntropyPolicy? = nil
    ) -> EntropyMeasurement {
        let m = EntropyMeasurement(
            bits: bits,
            source: .gate(agentId: agent, presence: presence),
            measuredAt: now.addingTimeInterval(-secondsAgo),
            now: now,
            policy: policy ?? enforce
        )
        return XCTUnwrapOrFail(m)
    }

    private func XCTUnwrapOrFail(_ m: EntropyMeasurement?) -> EntropyMeasurement {
        guard let m else {
            XCTFail("fixture measurement was refused by validation")
            return EntropyMeasurement(
                bits: 1, source: .gate(agentId: "x", presence: .live),
                measuredAt: now, now: now
            )!
        }
        return m
    }

    private func status(
        entropy: Double = 7.2, deltaH: Double = 0, collapsed: Bool = false, backend: String
    ) -> ShannonStatus {
        ShannonStatus(entropy: entropy, deltaH: deltaH, collapsed: collapsed,
                      tokenCount: 10, backend: backend)
    }

    // MARK: - REQUIRED: an absent detector cannot produce a 'healthy' verdict

    /// The headline regression. No detector, no gate rows — the reading must be
    /// `.absent`, must hold no number, and must not be healthy.
    func testAbsentDetectorIsNeverHealthy() {
        let reading = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil,
            gate: [], gateDBAvailable: true, now: now, policy: enforce
        )
        XCTAssertTrue(reading.isAbsent)
        XCTAssertEqual(reading.absence, .noDetector)
        XCTAssertNotEqual(reading.verdict(policy: enforce), .healthy)
        XCTAssertEqual(reading.verdict(policy: enforce), .unknown)
        XCTAssertFalse(reading.verdict(policy: enforce).isHealthy)
        XCTAssertNil(reading.currentBits, "absent must not carry a number")
        XCTAssertNil(reading.measurement)
        XCTAssertNil(reading.display(at: now, policy: enforce))
    }

    /// The idle placeholder is the exact source of the original defect: it is
    /// what the pill fell back to when nothing was attached.
    func testIdlePlaceholderResolvesToAbsentNotHealthy() {
        let reading = EntropyProvenance.resolve(
            bridgeConnected: false,
            bridgeStatus: IdleTelemetry.absentStatus,
            gate: [], gateDBAvailable: true, now: now, policy: enforce
        )
        XCTAssertTrue(reading.isAbsent)
        XCTAssertNotEqual(reading.verdict(policy: enforce), .healthy)
        XCTAssertNil(reading.currentBits)
    }

    /// No absence reason, under no policy and no mode, is ever healthy or
    /// numeric. Exhaustive so a future case cannot be added with a value.
    func testNoAbsenceReasonIsEverHealthyOrNumericUnderAnyPolicy() {
        let absences: [EntropyAbsence] = [
            .noDetector, .gateUnavailable,
            .syntheticSource("demo"), .syntheticSource(""),
            .rejected("H=NaN"),
        ]
        let policies = [
            enforce, observe,
            EntropyPolicy(maxAge: 86_400, warnBits: 0, maxBits: 1024, mode: .observe),
            EntropyPolicy(maxAge: 1, warnBits: 64, maxBits: 64, mode: .enforce),
        ]
        for absence in absences {
            let reading = EntropyReading.absent(absence)
            for policy in policies {
                XCTAssertEqual(reading.verdict(policy: policy), .unknown,
                               "\(absence) went conclusive under \(policy)")
                XCTAssertFalse(reading.verdict(policy: policy).isHealthy)
                XCTAssertNil(reading.display(at: now, policy: policy),
                             "\(absence) produced a renderable number under \(policy)")
                XCTAssertTrue(reading.suppressesNumericDisplay(policy: policy),
                              "absent must be suppressed in every mode, incl. observe")
            }
            XCTAssertNil(reading.currentBits)
            XCTAssertNil(reading.measurement)
            XCTAssertNil(reading.age(at: now))
            XCTAssertFalse(reading.explain(at: now, policy: enforce).isEmpty)
        }
    }

    /// A connected producer that fabricates its numbers is absence, not health.
    /// `pill_bridge --demo` opens a real socket and serves `8.0 + 2.0*sin(n/12)`.
    func testSyntheticBackendIsAbsentNotHealthy() {
        for backend in ShannonStatus.syntheticBackends {
            let reading = EntropyProvenance.resolve(
                bridgeConnected: true,
                bridgeStatus: status(entropy: 8.0, backend: backend),
                gate: [], gateDBAvailable: true, now: now, policy: enforce
            )
            XCTAssertTrue(reading.isAbsent, "backend '\(backend)' was not treated as absent")
            XCTAssertEqual(reading.absence, .syntheticSource(backend.trimmingCharacters(in: .whitespaces)))
            XCTAssertNotEqual(reading.verdict(policy: enforce), .healthy)
            XCTAssertNil(reading.currentBits)
        }
    }

    // MARK: - REQUIRED: unknown is not false

    /// The inverted failure mode, stated directly: nothing may assert
    /// "not collapsed" unless something measured it.
    func testCollapsedIsNilNotFalseWhenNothingMeasuredIt() {
        let absent = EntropyReading.absent(.noDetector)
        XCTAssertNil(absent.collapsed)
        XCTAssertNotEqual(absent.collapsed, false, "unknown must not read as 'not collapsed'")

        let stale = EntropyReading.stale(gateMeasurement(secondsAgo: 3600), age: 3600)
        XCTAssertNil(stale.collapsed, "a stale reading no longer describes the present")

        // And the wire type agrees: a synthetic producer's `collapsed` is not a
        // measurement, whatever the struct field happens to hold.
        XCTAssertNil(IdleTelemetry.absentStatus.measuredCollapsed)
        XCTAssertNil(status(collapsed: false, backend: "demo").measuredCollapsed)
        XCTAssertNil(status(collapsed: true, backend: "demo").measuredCollapsed)
        XCTAssertEqual(status(collapsed: false, backend: "cpp").measuredCollapsed, false)
        XCTAssertEqual(status(collapsed: true, backend: "cpp").measuredCollapsed, true)
    }

    /// The struct's `collapsed: false` on the absent sentinel must not be
    /// reachable as a verdict through any accessor on the reading.
    func testAbsentSentinelCannotYieldANotCollapsedVerdict() {
        let reading = EntropyProvenance.resolve(
            bridgeConnected: true,
            bridgeStatus: IdleTelemetry.absentStatus,
            gate: [], gateDBAvailable: true, now: now, policy: enforce
        )
        XCTAssertNil(reading.collapsed)
        XCTAssertEqual(reading.verdict(policy: enforce), .unknown)
        XCTAssertFalse(reading.verdict(policy: enforce).isHealthy)
    }

    // MARK: - REQUIRED: a stale gate reading is not presented as current

    func testGateReadingOlderThanMaxAgeIsStaleNotMeasured() {
        let old = gateMeasurement(bits: 2.86, secondsAgo: 40 * 60)
        let reading = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil,
            gate: [old], gateDBAvailable: true, now: now, policy: enforce
        )
        XCTAssertTrue(reading.isStale)
        XCTAssertFalse(reading.isMeasured)
        XCTAssertNil(reading.currentBits, "a 40-minute-old value is not a current reading")
        XCTAssertEqual(reading.verdict(policy: enforce), .unknown)
        XCTAssertEqual(reading.staleAge ?? 0, 2400, accuracy: 0.5)
        // Under enforce the number is withheld entirely.
        XCTAssertNil(reading.display(at: now, policy: enforce))
        XCTAssertTrue(reading.explain(at: now, policy: enforce).contains("STALE"))
    }

    /// Observe mode may keep showing the number, but never as a current one.
    func testStaleUnderObserveModeIsShownButFlaggedNotCurrent() {
        let old = gateMeasurement(bits: 2.86, secondsAgo: 40 * 60)
        let reading = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil,
            gate: [old], gateDBAvailable: true, now: now, policy: observe
        )
        guard let display = reading.display(at: now, policy: observe) else {
            return XCTFail("observe mode should still surface the stale number")
        }
        XCTAssertEqual(display.bits, 2.86, accuracy: 1e-9)
        XCTAssertFalse(display.isCurrent, "observe mode must not relabel stale as current")
        XCTAssertEqual(display.badge, "H⌛")
        XCTAssertEqual(display.age, 2400, accuracy: 0.5)
        XCTAssertEqual(reading.measurement?.deltaH, nil, "gate rows carry no per-agent delta")
        // The verdict is unaffected by mode — observe never buys health.
        XCTAssertEqual(reading.verdict(policy: observe), .unknown)
        XCTAssertNil(reading.currentBits)
        XCTAssertTrue(reading.wouldSuppressNumericDisplay,
                      "operator must be able to see what enforce would have done")
    }

    /// An agent the gate knows has hung up is stale at *any* age: its last H
    /// measured a conversation that has ended.
    func testDisconnectedAgentIsStaleEvenWhenTimestampIsFresh() {
        for presence in [AgentPresence.offline, .observed] {
            let m = gateMeasurement(secondsAgo: 1, presence: presence)
            let reading = EntropyProvenance.resolve(
                bridgeConnected: false, bridgeStatus: nil,
                gate: [m], gateDBAvailable: true, now: now, policy: enforce
            )
            XCTAssertTrue(reading.isStale, "presence \(presence) must not read as current")
            XCTAssertNil(reading.currentBits)
        }
    }

    func testFreshLiveGateReadingIsMeasuredAndCarriesProvenance() {
        let m = gateMeasurement(agent: "codex", bits: 2.63, secondsAgo: 3)
        let reading = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil,
            gate: [m], gateDBAvailable: true, now: now, policy: enforce
        )
        XCTAssertTrue(reading.isMeasured)
        XCTAssertEqual(reading.currentBits ?? 0, 2.63, accuracy: 1e-9)
        // 2.63 < warnBits 5.0 → watch, not healthy. Real collapse-range data.
        XCTAssertEqual(reading.verdict(policy: enforce), .watch)
        let display = reading.display(at: now, policy: enforce)
        XCTAssertEqual(display?.source, .gate(agentId: "codex", presence: .live))
        XCTAssertEqual(display?.isCurrent, true)
        XCTAssertEqual(display?.badge, "H")
        XCTAssertTrue(reading.explain(at: now, policy: enforce).contains("gate:codex"))
    }

    // MARK: - REQUIRED: no numeric entropy without provenance

    /// Sweeps the whole resolver input space. Any reading that yields a number
    /// must name where it came from and when; any reading that does not must
    /// yield no number at all and no conclusive verdict.
    func testNoNumberIsEverObtainableWithoutProvenance() {
        let backends = ["cpp", "numba", "numpy", "demo", "idle", "unknown", "", "absent"]
        let ages: [TimeInterval] = [0, 5, 119, 121, 2400, 40 * 3600]
        let presences: [AgentPresence] = [.live, .offline, .observed]

        for connected in [true, false] {
            for backend in backends {
                for age in ages {
                    for presence in presences {
                        for policy in [enforce, observe] {
                            let gate = EntropyMeasurement(
                                bits: 3.5,
                                source: .gate(agentId: "a", presence: presence),
                                measuredAt: now.addingTimeInterval(-age),
                                now: now, policy: policy
                            ).map { [$0] } ?? []
                            let reading = EntropyProvenance.resolve(
                                bridgeConnected: connected,
                                bridgeStatus: status(backend: backend),
                                gate: gate, gateDBAvailable: true,
                                now: now, policy: policy
                            )
                            let ctx = "connected=\(connected) backend=\(backend) "
                                + "age=\(age) presence=\(presence) mode=\(policy.mode)"

                            if let display = reading.display(at: now, policy: policy) {
                                // A number came out. It must be attributed.
                                XCTAssertFalse(display.source.label.isEmpty, ctx)
                                XCTAssertNotNil(reading.measurement, ctx)
                                XCTAssertGreaterThan(display.bits, 0, ctx)
                                if display.isCurrent {
                                    XCTAssertTrue(reading.isMeasured, ctx)
                                    XCTAssertNotNil(reading.currentBits, ctx)
                                } else {
                                    XCTAssertTrue(reading.isStale, ctx)
                                    XCTAssertNil(reading.currentBits, ctx)
                                }
                            }
                            if !reading.isMeasured {
                                XCTAssertNil(reading.currentBits, ctx)
                                XCTAssertNil(reading.collapsed, ctx)
                                XCTAssertEqual(reading.verdict(policy: policy), .unknown, ctx)
                            }
                            if reading.isAbsent {
                                XCTAssertNil(reading.measurement, ctx)
                                XCTAssertNil(reading.display(at: now, policy: policy), ctx)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Fail-closed construction

    func testMeasurementRefusesUnusableValues() {
        let src = EntropySource.gate(agentId: "a", presence: .live)
        func make(_ bits: Double, at offset: TimeInterval = -10, deltaH: Double? = nil)
            -> EntropyMeasurement? {
            EntropyMeasurement(bits: bits, deltaH: deltaH, source: src,
                               measuredAt: now.addingTimeInterval(offset),
                               now: now, policy: enforce)
        }
        XCTAssertNil(make(.nan), "NaN")
        XCTAssertNil(make(.infinity), "infinity")
        XCTAssertNil(make(-1), "negative")
        XCTAssertNil(make(0), "zero — indistinguishable from the DEFAULT 0.0")
        XCTAssertNil(make(64.1), "above policy.maxBits")
        XCTAssertNil(make(3.5, deltaH: .nan), "non-finite delta")
        XCTAssertNil(make(3.5, at: 60), "future-dated beyond the skew tolerance")
        XCTAssertNotNil(make(3.5, at: -EntropyPolicy.clockSkewTolerance + 1),
                        "small negative age is tolerated, not rejected")
        XCTAssertNotNil(make(64.0), "exactly maxBits is allowed")
    }

    /// A connected, real-backend detector serving a garbage number must produce
    /// an explicit refusal — not a silent fallback to some other source, which
    /// would hide an active fault.
    func testConnectedDetectorWithOutOfRangeValueIsRejectedNotSubstituted() {
        let fresh = gateMeasurement(bits: 4.0, secondsAgo: 1)
        let reading = EntropyProvenance.resolve(
            bridgeConnected: true,
            bridgeStatus: status(entropy: 900, backend: "cpp"),
            gate: [fresh], gateDBAvailable: true, now: now, policy: enforce
        )
        guard case .absent(.rejected(let why)) = reading else {
            return XCTFail("expected .rejected, got \(reading)")
        }
        XCTAssertTrue(why.contains("cpp"))
        XCTAssertNil(reading.currentBits)
        XCTAssertNotEqual(reading.verdict(policy: enforce), .healthy)
    }

    func testUnreadableGateDBIsDistinctFromNoDetector() {
        let reading = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil,
            gate: [], gateDBAvailable: false, now: now, policy: enforce
        )
        XCTAssertEqual(reading.absence, .gateUnavailable)
        XCTAssertNotEqual(reading.verdict(policy: enforce), .healthy)
    }

    // MARK: - Determinism

    /// Row order out of SQLite must not change the answer.
    func testResolutionIsIndependentOfInputOrder() {
        let a = gateMeasurement(agent: "aaa", bits: 3.0, secondsAgo: 10)
        let b = gateMeasurement(agent: "bbb", bits: 4.0, secondsAgo: 5)
        let c = gateMeasurement(agent: "ccc", bits: 5.0, secondsAgo: 5, presence: .offline)
        let permutations = [[a, b, c], [c, b, a], [b, c, a], [c, a, b], [a, c, b], [b, a, c]]
        let expected = EntropyProvenance.resolve(
            bridgeConnected: false, bridgeStatus: nil, gate: [a, b, c],
            gateDBAvailable: true, now: now, policy: enforce
        )
        for p in permutations {
            let got = EntropyProvenance.resolve(
                bridgeConnected: false, bridgeStatus: nil, gate: p,
                gateDBAvailable: true, now: now, policy: enforce
            )
            XCTAssertEqual(got, expected, "order changed the reading: \(p.map(\.source.label))")
        }
        XCTAssertEqual(expected.currentBits ?? 0, 4.0, accuracy: 1e-9, "newest live wins")
    }

    /// Identical timestamps must still resolve identically every time.
    func testTiesBreakDeterministicallyOnAgentId() {
        let a = gateMeasurement(agent: "zzz", bits: 3.0, secondsAgo: 5)
        let b = gateMeasurement(agent: "aaa", bits: 4.0, secondsAgo: 5)
        for _ in 0..<20 {
            let r = EntropyProvenance.resolve(
                bridgeConnected: false, bridgeStatus: nil, gate: [a, b],
                gateDBAvailable: true, now: now, policy: enforce
            )
            XCTAssertEqual(r.currentBits ?? 0, 4.0, accuracy: 1e-9)
        }
    }

    // MARK: - Operator surface

    func testPolicyDefaultsAreSafeAndDocumented() {
        let p = EntropyPolicy.fromEnvironment([:])
        XCTAssertEqual(p.maxAge, 120)
        XCTAssertEqual(p.warnBits, 5.0)
        XCTAssertEqual(p.maxBits, 64)
        XCTAssertEqual(p.mode, .enforce, "the strict mode is the default")
    }

    func testPolicyParsesEnvAndFallsBackToSafeDefaultsOnGarbage() {
        let good = EntropyPolicy.fromEnvironment([
            "SHANNON_PILL_ENTROPY_MAX_AGE": "30",
            "SHANNON_PILL_ENTROPY_WARN_BITS": "4",
            "SHANNON_PILL_ENTROPY_MAX_BITS": "32",
            "SHANNON_PILL_ENTROPY_MODE": "observe",
        ])
        XCTAssertEqual(good.maxAge, 30)
        XCTAssertEqual(good.warnBits, 4)
        XCTAssertEqual(good.maxBits, 32)
        XCTAssertEqual(good.mode, .observe)

        for garbage in ["", "  ", "banana", "NaN", "-1e400"] {
            let p = EntropyPolicy.fromEnvironment([
                "SHANNON_PILL_ENTROPY_MAX_AGE": garbage,
                "SHANNON_PILL_ENTROPY_MODE": garbage,
            ])
            XCTAssertEqual(p.maxAge, 120, "garbage '\(garbage)' must fall back to the default")
            XCTAssertEqual(p.mode, .enforce, "garbage '\(garbage)' must not select observe")
        }
        // An unrecognised mode is never the permissive one.
        XCTAssertEqual(EntropyPolicy.fromEnvironment(
            ["SHANNON_PILL_ENTROPY_MODE": "yolo"]).mode, .enforce)
        // Case and whitespace are tolerated for the mode that *is* valid.
        XCTAssertEqual(EntropyPolicy.fromEnvironment(
            ["SHANNON_PILL_ENTROPY_MODE": " OBSERVE "]).mode, .observe)
    }

    func testPolicyClampsOutOfRangeValuesRatherThanTrustingThem() {
        let wide = EntropyPolicy.fromEnvironment([
            "SHANNON_PILL_ENTROPY_MAX_AGE": "9999999",
            "SHANNON_PILL_ENTROPY_MAX_BITS": "999999",
        ])
        XCTAssertEqual(wide.maxAge, EntropyPolicy.maxMaxAge)
        XCTAssertEqual(wide.maxBits, EntropyPolicy.maxMaxBits)

        let narrow = EntropyPolicy.fromEnvironment([
            "SHANNON_PILL_ENTROPY_MAX_AGE": "-5",
            "SHANNON_PILL_ENTROPY_MAX_BITS": "0",
        ])
        XCTAssertEqual(narrow.maxAge, EntropyPolicy.minMaxAge)
        XCTAssertEqual(narrow.maxBits, EntropyPolicy.minMaxBits)
        XCTAssertLessThanOrEqual(narrow.warnBits, narrow.maxBits,
                                 "warn threshold can never exceed the accepted range")
    }

    /// Observe mode is a display concession only. It must not be able to make
    /// anything healthy — that is the defect, and it is not configurable.
    func testObserveModeCannotUpgradeAnyReading() {
        let inputs: [EntropyReading] = [
            .absent(.noDetector), .absent(.gateUnavailable),
            .absent(.syntheticSource("demo")), .absent(.rejected("x")),
            .stale(gateMeasurement(secondsAgo: 3600), age: 3600),
        ]
        for reading in inputs {
            XCTAssertEqual(reading.verdict(policy: observe), .unknown)
            XCTAssertEqual(reading.verdict(policy: enforce),
                           reading.verdict(policy: observe),
                           "mode changed a verdict")
        }
    }

    func testVerdictBandsForMeasuredReadings() {
        func verdict(_ bits: Double, collapsed: Bool? = nil) -> EntropyVerdict {
            let m = EntropyMeasurement(
                bits: bits, collapsed: collapsed,
                source: .bridge(backend: "cpp"), measuredAt: now, now: now, policy: enforce
            )
            return EntropyReading.measured(XCTUnwrapOrFail(m)).verdict(policy: enforce)
        }
        XCTAssertEqual(verdict(8.4), .healthy)
        XCTAssertEqual(verdict(5.0), .healthy, "exactly at the threshold is not yet a warning")
        XCTAssertEqual(verdict(4.99), .watch)
        XCTAssertEqual(verdict(8.4, collapsed: true), .collapsed)
        XCTAssertEqual(verdict(8.4, collapsed: false), .healthy)
    }
}
