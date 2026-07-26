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

    /// T3: review/failed motion must not surface idle mood words on moodLine.
    func testMoodLineHonestWhenOutcomeDrivesReviewOrFailed() {
        let review = CompanionState(
            agent: snapshot(status: .idle, presence: .live, secondsAgo: 1),
            lastOutcome: "success"
        )
        XCTAssertEqual(review.codexMotion, .review)
        XCTAssertEqual(review.mood, .idle)
        XCTAssertEqual(review.moodDisplayWord, "ready")
        XCTAssertFalse(review.moodLine.contains("resting"))
        XCTAssertTrue(review.accessibilityLine.contains("ready"))

        let failed = CompanionState(
            agent: snapshot(status: .idle, presence: .live, secondsAgo: 1),
            lastOutcome: "error"
        )
        XCTAssertEqual(failed.codexMotion, .failed)
        XCTAssertEqual(failed.moodDisplayWord, "uneasy")
        XCTAssertFalse(failed.moodLine.contains("resting"))
        XCTAssertTrue(failed.accessibilityLine.contains("uneasy"))
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
        // ENH-016: matches rankedAgents — working first, then idle by displayName.
        // ChatGPT < Codex < Cursor among idle catalog names.
        XCTAssertEqual(roster.map(\.id), ["science", "chatgpt", "codex", "cursor"])
        XCTAssertEqual(roster[0].mood, .alert)
        XCTAssertEqual(roster[1].mood, .idle)
        let ranked = AgentLiveSurfaceLogic.rankedAgents(
            agents: summary.agents, now: now, limit: 8
        )
        XCTAssertEqual(roster.map(\.id), ranked.map(\.id))
    }

    /// ENH-016: finished-vs-working edge — companions follow attention rank,
    /// not mood/waiting heuristics (working before finished).
    func testOrderingAlignsWithRankedAgentsFinishedVsWorking() {
        let now = Date()
        let working = snapshot(id: "codex", status: .midTask, presence: .live, secondsAgo: 1, now: now)
        let finishedAgent = snapshot(id: "claude_code", status: .idle, presence: .live, secondsAgo: 1, now: now)
        let activity = [
            GateDBReader.ActivityEvent(
                id: 1, agentId: "codex", at: now.addingTimeInterval(-2),
                type: "tool_call", label: "Edited x", output: ""
            ),
            GateDBReader.ActivityEvent(
                id: 2, agentId: "claude_code", at: now.addingTimeInterval(-1),
                type: "task_complete", label: "Done", output: ""
            ),
        ]
        let summary = AgentActivitySummary(agents: [finishedAgent, working], scannedAt: now)
        let roster = CompanionRoster.build(
            from: summary, now: now, activity: activity
        )
        let ranked = AgentLiveSurfaceLogic.rankedAgents(
            agents: summary.agents,
            activity: activity,
            now: now,
            limit: 4
        )
        XCTAssertEqual(roster.map(\.id), ranked.map(\.id))
        XCTAssertEqual(roster.map(\.id).first, "codex", "working outranks finished")
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

// MARK: - Codex motion vocabulary (atlas responsiveness)

final class PetCodexMotionTests: XCTestCase {

    func testCoreVocabularyPresent() {
        let labels = Set(PetCodexMotion.core.map(\.rawValue))
        for name in ["idle", "running", "waiting", "failed", "review"] {
            XCTAssertTrue(labels.contains(name), "missing \(name)")
        }
    }

    func testLiveBusyIsRunning() {
        let m = PetCodexMotion.map(.init(presence: .live, status: .active))
        XCTAssertEqual(m, .running)
        XCTAssertTrue(m.claimsWork)
    }

    func testLiveBlockedIsWaiting() {
        XCTAssertEqual(
            PetCodexMotion.map(.init(presence: .live, status: .blocked)),
            .waiting
        )
    }

    func testPendingAskIsWaiting() {
        XCTAssertEqual(
            PetCodexMotion.map(.init(presence: .live, status: .active, hasPendingAsk: true)),
            .waiting
        )
    }

    func testFailedOutcome() {
        XCTAssertEqual(
            PetCodexMotion.map(.init(presence: .live, status: .idle, lastOutcome: "failed")),
            .failed
        )
    }

    func testReviewAfterSuccess() {
        XCTAssertEqual(
            PetCodexMotion.map(.init(presence: .live, status: .idle, lastOutcome: "success")),
            .review
        )
    }

    func testApprovalIsWaving() {
        XCTAssertEqual(
            PetCodexMotion.map(.init(presence: .live, justApproved: true)),
            .waving
        )
    }

    func testCollapseIsFailedAndOutranksApproval() {
        let m = PetCodexMotion.map(.init(
            presence: .live, status: .active,
            justApproved: true, entropyCollapse: true
        ))
        XCTAssertEqual(m, .failed)
    }

    func testObservedBusyNeverClaimsWork() {
        let m = PetCodexMotion.map(.init(presence: .observed, status: .active))
        XCTAssertEqual(m, .idle)
        XCTAssertFalse(m.claimsWork)
    }

    /// Flip one input → motion label changes (responsiveness).
    func testFlipStatusChangesMotion() {
        let busy = PetCodexMotion.map(.init(presence: .live, status: .active))
        let wait = PetCodexMotion.map(.init(presence: .live, status: .blocked))
        XCTAssertEqual(busy, .running)
        XCTAssertEqual(wait, .waiting)
        XCTAssertNotEqual(busy, wait)
    }

    func testCompanionStateCarriesCodexMotion() {
        let state = CompanionState(
            agent: snapshot(status: .active, presence: .live, secondsAgo: 1)
        )
        XCTAssertEqual(state.codexMotion, .running)
        let idle = CompanionState(
            agent: snapshot(status: .idle, presence: .observed, secondsAgo: 2)
        )
        XCTAssertEqual(idle.codexMotion, .idle)
    }

    func testMoodBridgeAlertToRunning() {
        XCTAssertEqual(PetCodexMotion.from(mood: .alert), .running)
        XCTAssertEqual(PetCodexMotion.from(mood: .wary), .failed)
        XCTAssertEqual(PetCodexMotion.from(mood: .happy), .waving)
    }

    /// T2 — shared golden with hub/tests/fixtures/pet_codex_motion_matrix.json.
    /// Fail closed if the file is missing or any expected label drifts.
    func testMotionMatrixGoldenMatchesSwiftMap() throws {
        let url = try Self.petCodexMotionGoldenURL()
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let cases = root?["cases"] as? [[String: Any]], !cases.isEmpty else {
            return XCTFail("golden has no cases: \(url.path)")
        }

        var mismatches: [String] = []
        for caseObj in cases {
            let caseId = caseObj["id"] as? String ?? "<missing-id>"
            guard let signalsRaw = caseObj["signals"] as? [String: Any] else {
                mismatches.append("\(caseId): missing signals")
                continue
            }
            guard let expectedRaw = caseObj["expected"] as? String,
                  let expected = PetCodexMotion(rawValue: expectedRaw) else {
                mismatches.append("\(caseId): bad expected \(caseObj["expected"] ?? "nil")")
                continue
            }
            let signals = try Self.signals(fromGolden: signalsRaw, caseId: caseId)
            let got = PetCodexMotion.map(signals)
            if got != expected {
                mismatches.append("\(caseId): got \(got.rawValue) expected \(expected.rawValue)")
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "Swift PetCodexMotion.map drifted from golden matrix:\n" + mismatches.joined(separator: "\n")
        )
    }

    private static func petCodexMotionGoldenURL() throws -> URL {
        // Pill/Tests/PillCoreTests → repo root → hub/tests/fixtures/...
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // PillCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Pill
            .deletingLastPathComponent() // repo
        let url = repoRoot
            .appendingPathComponent("hub/tests/fixtures/pet_codex_motion_matrix.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "PetCodexMotionTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "pet codex motion golden missing (fail closed): \(url.path)",
                ]
            )
        }
        return url
    }

    private static func signals(
        fromGolden raw: [String: Any],
        caseId: String
    ) throws -> PetCodexMotion.Signals {
        let presenceRaw = (raw["presence"] as? String ?? "observed").lowercased()
        guard let presence = AgentPresence(rawValue: presenceRaw) else {
            throw NSError(
                domain: "PetCodexMotionTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(caseId): unknown presence \(presenceRaw)"]
            )
        }
        let statusRaw = (raw["status"] as? String ?? "idle")
        let status: AgentRunStatus
        switch statusRaw.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "active": status = .active
        case "mid_task": status = .midTask
        case "idle": status = .idle
        case "blocked": status = .blocked
        case "unknown": status = .unknown
        default:
            throw NSError(
                domain: "PetCodexMotionTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(caseId): unknown status \(statusRaw)"]
            )
        }
        let lastOutcome: String?
        if raw["last_outcome"] is NSNull || raw["last_outcome"] == nil {
            lastOutcome = nil
        } else if let s = raw["last_outcome"] as? String {
            lastOutcome = s
        } else {
            throw NSError(
                domain: "PetCodexMotionTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(caseId): bad last_outcome"]
            )
        }
        return PetCodexMotion.Signals(
            presence: presence,
            status: status,
            hasPendingAsk: raw["has_pending_ask"] as? Bool ?? false,
            lastOutcome: lastOutcome,
            justApproved: raw["just_approved"] as? Bool ?? false,
            entropyCollapse: raw["entropy_collapse"] as? Bool ?? false,
            celebrateAsJump: raw["celebrate_as_jump"] as? Bool ?? false
        )
    }

}

