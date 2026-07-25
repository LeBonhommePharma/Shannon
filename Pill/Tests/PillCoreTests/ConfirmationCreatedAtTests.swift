import XCTest
import ShannonCore
@testable import PillCore

/// `PendingConfirmation.expiresAt` is derived from `createdAt`, so whichever
/// clock feeds `createdAt` decides when an unanswered ask ages out on the phone
/// and the watch. Seeding it from the pill's own `Date()` restarted the 15
/// minute lifetime on every pill launch, so an ask the gate created hours ago
/// could never expire — the gate's `created_at_ns` is the only source of truth.
final class ConfirmationCreatedAtTests: XCTestCase {

    private func ask(_ id: String, createdAt: Date = .distantPast) -> GateDBReader.PendingAsk {
        GateDBReader.PendingAsk(
            interactionId: id,
            agentId: "codex",
            prompt: "rm -rf build?",
            createdAt: createdAt
        )
    }

    // MARK: The gate's clock wins

    func testUsesGateTimestampRatherThanLocalClock() {
        let now = Date()
        let asked = now.addingTimeInterval(-20 * 60)
        var resolver = ConfirmationCreatedAtResolver()

        XCTAssertEqual(
            resolver.createdAt(for: ask("i-1", createdAt: asked), now: now).timeIntervalSince1970,
            asked.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    /// The user-visible consequence: an ask older than the 15 minute lifetime
    /// must publish as already expired instead of as brand new.
    func testOldAskPublishesAsExpired() {
        let now = Date()
        let asked = now.addingTimeInterval(-20 * 60)
        var resolver = ConfirmationCreatedAtResolver()

        let confirmation = PendingConfirmation(
            id: "i-1",
            question: "rm -rf build?",
            agentID: "codex",
            createdAt: resolver.createdAt(for: ask("i-1", createdAt: asked), now: now)
        )
        XCTAssertTrue(
            confirmation.isExpired(now: now),
            "an ask created \(-asked.timeIntervalSince(now) / 60) min ago is past the "
                + "\(PendingConfirmation.defaultLifetime / 60) min lifetime and must age out"
        )
    }

    /// Relaunching the pill must not reset the clock: a fresh resolver — which
    /// is what a new process gets — has to reach the same answer.
    func testRelaunchDoesNotRestartTheLifetime() {
        let launchOne = Date()
        let asked = launchOne.addingTimeInterval(-14 * 60)
        var first = ConfirmationCreatedAtResolver()
        let before = first.createdAt(for: ask("i-1", createdAt: asked), now: launchOne)

        // Pill quits, restarts two minutes later. The ask is now 16 min old.
        let launchTwo = launchOne.addingTimeInterval(2 * 60)
        var second = ConfirmationCreatedAtResolver()
        let after = second.createdAt(for: ask("i-1", createdAt: asked), now: launchTwo)

        XCTAssertEqual(before.timeIntervalSince1970, after.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(
            PendingConfirmation(id: "i-1", question: "q", createdAt: after).isExpired(now: launchTwo),
            "expiry must be measured from the gate's timestamp, not from this launch"
        )
    }

    // MARK: Stability and the local fallback

    /// Republishing an unchanged ask with a fresh timestamp defeats the
    /// publisher's unchanged-record suppression, so the value must be stable
    /// across passes whichever clock it came from.
    func testStableAcrossPassesForGateStampedAsk() {
        let now = Date()
        let asked = now.addingTimeInterval(-60)
        var resolver = ConfirmationCreatedAtResolver()

        let first = resolver.createdAt(for: ask("i-1", createdAt: asked), now: now)
        let second = resolver.createdAt(for: ask("i-1", createdAt: asked),
                                        now: now.addingTimeInterval(10))
        XCTAssertEqual(first, second)
    }

    /// `GateDBReader` writes `.distantPast` when `created_at_ns` is missing or
    /// zero. Those rows keep the local first-seen fallback — and it still has to
    /// be stable, or the record churns every tick.
    func testFallsBackToStableLocalFirstSeenWhenGateTimestampMissing() {
        let now = Date()
        var resolver = ConfirmationCreatedAtResolver()

        let first = resolver.createdAt(for: ask("i-1"), now: now)
        let second = resolver.createdAt(for: ask("i-1"), now: now.addingTimeInterval(30))
        XCTAssertEqual(first.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(first, second, "an unstamped ask still needs a stable createdAt")
        XCTAssertNotEqual(first, Date.distantPast)
    }

    // MARK: Bounded growth

    func testPruneDropsClearedAsks() {
        let now = Date()
        var resolver = ConfirmationCreatedAtResolver()
        for i in 0..<50 { _ = resolver.createdAt(for: ask("i-\(i)"), now: now) }
        XCTAssertEqual(resolver.trackedCount, 50)

        resolver.prune(keeping: ["i-3", "i-7"])
        XCTAssertEqual(resolver.trackedCount, 2)
    }

    /// A re-used interaction id must start fresh rather than inherit the
    /// timestamp of the ask that previously held it.
    func testReusedInteractionIDStartsFreshAfterPrune() {
        let now = Date()
        var resolver = ConfirmationCreatedAtResolver()
        let first = resolver.createdAt(for: ask("i-1"), now: now)
        resolver.prune(keeping: [])
        let later = now.addingTimeInterval(3600)
        XCTAssertEqual(
            resolver.createdAt(for: ask("i-1"), now: later).timeIntervalSince1970,
            later.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertNotEqual(first, later)
    }

    /// Belt and braces: even a caller that never prunes cannot grow the cache
    /// without bound.
    func testCacheIsCappedWithoutPruning() {
        let now = Date()
        var resolver = ConfirmationCreatedAtResolver()
        for i in 0..<(ConfirmationCreatedAtResolver.maxTracked + 200) {
            _ = resolver.createdAt(for: ask("i-\(i)"), now: now.addingTimeInterval(Double(i)))
        }
        XCTAssertLessThanOrEqual(resolver.trackedCount, ConfirmationCreatedAtResolver.maxTracked)
    }
}
