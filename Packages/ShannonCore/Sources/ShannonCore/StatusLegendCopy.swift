import Foundation

// MARK: - Multi-OS status colour legend (amber ask · red collapse)

/// Shared operator legend for Shannon status chrome on **every** OS.
///
/// **UX-010:** Mac notch / menu bar teach “amber = approval, red = collapse”
/// via `PillChromePolicy.statusLegend`. Phone and pad must use the same
/// mental model — one canonical string here so dual-OS wording cannot drift.
///
/// Semantics (do not invert):
/// - **Amber** → human approval / ask needed
/// - **Red** → measured entropy collapse
public enum StatusLegendCopy: Sendable {

    /// Short one-line legend (empty states, first-run, help footer).
    ///
    /// Matches historical Mac `PillChromePolicy.statusLegend` wording.
    public static let line =
        "Amber = approval needed · Red = entropy collapse"

    /// Accessibility label — same content; reserved if UI ever shortens the visual line.
    public static let accessibilityLabel = line
}