// MARK: - Atlas frame selection

final class PetAtlasFrameTests: XCTestCase {

    func testGridMatchesCodexV2() {
        XCTAssertEqual(PetAtlasGrid.columns, 8)
        XCTAssertEqual(PetAtlasGrid.extendedRows, 11)
        XCTAssertEqual(PetAtlasGrid.cellWidth, 192)
        XCTAssertEqual(PetAtlasGrid.cellHeight, 208)
        XCTAssertEqual(PetAtlasGrid.atlasWidth, 1536)
        XCTAssertEqual(PetAtlasGrid.extendedHeight, 2288)
    }

    func testCoreMotionsLandInCorrectRows() {
        let expected: [String: Int] = [
            "idle": 0, "running": 7, "waiting": 6, "failed": 5, "review": 8,
        ]
        for (motion, row) in expected {
            let fr = PetAtlasFrame.select(motion: motion, tSeconds: 0)
            XCTAssertEqual(fr.row, row, motion)
            XCTAssertGreaterThan(fr.framesInRow, 0)
            XCTAssertTrue((0 ..< fr.framesInRow).contains(fr.col))
            XCTAssertEqual(fr.width, 192)
            XCTAssertEqual(fr.height, 208)
            XCTAssertEqual(fr.x, fr.col * 192)
            XCTAssertEqual(fr.y, row * 208)
        }
    }

