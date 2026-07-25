import Foundation

/// Decides the `createdAt` each mirrored ask is published to iCloud with.
///
/// `PendingConfirmation.expiresAt` is derived from `createdAt`, so this value
/// is what decides when an unanswered ask ages out on the phone and the watch.
/// The gate already records the truth (`agent_interactions.created_at_ns`,
/// surfaced as `GateDBReader.PendingAsk.createdAt`); seeding from the pill's own
/// clock instead restarts the lifetime from zero on every pill launch, so an ask
/// the gate created hours ago can never expire.
///
/// The local first-seen cache is kept only as a fallback for rows that genuinely
/// carry no gate timestamp (`createdAt == .distantPast`, which is what
/// `GateDBReader` writes when `created_at_ns` is missing or zero). Keeping *some*
/// stable value matters independently of expiry: `createdAt` is part of
/// `cloudFields`, so recomputing it every pass makes an unchanged ask serialise
/// differently each tick, defeating `ShannonPublisher`'s unchanged-record
/// suppression and re-notifying every device forever.
public struct ConfirmationCreatedAtResolver {
    /// Hard ceiling on the fallback cache, independent of pruning, so a
    /// pathological gate cannot grow this map without bound between prunes.
    public static let maxTracked = 512

    private var firstSeen: [String: Date] = [:]

    public init() {}

    /// Number of asks currently holding a fallback timestamp. Test seam.
    public var trackedCount: Int { firstSeen.count }

    /// Stable creation date for `ask`, preferring the gate's own timestamp.
    ///
    /// A gate-stamped ask needs no bookkeeping at all: `created_at_ns` is
    /// already stable across passes AND across pill launches, which the local
    /// cache never was. Only the unstamped rows land in the map, so it holds
    /// strictly less than before.
    public mutating func createdAt(for ask: GateDBReader.PendingAsk, now: Date = Date()) -> Date {
        if ask.createdAt > .distantPast {
            // The gate already knows when the agent asked. Trust it, and make
            // sure no stale local guess for this id survives to override it.
            firstSeen[ask.interactionId] = nil
            return ask.createdAt
        }
        let seen = firstSeen[ask.interactionId] ?? now
        firstSeen[ask.interactionId] = seen
        enforceCap(now: now)
        return seen
    }

    /// Forget bookkeeping for asks the gate has cleared, so the map cannot grow
    /// without bound and a re-used interaction id starts fresh.
    public mutating func prune(keeping liveIDs: Set<String>) {
        firstSeen = firstSeen.filter { liveIDs.contains($0.key) }
    }

    /// Drop the oldest fallbacks once the cache passes its ceiling. Only reached
    /// if a caller stops pruning; expiry of a dropped row is then re-seeded from
    /// the current clock, which is no worse than the fallback already is.
    private mutating func enforceCap(now: Date) {
        guard firstSeen.count > Self.maxTracked else { return }
        let survivors = firstSeen
            .sorted { $0.value > $1.value }
            .prefix(Self.maxTracked)
        firstSeen = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }
}
