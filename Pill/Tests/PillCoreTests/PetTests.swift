import XCTest
@testable import PillCore

// Tests for the companion pets.
//
// The first class is the important one. Everything else is character work; the
// honesty matrix is the thing that stops the pets from re-introducing the bug
// they were removed over — a pet that says "focused" because a stale
// state.json on disk says "active".

// MARK: - Helpers

private func snapshot(
    id: String = "science",
    status: AgentRunStatus = .idle,
    presence: AgentPresence = .observed,
    secondsAgo: TimeInterval = 5,
    historyCount: Int = 0,
    now: Date = Date()
) -> AgentActivitySnapshot {
    AgentActivitySnapshot(
        id: id,
        displayName: AgentStyleCatalog.style(for: id).displayName,
        status: status,
        lastTask: "docking 1ACJ",
        source: "test",
        updatedAt: now.addingTimeInterval(-secondsAgo),
        resumable: false,
        historyCount: historyCount,
        presence: presence
    )
}

// MARK: - The honesty matrix

final class CompanionMoodHonestyTests: XCTestCase {

    /// The load-bearing invariant. Only live gate telemetry may produce a mood
    /// that claims the agent is working. Exhaustive over presence × status.
    func testOnlyLivePresenceCanEverClaimWork() {
        for presence in AgentPresence.allCases {
            for status in [AgentRunStatus.active, .midTask, .blocked, .idle, .unknown] {
                let mood = CompanionMood.resolve(
                    presence: presence, status: status, secondsSinceSeen: 1
                )
                if presence == .live && status.isBusy {
                    XCTAssertEqual(mood, .alert,
                                   "live+\(status) should be alert, got \(mood)")
                } else {
                    XCTAssertFalse(mood.claimsWork,
                                   "\(presence)+\(status) must not claim work, got \(mood)")
                    XCTAssertNotEqual(mood, .alert)
                }
            }
        }
    }

    /// The exact shape of the data sitting in ~/.shannon/pets today: ⌘D wrote
    /// `"status": "active"` for a browser two days ago and nothing cleared it.
    /// The companion must read that as asleep, not as work.
    func testStaleObservedActiveRecordIsSleepyNotAlert() {
        let twoDays: TimeInterval = 2 * 86_400
        let mood = CompanionMood.resolve(
            presence: .observed, status: .active, secondsSinceSeen: twoDays
        )
        XCTAssertEqual(mood, .sleepy)
        XCTAssertFalse(mood.claimsWork)
    }

    /// A *fresh* observation is still only an observation.
    func testFreshObservedActiveRecordIsIdleNotAlert() {
        let mood = CompanionMood.resolve(
            presence: .observed, status: .active, secondsSinceSeen: 3
        )
        XCTAssertEqual(mood, .idle)
    }

    func testOfflineIsAlwaysSleepyEvenWhenFreshlySeen() {
        XCTAssertEqual(
            CompanionMood.resolve(presence: .offline, status: .midTask, secondsSinceSeen: 0),
            .sleepy
        )
    }

    func testLiveButQuietIsIdleUntilItGoesStale() {
        XCTAssertEqual(
            CompanionMood.resolve(presence: .live, status: .idle, secondsSinceSeen: 10),
            .idle
        )
        XCTAssertEqual(
            CompanionMood.resolve(presence: .live, status: .idle,
                                  secondsSinceSeen: CompanionMood.sleepyAfter + 1),
            .sleepy
        )
    }

    /// Exactly one mood is allowed to assert work.
    func testExactlyOneMoodClaimsWork() {
        XCTAssertEqual(CompanionMood.allCases.filter(\.claimsWork), [.alert])
    }
}

// MARK: - Entropy

final class CompanionMoodEntropyTests: XCTestCase {

    func testCollapseMakesTheCompanionWary() {
        let mood = CompanionMood.resolve(
            presence: .live, status: .active, secondsSinceSeen: 1, entropyDelta: -4.0
        )
        XCTAssertEqual(mood, .wary)
    }