    func testMultiFrameAdvancesWithTime() {
        let f0 = PetAtlasFrame.select(motion: "idle", tSeconds: 0, fps: 8)
        let f1 = PetAtlasFrame.select(motion: "idle", tSeconds: 0.2, fps: 8)
        XCTAssertEqual(f0.frameIndex, 0)
        XCTAssertEqual(f1.frameIndex, 1)
        XCTAssertTrue(PetAtlasFrame.advances(motion: "running", from: 0, to: 1, fps: 8))
        XCTAssertTrue(PetAtlasFrame.advances(motion: "waiting", from: 0, to: 1, fps: 8))
    }

    func testUnknownFallsBackToIdle() {
        let fr = PetAtlasFrame.select(motion: "not-a-motion", tSeconds: 0)
        XCTAssertEqual(fr.motion, "idle")
        XCTAssertEqual(fr.row, 0)
    }
}

// MARK: - Package resolve + procedural fallback

final class PetPackageResolverTests: XCTestCase {

    func testMissingPackageUsesProcedural() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let a = PetPackageResolver.resolve(petId: "does-not-exist", roots: [root])
        let b = PetPackageResolver.resolve(petId: "does-not-exist", roots: [root])
        XCTAssertTrue(a.useProcedural)
        XCTAssertTrue(b.useProcedural)
        XCTAssertFalse(a.isV2)
        XCTAssertEqual(a.spriteVersion, 0)
    }

    func testResolvesV2FixturePackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-pkg-\(UUID().uuidString)")
        let pkgDir = root.appendingPathComponent("fixture-pet")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta: [String: Any] = [
            "id": "fixture-pet",
            "displayName": "Fixture Pet",
            "description": "test",
            "spriteVersionNumber": 2,
            "spritesheetPath": "spritesheet.webp",
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        try metaData.write(to: pkgDir.appendingPathComponent("pet.json"))
        try Data("RIFF....WEBP".utf8).write(to: pkgDir.appendingPathComponent("spritesheet.webp"))

        let result = PetPackageResolver.resolve(petId: "fixture-pet", roots: [root], requireV2: true)
        XCTAssertFalse(result.useProcedural)
        XCTAssertTrue(result.isV2)
        XCTAssertEqual(result.spriteVersion, 2)
        XCTAssertEqual(result.displayName, "Fixture Pet")
        XCTAssertNotNil(result.spritesheetURL)

        let again = PetPackageResolver.resolve(petId: "fixture-pet", roots: [root], requireV2: true)
        XCTAssertEqual(again.spritesheetURL, result.spritesheetURL)
    }

    /// B1: pet.json without spriteVersionNumber but with a sheet is still v2 / atlas-eligible.
    func testMissingSpriteVersionInferredAsV2WhenSheetPresent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-pkg-\(UUID().uuidString)")
        let pkgDir = root.appendingPathComponent("oc-an-like")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta: [String: Any] = [
            "id": "oc-an-like",
            "displayName": "OC An",
            // no spriteVersionNumber — live oc-an / stitch packages
            "spritesheetPath": "spritesheet.webp",
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: pkgDir.appendingPathComponent("pet.json"))
        try Data("RIFF....WEBP".utf8)
            .write(to: pkgDir.appendingPathComponent("spritesheet.webp"))

        let pure = PetPackageResolver.inferredSpriteVersion(declared: nil, sheetPresent: true)
        XCTAssertEqual(pure.version, 2)
        XCTAssertNotNil(pure.note)

        let result = PetPackageResolver.resolve(
            petId: "oc-an-like", roots: [root], requireV2: true
        )
        XCTAssertFalse(result.useProcedural, "must not fall to procedural when sheet exists")
        XCTAssertTrue(result.isV2)
        XCTAssertEqual(result.spriteVersion, 2)
        XCTAssertTrue(
            result.notes.contains(where: { $0.contains("inferred 2") }),
            "notes should record inference: \(result.notes)"
        )

        // Explicit v1 still fails requireV2.
        let v1 = PetPackageResolver.inferredSpriteVersion(declared: 1, sheetPresent: true)
        XCTAssertEqual(v1.version, 1)
        XCTAssertFalse(v1.version >= 2)
    }

    func testMemoryRootIsNotASpritesheetStore() {
        let mem = PetPackageResolver.agentMemoryRoot()
        XCTAssertTrue(mem.path.contains("pets"))
        // Default roots must not equal the memory root path.
        let roots = PetPackageResolver.defaultRoots()
        XCTAssertFalse(roots.contains(where: { $0.standardizedFileURL == mem.standardizedFileURL }))
    }

    func testDrawModeProceduralWithoutPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mode = CompanionDrawMode.resolve(petId: "none", motion: .running, roots: [root])
        XCTAssertEqual(mode, .procedural)
        XCTAssertFalse(mode.usesPackage)
    }

    /// Placeholder / unloadable sheet must not claim atlas mode (no blank UI).
    func testUnloadableSheetFallsBackToProcedural() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-bad-\(UUID().uuidString)")
        let pkgDir = root.appendingPathComponent("bad-pet")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta: [String: Any] = [
            "id": "bad-pet",
            "displayName": "Bad",
            "spriteVersionNumber": 2,
            "spritesheetPath": "spritesheet.webp",
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: pkgDir.appendingPathComponent("pet.json"))
        // Not a real image — NSImage load fails.
        try Data("not-a-real-image".utf8)
            .write(to: pkgDir.appendingPathComponent("spritesheet.webp"))

        let mode = CompanionDrawMode.resolve(petId: "bad-pet", motion: .idle, roots: [root])
        XCTAssertEqual(mode, .procedural, "unloadable sheet must not use atlas mode")

        let pkg = PetPackageResolver.resolve(petId: "bad-pet", roots: [root], requireV2: true)
        // Metadata may resolve, but renderer must refuse to draw.
        if !pkg.useProcedural {
            XCTAssertFalse(PetAtlasRenderer.isDrawable(package: pkg))
            XCTAssertNil(PetAtlasRenderer.frameImage(package: pkg, motion: .idle, tSeconds: 0))
        }
    }

    /// T1: live `~/.codex/pets/shannon/spritesheet.webp` through PetAtlasRenderer
    /// (geometry/crop), not only package metadata resolve. Skip when missing so
    /// CI without pets stays green.
    func testLiveShannonSpritesheetDrawableIfPresent() throws {
        #if canImport(AppKit)
        guard #available(macOS 14.0, *) else {
            throw XCTSkip("PetAtlasRenderer requires macOS 14+")
        }
        let sheet = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets/shannon/spritesheet.webp")
        guard FileManager.default.fileExists(atPath: sheet.path) else {
            throw XCTSkip("live ~/.codex/pets/shannon/spritesheet.webp not present")
        }

        let pkg = PetPackageResolver.resolve(petId: "shannon", requireV2: true)
        XCTAssertFalse(pkg.useProcedural, "live shannon package should resolve as non-procedural")
        XCTAssertNotNil(pkg.spritesheetURL, "live shannon must expose spritesheetURL")
        XCTAssertTrue(
            PetAtlasRenderer.isDrawable(package: pkg),
            "live shannon webp must be drawable via PetAtlasRenderer"
        )
        for motion in [PetCodexMotion.idle, .running] {
            let crop = PetAtlasRenderer.frameImage(
                package: pkg, motion: motion, tSeconds: 0
            )
            XCTAssertNotNil(crop, "frameImage must crop non-nil for \(motion)")
            if let crop {
                XCTAssertGreaterThan(crop.width, 0)
                XCTAssertGreaterThan(crop.height, 0)
            }
        }
        #else
        throw XCTSkip("AppKit unavailable")
        #endif
    }
}

