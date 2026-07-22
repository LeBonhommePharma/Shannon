/// RadialMenuView.swift
/// Pencil Pro squeeze quick-action overlay.
/// Shown at the tip position; dismissed on second squeeze or tap-outside.
/// Animates with .shannonSnap spring from ShannonTheme.
import SwiftUI
import ShannonTheme

#if canImport(PencilKit)

struct RadialMenuView: View {

    let origin: CGPoint               // tip position in screen coords
    let onAction: (PencilQuickAction) -> Void
    let onDismiss: () -> Void

    @State private var appeared = false

    // Lay items out on a circle of this radius.
    private let orbitRadius: CGFloat = 72
    private let itemSize:    CGFloat = 52

    private let actions = PencilQuickAction.allCases

    var body: some View {
        ZStack {
            // Tap-outside dimmer
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            // Action buttons arranged radially
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                let angle = itemAngle(for: index, total: actions.count)
                let offset = CGSize(
                    width:  cos(angle) * orbitRadius,
                    height: sin(angle) * orbitRadius
                )

                Button {
                    onAction(action)
                    onDismiss()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 18, weight: .medium))
                        Text(action.rawValue)
                            .shannonText(.shannonCaption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: itemSize, height: itemSize)
                    .background(Color.shannonSurfaceElevated)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                }
                .tint(Color.shannonAccent)
                .offset(offset)
                .scaleEffect(appeared ? 1 : 0.3)
                .opacity(appeared ? 1 : 0)
                .animation(
                    .shannonSnap.delay(Double(index) * 0.03),
                    value: appeared
                )
            }

            // Centre dismiss pip
            Circle()
                .fill(Color.shannonAccent)
                .frame(width: 14, height: 14)
                .opacity(appeared ? 1 : 0)
                .animation(.shannonSnap, value: appeared)
        }
        .position(x: origin.x, y: origin.y)
        .onAppear { appeared = true }
    }

    // MARK: - Helpers

    /// Distribute items evenly starting at the top (−π/2).
    private func itemAngle(for index: Int, total: Int) -> CGFloat {
        let step = (2 * CGFloat.pi) / CGFloat(total)
        return -CGFloat.pi / 2 + step * CGFloat(index)
    }
}

// MARK: - Presentation wrapper

/// Manages the radial menu lifecycle on top of any view.
struct RadialMenuHost<Content: View>: View {

    var content: Content
    @State private var menuOrigin: CGPoint?
    @State private var onActionCallback: ((PencilQuickAction) -> Void)?

    var body: some View {
        ZStack {
            content

            if let origin = menuOrigin {
                RadialMenuView(
                    origin: origin,
                    onAction: { action in
                        onActionCallback?(action)
                        menuOrigin = nil
                    },
                    onDismiss: { menuOrigin = nil }
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .onPreferenceChange(RadialMenuTriggerKey.self) { trigger in
            guard let t = trigger else { return }
            menuOrigin        = t.origin
            onActionCallback  = t.onAction
        }
    }
}

// MARK: - PreferenceKey for triggering

struct RadialMenuTrigger: Equatable {
    var origin:   CGPoint
    var onAction: (PencilQuickAction) -> Void

    // Closures aren't Equatable; compare by origin only (menu fires once per tip position).
    static func == (lhs: RadialMenuTrigger, rhs: RadialMenuTrigger) -> Bool {
        lhs.origin == rhs.origin
    }
}

struct RadialMenuTriggerKey: PreferenceKey {
    static var defaultValue: RadialMenuTrigger? { nil }
    static func reduce(value: inout RadialMenuTrigger?, nextValue: () -> RadialMenuTrigger?) {
        value = nextValue() ?? value
    }
}

#endif // canImport(PencilKit)