    /// A collapse must outrank a celebration: a companion that bounces happily
    /// through an entropy collapse is the exact "all fine" lie Shannon exists
    /// to catch.
    func testCollapseOutranksApproval() {
        let mood = CompanionMood.resolve(
            presence: .live, status: .idle, secondsSinceSeen: 1,
            secondsSinceApproval: 0.1, entropyDelta: -5.0
        )
        XCTAssertEqual(mood, .wary)
    }

    func testCollapseOutranksAlert() {
        let mood = CompanionMood.resolve(
            presence: .live, status: .midTask, secondsSinceSeen: 1, entropyDelta: -3.5
        )
        XCTAssertEqual(mood, .wary)
    }

    func testThresholdBoundaryIsInclusive() {
        let at = CompanionMood.resolve(presence: .live, status: .idle,
                                       secondsSinceSeen: 1, entropyDelta: -3.2)
        let just = CompanionMood.resolve(presence: .live, status: .idle,
                                         secondsSinceSeen: 1, entropyDelta: -3.19)
        XCTAssertEqual(at, .wary)
        XCTAssertEqual(just, .idle)
    }

    func testDefaultThresholdIsShannonsShippingValue() {
        XCTAssertEqual(CompanionMood.defaultCollapseThreshold, -3.2, accuracy: 1e-9)
    }

    /// A collapse is a claim about a token stream we are currently reading.
    /// Attributing one to an app we merely *saw* through ⌘D would be invention.
    func testCollapseIsIgnoredWithoutLivePresence() {
        for presence in [AgentPresence.observed, .offline] {
            let mood = CompanionMood.resolve(
                presence: presence, status: .idle, secondsSinceSeen: 1, entropyDelta: -9.0
            )
            XCTAssertNotEqual(mood, .wary, "\(presence) must not be able to go wary")
        }
    }

    func testNilEntropyNeverGoesWary() {
        let mood = CompanionMood.resolve(presence: .live, status: .idle,
                                         secondsSinceSeen: 1, entropyDelta: nil)
        XCTAssertEqual(mood, .idle)
    }

    /// Positive deltas (entropy *rising*) are not a collapse.
    func testPositiveDeltaIsNotACollapse() {
        let mood = CompanionMood.resolve(presence: .live, status: .idle,
                                         secondsSinceSeen: 1, entropyDelta: 4.0)
        XCTAssertEqual(mood, .idle)
    }
}

// MARK: - Approval

final class CompanionMoodApprovalTests: XCTestCase {

    func testApprovalIsHappyInsideTheWindow() {
        let mood = CompanionMood.resolve(presence: .live, status: .idle,
                                         secondsSinceSeen: 1, secondsSinceApproval: 0.2)
        XCTAssertEqual(mood, .happy)
    }

    func testApprovalExpiresAndFallsBackToTheUnderlyingMood() {
        let mood = CompanionMood.resolve(
            presence: .live, status: .active, secondsSinceSeen: 1,
            secondsSinceApproval: CompanionMood.happyDuration + 0.01
        )
        XCTAssertEqual(mood, .alert)
    }

    /// An approval must not license a work claim for an observed agent.
    func testExpiredApprovalOnObservedAgentDoesNotBecomeAlert() {
        let mood = CompanionMood.resolve(
            presence: .observed, status: .active, secondsSinceSeen: 1,
            secondsSinceApproval: 5
        )
        XCTAssertEqual(mood, .idle)
    }
}

// MARK: - Kind mapping and artwork fallback

final class CompanionKindTests: XCTestCase {

    func testDrawnPetsResolve() {
        for name in ["owl", "raven", "fox", "dolphin", "wolf", "beaver", "gear"] {
            XCTAssertNotNil(CompanionKind(petName: name), "\(name) should be drawable")
        }
    }

    /// A missing drawing must never silently render as the wrong animal — these
    /// fall back to the agent's SF Symbol instead.
    func testUndrawnPetsReturnNil() {
        for name in ["parrot", "tortoise", "gecko", "cat", "ladybug", "", "unicorn"] {
            XCTAssertNil(CompanionKind(petName: name), "\(name) must not resolve")
        }
    }