// MARK: - Roster pending ask / outcome → Codex motion

final class CompanionRosterCodexMotionTests: XCTestCase {

    func testPendingAskDrivesWaitingMotion() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snapshot(id: "science", status: .active, presence: .live, secondsAgo: 1, now: now),
            snapshot(id: "codex", status: .idle, presence: .live, secondsAgo: 2, now: now),
        ], scannedAt: now)
        let asks = [
            GateDBReader.PendingAsk(
                interactionId: "ask-1",
                agentId: "science",
                prompt: "Approve Softβ?",
                createdAt: now
            ),
        ]
        let roster = CompanionRoster.build(
            from: summary, now: now, pendingAsks: asks
        )
        let byID = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, $0) })
        XCTAssertEqual(byID["science"]?.codexMotion, .waiting,
                       "open ask must map to waiting")
        XCTAssertEqual(byID["codex"]?.codexMotion, .idle)
    }

    func testActivityCompletionDrivesReviewMotion() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snapshot(id: "science", status: .idle, presence: .live, secondsAgo: 1, now: now),
        ], scannedAt: now)
        let activity = [
            GateDBReader.ActivityEvent(
                id: 1,
                agentId: "science",
                at: now.addingTimeInterval(-5),
                type: "task_complete",
                label: "all tests passed",
                output: "ready for review"
            ),
        ]
        let roster = CompanionRoster.build(
            from: summary, now: now, activity: activity
        )
        XCTAssertEqual(roster.first?.codexMotion, .review)
    }

    func testActivityFailureDrivesFailedMotion() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snapshot(id: "science", status: .idle, presence: .live, secondsAgo: 1, now: now),
        ], scannedAt: now)
        let activity = [
            GateDBReader.ActivityEvent(
                id: 2,
                agentId: "science",
                at: now.addingTimeInterval(-2),
                type: "error",
                label: "build failed",
                output: "exit 1"
            ),
        ]
        let roster = CompanionRoster.build(
            from: summary, now: now, activity: activity
        )
        XCTAssertEqual(roster.first?.codexMotion, .failed)
    }

    func testExplicitOutcomeWinsOverActivity() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            snapshot(id: "science", status: .idle, presence: .live, secondsAgo: 1, now: now),
        ], scannedAt: now)
        let activity = [
            GateDBReader.ActivityEvent(
                id: 3, agentId: "science", at: now,
                type: "task_complete", label: "done", output: ""
            ),
        ]
        let roster = CompanionRoster.build(
            from: summary, now: now,
            lastOutcomes: ["science": "failed"],
            activity: activity
        )
        XCTAssertEqual(roster.first?.codexMotion, .failed)
    }

    func testOutcomeHintMergeIsPure() {
        let now = Date()
        let ev = GateDBReader.ActivityEvent(
            id: 9, agentId: "codex", at: now,
            type: "task_complete", label: "done", output: ""
        )
        let merged = CompanionRoster.mergeOutcomes(
            explicit: ["science": "failed"],
            activity: [ev],
            now: now
        )
        XCTAssertEqual(merged["science"], "failed")
        XCTAssertEqual(merged["codex"], "review")
    }
}
