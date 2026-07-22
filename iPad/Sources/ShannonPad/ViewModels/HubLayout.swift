import SwiftUI

/// How much canvas the hub actually has right now.
///
/// Size class alone is not enough on iPad: a Stage Manager window can be
/// `.regular` at 700pt, where a three-column split view would crush every
/// column below its useful width. The breakpoints below are the four widths
/// the layout is tuned against — Slide Over (320), half screen (768), full
/// portrait (1024), full landscape (1366).
enum HubLayout: Equatable {
    /// Slide Over, or an iPhone-width Stage Manager window. Single column.
    case compact
    /// Half screen or portrait. Sidebar + detail.
    case twoColumn
    /// Landscape or a wide Stage Manager window. Rail + detail + right panel.
    case threeColumn

    static func resolve(width: CGFloat, sizeClass: UserInterfaceSizeClass?) -> HubLayout {
        if sizeClass == .compact || width < 600 { return .compact }
        if width >= 1100 { return .threeColumn }
        return .twoColumn
    }

    /// The left column. Narrower in three-column mode, where it degrades to a
    /// rail and the agent detail gets the space instead.
    var sidebarWidth: CGFloat {
        self == .threeColumn ? 240 : 280
    }

    static let rightPanelWidth: CGFloat = 320

    /// Dashboard columns. 11" landscape lands on 3, 13" on 4.
    static func gridColumnCount(width: CGFloat) -> Int {
        switch width {
        case ..<600:  return 1
        case ..<900:  return 2
        case ..<1250: return 3
        default:      return 4
        }
    }
}

/// Reads the width of whatever it is placed behind. Used once, at the root, so
/// the whole hierarchy can branch on one measured value rather than each view
/// running its own `GeometryReader`.
struct HubWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1024
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