    func testMappingIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(CompanionKind(petName: "  OWL "), .owl)
    }

    func testEveryCatalogAgentHasEitherArtworkOrASymbol() {
        for style in AgentStyleCatalog.all {
            if CompanionKind(petName: style.pet) == nil {
                XCTAssertFalse(style.petSymbol.isEmpty,
                               "\(style.id) has no artwork and no fallback symbol")
            }
        }
    }

    func testForAgentUsesTheCatalog() {
        XCTAssertEqual(CompanionKind.forAgent(id: "science"), .owl)
        XCTAssertEqual(CompanionKind.forAgent(id: "dispatch"), .wolf)
        XCTAssertNil(CompanionKind.forAgent(id: "terminal"))   // tortoise, undrawn
        XCTAssertNil(CompanionKind.forAgent(id: "no_such_agent"))
    }
}

// MARK: - Personality

final class CompanionPersonalityTests: XCTestCase {

    func testEveryKindHasUsableTiming() {
        for kind in CompanionKind.allCases {
            let p = kind.personality
            XCTAssertGreaterThan(p.breathPeriod, 0, "\(kind)")
            XCTAssertGreaterThan(p.blinkPeriod, 0, "\(kind)")
            XCTAssertTrue((0 ... 1).contains(p.breathPhase), "\(kind)")
            XCTAssertGreaterThanOrEqual(p.swayAmp, 0, "\(kind)")
            XCTAssertGreaterThanOrEqual(p.alertEyeWiden, 1, "\(kind)")
        }
    }

    /// The whole point of per-kind personality: a board of pets must not
    /// breathe as one body.
    func testAnimalsDoNotShareABreathPhase() {
        let animals = CompanionKind.allCases.filter { $0 != .gear }
        let phases = Set(animals.map(\.personality.breathPhase))
        XCTAssertEqual(phases.count, animals.count, "two animals share a breath phase")
    }

    func testGearIsInanimate() {
        let p = CompanionKind.gear.personality
        XCTAssertEqual(p.swayAmp, 0)
        XCTAssertEqual(p.alertEyeWiden, 1)
    }
}

// MARK: - Motion

final class CompanionMotionTests: XCTestCase {

    private let moods = CompanionMood.allCases

    /// Analytic, not stateful: the same clock value always gives the same frame.
    func testFrameIsPureAndPhaseLocked() {
        for kind in CompanionKind.allCases {
            for mood in moods {
                let a = CompanionMotion.frame(kind: kind, mood: mood, t: 123.456, happyElapsed: 0.1)
                let b = CompanionMotion.frame(kind: kind, mood: mood, t: 123.456, happyElapsed: 0.1)
                XCTAssertEqual(a, b, "\(kind)/\(mood) is not deterministic")
            }
        }
    }

    func testFrameStaysInsideItsDesignEnvelope() {
        for kind in CompanionKind.allCases {
            for mood in moods {
                for i in 0 ..< 400 {
                    let t = Double(i) * 0.037
                    let f = CompanionMotion.frame(kind: kind, mood: mood, t: t,
                                                  happyElapsed: t.truncatingRemainder(dividingBy: 0.4))
                    XCTAssertTrue((0.9 ... 1.1).contains(f.breath), "\(kind)/\(mood) breath \(f.breath)")
                    XCTAssertGreaterThanOrEqual(f.eyeOpen, 0, "\(kind)/\(mood)")
                    XCTAssertLessThanOrEqual(f.eyeOpen, 2.0, "\(kind)/\(mood)")
                    XCTAssertTrue((-1 ... 1).contains(f.lean), "\(kind)/\(mood) lean \(f.lean)")
                    XCTAssertTrue((-6.0 ... 1.0).contains(f.yOffset), "\(kind)/\(mood)")
                    XCTAssertLessThanOrEqual(abs(f.sway), 1.0, "\(kind)/\(mood) sway \(f.sway)")
                }
            }
        }
    }

