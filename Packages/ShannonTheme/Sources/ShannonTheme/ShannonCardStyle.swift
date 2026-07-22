import SwiftUI

/// The companion-app card. Same token vocabulary as the Mac pill, different
/// geometry per platform (see `ShannonLayout`).
public struct ShannonCardStyle: ViewModifier {
    public var isHighlighted: Bool

    public init(isHighlighted: Bool = false) {
        self.isHighlighted = isHighlighted
    }

    #if os(watchOS)
    private var radius: CGFloat { ShannonLayout.WatchCard.radius }
    private var padding: CGFloat { ShannonLayout.WatchCard.padding }
    private var fill: Color { .shannonBackground }
    #else
    private var radius: CGFloat { ShannonLayout.IOSCard.radius }
    private var padding: CGFloat { ShannonLayout.IOSCard.padding }
    private var fill: Color { .shannonSurface }
    #endif

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isHighlighted ? Color.shannonAccentSubtle : fill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        isHighlighted ? Color.shannonAccent.opacity(0.35) : .clear,
                        lineWidth: 1
                    )
            }
            .animation(.shannonEase, value: isHighlighted)
    }
}

public extension View {
    /// Card chrome for the iPhone and Watch companions. On watchOS this picks up
    /// the tighter 12pt radius / 8pt padding automatically.
    func shannonCard(isHighlighted: Bool = false) -> some View {
        modifier(ShannonCardStyle(isHighlighted: isHighlighted))
    }

    /// Standard page inset for iOS scroll content (16pt each side).
    func shannonPageInset() -> some View {
        #if os(watchOS)
        return self
        #else
        return self.padding(.horizontal, ShannonLayout.IOSCard.pageMargin)
        #endif
    }
}

/// A small status dot driven by the semantic state colours — the one piece of
/// shared chrome that appears on all three platforms.
public struct ShannonStatusDot: View {
    public enum State: Sendable {
        case success, warning, error, neutral, active

        var color: Color {
            switch self {
            case .success: return .shannonSuccess
            case .warning: return .shannonWarning
            case .error: return .shannonError
            case .neutral: return .shannonNeutral
            case .active: return .shannonAccent
            }
        }
    }

    public var state: State
    public var diameter: CGFloat

    public init(state: State, diameter: CGFloat = 6) {
        self.state = state
        self.diameter = diameter
    }

    public var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: diameter, height: diameter)
            .animation(.shannonSnap, value: state.color)
    }
}
