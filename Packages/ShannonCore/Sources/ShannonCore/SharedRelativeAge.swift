import Foundation

// MARK: - Shared relative-age buckets (Mac · widget · companions)

/// Relative age strings shared across OS surfaces.
///
/// **UX-008 / Mac parity:** Mac Pill uses `AgentActivitySnapshot.signatureAge`
/// (15 s buckets under a minute) so sub-minute second ticks do not thrash
/// layout or force a structural re-publish. Widget glance and other
/// companions must use the same buckets — fine-grained `"12s"` → `"13s"`
/// would make WidgetKit reload thrash and look like a flicker.
///
/// - `bucketed` — coarse ages for glance UI and identity/signatures
/// - `fine` — second-resolution ages when a live surface deliberately redraws
public enum SharedRelativeAge: Sendable {

    /// Sub-minute bucket width (seconds). Matches Mac `signatureAge`.
    public static let bucketSeconds: TimeInterval = 15

    /// Coarse age for **widget glance and thrash-safe signatures**.
    ///
    /// Semantics (Mac `AgentActivitySnapshot.signatureAge`):
    /// - distantPast → `"never"`
    /// - < 15 s → `"now"`
    /// - < 60 s → `"15s"` / `"30s"` / `"45s"`
    /// - < 1 h → `"Nm"`
    /// - < 1 d → `"Nh"`
    /// - else → `"Nd"`
    public static func bucketed(since date: Date, now: Date = Date()) -> String {
        guard date > .distantPast else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < bucketSeconds { return "now" }
        if s < 60 {
            let bucket = Int(s / bucketSeconds) * Int(bucketSeconds)
            return "\(bucket)s"
        }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    /// Fine-grained age for surfaces that redraw intentionally (not widgets).
    ///
    /// Matches Mac `AgentActivitySnapshot.age`:
    /// - distantPast → `"never"`
    /// - < 5 s → `"now"`
    /// - < 60 s → `"Ns"` (every second)
    /// - < 1 h → `"Nm"`
    /// - < 1 d → `"Nh"`
    /// - else → `"Nd"`
    public static func fine(since date: Date, now: Date = Date()) -> String {
        guard date > .distantPast else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < 5 { return "now" }
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    /// Freshest timestamp among snapshot agents and `capturedAt` — the glance
    /// age a widget shows for "how recent is this state?".
    public static func glanceReferenceDate(in snapshot: ShannonSnapshot) -> Date {
        var latest = snapshot.capturedAt
        for agent in snapshot.agents where agent.updatedAt > latest {
            latest = agent.updatedAt
        }
        for run in snapshot.docking where run.updatedAt > latest {
            latest = run.updatedAt
        }
        return latest
    }

    /// Bucketed age for a full companion snapshot (widget / watch glance).
    public static func glanceBucketed(
        in snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> String {
        bucketed(since: glanceReferenceDate(in: snapshot), now: now)
    }
}