    /// A blink that never fires is the failure mode that makes eyes look
    /// painted on. Sample a full cycle and insist the lids actually drop.
    func testIdleBlinkActuallyFiresForEveryAnimal() {
        for kind in CompanionKind.allCases where kind != .gear {
            let period = kind.personality.blinkPeriod
            var minOpen = Double.greatestFiniteMagnitude
            for i in 0 ... 4_000 {
                let t = Double(i) / 4_000 * period
                minOpen = min(minOpen, CompanionMotion.frame(kind: kind, mood: .idle, t: t).eyeOpen)
            }
            XCTAssertLessThan(minOpen, 0.3, "\(kind) never blinks within its own period")
        }
    }

    func testDoubleBlinkKindsDropTheLidsTwicePerCycle() {
        for kind in CompanionKind.allCases where kind.personality.doubleBlink {
            let period = kind.personality.blinkPeriod
            var dips = 0
            var inDip = false
            for i in 0 ... 8_000 {
                let t = Double(i) / 8_000 * period
                let shut = CompanionMotion.frame(kind: kind, mood: .idle, t: t).eyeOpen < 0.6
                if shut && !inDip { dips += 1 }
                inDip = shut
            }
            XCTAssertGreaterThanOrEqual(dips, 2, "\(kind) should double-blink, saw \(dips) dip(s)")
        }
    }

    func testSwayingKindsActuallyDrift() {
        for kind in CompanionKind.allCases where kind.personality.swayAmp > 0 {
            let period = kind.personality.breathPeriod * 2.3
            var maxSway = 0.0
            for i in 0 ... 500 {
                let t = Double(i) / 500 * period
                maxSway = max(maxSway, abs(CompanionMotion.frame(kind: kind, mood: .idle, t: t).sway))
            }
            XCTAssertGreaterThan(maxSway, kind.personality.swayAmp * 0.9, "\(kind) does not sway")
        }
    }

    func testGearHasNoLungsLidsOrSway() {
        for mood in moods where mood != .happy {
            for i in 0 ..< 50 {
                let f = CompanionMotion.frame(kind: .gear, mood: mood, t: Double(i) * 0.31)
                XCTAssertEqual(f.breath, 1, "gear breathed in \(mood)")
                XCTAssertEqual(f.eyeOpen, 1, "gear blinked in \(mood)")
                XCTAssertEqual(f.sway, 0, "gear swayed in \(mood)")
                XCTAssertEqual(f.lean, 0, "gear leaned in \(mood)")
            }
        }
    }

    func testGearSpinsFasterWhenAlertThanWhenIdle() {
        let idle  = CompanionMotion.gearSpin(mood: .idle, t: 60)
        let alert = CompanionMotion.gearSpin(mood: .alert, t: 60)
        let happy = CompanionMotion.gearSpin(mood: .happy, t: 60)
        XCTAssertGreaterThan(alert, idle)
        XCTAssertGreaterThan(happy, alert)
    }

    func testSleepyGearHoldsStillForMostOfItsCycle() {
        // Still for the first 80% of a 2.5 s cycle, then steps one tooth.
        let held  = CompanionMotion.gearSpin(mood: .sleepy, t: 0.1)
        let still = CompanionMotion.gearSpin(mood: .sleepy, t: 1.9)
        XCTAssertEqual(held, still, accuracy: 1e-9, "sleepy gear should not creep")
    }

    func testHappyBounceRisesAndSettles() {
        let start = CompanionMotion.frame(kind: .fox, mood: .happy, t: 0, happyElapsed: 0)
        let peak  = CompanionMotion.frame(kind: .fox, mood: .happy, t: 0,
                                          happyElapsed: CompanionMood.happyDuration / 2)
        let end   = CompanionMotion.frame(kind: .fox, mood: .happy, t: 0,
                                          happyElapsed: CompanionMood.happyDuration)
        XCTAssertEqual(start.yOffset, 0, accuracy: 1e-9)
        XCTAssertEqual(end.yOffset, 0, accuracy: 1e-9)
        XCTAssertLessThan(peak.yOffset, -3.5, "the bounce should lift the pet")
    }

