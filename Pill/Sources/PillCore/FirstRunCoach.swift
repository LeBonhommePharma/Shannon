import Foundation

/// First-run tips for the menu-bar popover. Pure model over injectable
/// `UserDefaults` so tests never touch the real suite.
public enum FirstRunCoach {
    public static let defaultsKey = "shannon.pill.firstRunDone"

    /// Ordered coach steps shown once while the agent roster is empty.
    public enum Step: String, Sendable, CaseIterable, Equatable {
        case watch
        case attach
        case permissions
    }

    public static var steps: [Step] { Step.allCases }

    /// Short copy for each step.
    public static func tip(for step: Step) -> String {
        switch step {
        case .watch:
            // Teaches amber vs red without inventing a third alarm color.
            return "Watch the notch: amber = approval needed, red = entropy collapse. \(PillChromePolicy.statusLegend)"
        case .attach:
            return "Press ⌘D in Terminal, Claude, or a browser to attach that session as an agent."
        case .permissions:
            return "Allow notifications so pending approvals reach you when the pill is tucked away."
        }
    }

    /// True until the user dismisses the coach (or tests call `markDone`).
    public static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        // Shared key with ShannonPreferences.firstRunDone.
        !ShannonPreferences.firstRunDone(defaults: defaults)
    }

    /// Persist that first-run tips have been seen.
    public static func markDone(defaults: UserDefaults = .standard) {
        ShannonPreferences.setFirstRunDone(true, defaults: defaults)
    }
}
