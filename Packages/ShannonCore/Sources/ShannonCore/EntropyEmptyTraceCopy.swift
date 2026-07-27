import Foundation

// MARK: - Entropy empty-trace chrome (pad chart + detail)

/// Empty entropy series copy when fewer than two samples exist (UX-056).
///
/// Chart cards use density-short chrome; agent detail uses an explicit
/// “why empty” line. Both share one Core family so pad surfaces cannot
/// fork wording independently.
public enum EntropyEmptyTraceCopy: Sendable {

    /// Compact dashboard / multi-agent chart empty (StatusCardsView).
    public static let short = "Collecting samples…"

    /// Agent detail empty-trace explanation (needs ≥2 readings to plot).
    public static let detail = "Collecting samples — the trace needs two readings."
}