    func testSleepyDroopsAndCloses() {
        for kind in CompanionKind.allCases where kind != .gear {
            let f = CompanionMotion.frame(kind: kind, mood: .sleepy, t: 7.3)
            XCTAssertLessThan(f.eyeOpen, 0.35, "\(kind) sleepy eyes should be shut")
            XCTAssertGreaterThan(f.headDroop, 0, "\(kind) sleepy head should hang")
        }
    }

    /// Wary is a flinch, not a stare-and-blink: the eyes stay locked open for a
    /// full blink cycle, and the body leans away rather than forward.
    func testWaryNeverBlinksAndLeansAway() {
        for kind in CompanionKind.allCases where kind != .gear {
            let period = kind.personality.blinkPeriod
            for i in 0 ... 600 {
                let t = Double(i) / 600 * period
                let f = CompanionMotion.frame(kind: kind, mood: .wary, t: t)
                XCTAssertGreaterThan(f.eyeOpen, 1, "\(kind) blinked while wary")
                XCTAssertLessThan(f.lean, 0, "\(kind) should flinch back when wary")
            }
        }
    }

    func testAlertLeansForwardAndWidensTheEyes() {
        for kind in CompanionKind.allCases where kind != .gear {
            let f = CompanionMotion.frame(kind: kind, mood: .alert, t: 3.0)
            XCTAssertGreaterThan(f.lean, 0, "\(kind)")
            XCTAssertEqual(f.eyeOpen, kind.personality.alertEyeWiden, accuracy: 1e-9, "\(kind)")
        }
    }

    func testSparkleDecaysAcrossTheHappyWindow() {
        XCTAssertGreaterThan(CompanionMotion.sparkleEnvelope(elapsed: 0), 0.99)
        XCTAssertEqual(CompanionMotion.sparkleEnvelope(elapsed: CompanionMood.happyDuration),
                       0, accuracy: 1e-9)
        XCTAssertEqual(CompanionMotion.sparkleEnvelope(elapsed: 99), 0)
    }
}

// MARK: - Bond

final class CompanionBondTests: XCTestCase {

    func testTenureThresholds() {
        XCTAssertEqual(CompanionBond.from(historyCount: 0), .fresh)
        XCTAssertEqual(CompanionBond.from(historyCount: 9), .fresh)
        XCTAssertEqual(CompanionBond.from(historyCount: 10), .familiar)
        XCTAssertEqual(CompanionBond.from(historyCount: 99), .familiar)
        XCTAssertEqual(CompanionBond.from(historyCount: 100), .seasoned)
        XCTAssertEqual(CompanionBond.from(historyCount: 999), .seasoned)
        XCTAssertEqual(CompanionBond.from(historyCount: 1_000), .veteran)
    }

    /// Tenure is monotone in real recorded turns — unlike the XP it replaced,
    /// nothing the user does can inflate or reset it.
    func testTenureNeverGoesBackwards() {
        var previous = CompanionBond.fresh
        for n in stride(from: 0, through: 2_000, by: 7) {
            let bond = CompanionBond.from(historyCount: n)
            XCTAssertGreaterThanOrEqual(bond, previous)
            previous = bond
        }
    }
}

// MARK: - CompanionState / roster

final class CompanionStateTests: XCTestCase {

    func testStateCarriesArtworkAndBranding() {
        let state = CompanionState(agent: snapshot(id: "science"))
        XCTAssertEqual(state.kind, .owl)
        XCTAssertEqual(state.petName, "owl")
        XCTAssertEqual(state.id, "science")
    }

    func testStateFallsBackToTheSymbolForUndrawnPets() {
        let state = CompanionState(agent: snapshot(id: "terminal"))
        XCTAssertNil(state.kind)
        XCTAssertEqual(state.symbolFallback, "tortoise.fill")
    }

    /// The companion restates status softly, but the hard evidence is always
    /// carried alongside it.
    func testAccessibilityLineAlwaysIncludesTheHonestStatusLine() {
        let agent = snapshot(id: "science", status: .active, presence: .observed,
                             secondsAgo: 800)
        let state = CompanionState(agent: agent)
        XCTAssertTrue(state.accessibilityLine.contains(agent.statusLine),
                      "\(state.accessibilityLine) is missing \(agent.statusLine)")
        XCTAssertTrue(state.accessibilityLine.contains("owl"))
    }

    func testMoodLineNeverClaimsWorkForAnObservedAgent() {
        let state = CompanionState(agent: snapshot(status: .active, presence: .observed,
                                                   secondsAgo: 2))
        XCTAssertFalse(state.moodLine.contains("focused"))
    }

    func testHistoryCountDrivesBond() {
        XCTAssertEqual(CompanionState(agent: snapshot(historyCount: 250)).bond, .seasoned)
    }
}

final class CompanionRosterTests: XCTestCase {

    func testOrderingPutsProvableWorkFirstThenLiveThenRecency() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snapshot(id: "cursor",   status: .idle,   presence: .observed, secondsAgo: 5,  now: now),
            snapshot(id: "codex",    status: .idle,   presence: .live,     secondsAgo: 40, now: now),
            snapshot(id: "science",  status: .active,  presence: .live,     secondsAgo: 2,  now: now),
            snapshot(id: "chatgpt",  status: .idle,   presence: .observed, secondsAgo: 90, now: now),
        ], scannedAt: now)

        let roster = CompanionRoster.build(from: summary, now: now)
        XCTAssertEqual(roster.map(\.id), ["science", "codex", "cursor", "chatgpt"])
        XCTAssertEqual(roster[0].mood, .alert)
        XCTAssertEqual(roster[1].mood, .idle)
    }

    /// The roster must not smear a machine-wide collapse across agents it only
    /// observed through ⌘D.
    func testEntropyDeltaOnlyReachesLiveAgents() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snapshot(id: "science", status: .idle, presence: .live,     secondsAgo: 1, now: now),
            snapshot(id: "cursor",  status: .idle, presence: .observed, secondsAgo: 1, now: now),
            snapshot(id: "codex",   status: .idle, presence: .offline,  secondsAgo: 1, now: now),
        ], scannedAt: now)

        let roster = CompanionRoster.build(from: summary, now: now, entropyDelta: -6.0)
        let byID = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, $0.mood) })
        XCTAssertEqual(byID["science"], .wary)
        XCTAssertEqual(byID["cursor"], .idle)
        XCTAssertEqual(byID["codex"], .sleepy)
    }

    func testApprovalsAreAppliedPerAgent() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snapshot(id: "science", status: .idle, presence: .live, secondsAgo: 1, now: now),
            snapshot(id: "codex",   status: .idle, presence: .live, secondsAgo: 1, now: now),
        ], scannedAt: now)

        let roster = CompanionRoster.build(
            from: summary, now: now,
            approvals: ["science": now.addingTimeInterval(-0.1)]
        )
        let byID = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, $0.mood) })
        XCTAssertEqual(byID["science"], .happy)
        XCTAssertEqual(byID["codex"], .idle)
    }

    func testEmptySummaryProducesAnEmptyRoster() {
        XCTAssertTrue(CompanionRoster.build(from: AgentActivitySummary()).isEmpty)
    }

    /// No arrangement of pet/registry data may light the board up.
    func testNoObservedOnlyBoardCanEverClaimWork() {
        let now = Date()
        let agents = [AgentRunStatus.active, .midTask, .blocked, .idle, .unknown].map {
            snapshot(id: "science", status: $0, presence: .observed, secondsAgo: 1, now: now)
        }
        let roster = CompanionRoster.build(from: AgentActivitySummary(agents: agents,
                                                                      scannedAt: now),
                                           now: now, entropyDelta: -9)
        XCTAssertTrue(roster.allSatisfy { !$0.mood.claimsWork })
    }
}
