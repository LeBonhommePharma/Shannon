/// HoverCursorView.swift
/// UIPointerInteraction + UIHoverGestureRecognizer extensions for agent cards.
/// When the Pencil Pro hovers over an agent card the card lifts and shows
/// contextual actions (Annotate · Expand · Pin) without requiring a tap.
import SwiftUI
import UIKit
import ShannonTheme

// MARK: - Hover-reveal card overlay modifier

/// Wraps an agent card view with hover detection and an action overlay.
struct PencilHoverModifier: ViewModifier {

    var onAnnotate: () -> Void
    var onExpand:   () -> Void
    var onPin:      () -> Void

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isHovering {
                    hoverOverlay
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .background(
                HoverDetectorView(isHovering: $isHovering)
                    .allowsHitTesting(false)
            )
            .animation(.shannonSnap, value: isHovering)
    }

    private var hoverOverlay: some View {
        VStack(spacing: ShannonSpacing.sm) {
            Spacer()
            HStack(spacing: ShannonSpacing.sm) {
                HoverActionButton(
                    title: "Annotate",
                    symbol: "pencil.tip",
                    action: onAnnotate
                )
                HoverActionButton(
                    title: "Expand",
                    symbol: "arrow.up.left.and.arrow.down.right",
                    action: onExpand
                )
                HoverActionButton(
                    title: "Pin",
                    symbol: "pin",
                    action: onPin
                )
            }
            .padding(ShannonSpacing.sm)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ShannonRadius.md))
        }
        .padding(ShannonSpacing.xs)
    }
}

private struct HoverActionButton: View {
    var title:  String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .shannonText(.shannonCaption)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(Color.shannonAccent)
    }
}

// MARK: - UIViewRepresentable hover detector

/// A zero-size UIView that installs a UIHoverGestureRecognizer and feeds
/// hover state back to SwiftUI via a binding.
private struct HoverDetectorView: UIViewRepresentable {

    @Binding var isHovering: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let hover = UIHoverGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHover(_:))
        )
        view.addGestureRecognizer(hover)

        // UIPointerInteraction: show `.lift` effect when hovering the card.
        let pointer = UIPointerInteraction(delegate: context.coordinator)
        view.addInteraction(pointer)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(binding: $isHovering) }

    // MARK: Coordinator

    final class Coordinator: NSObject,
        UIGestureRecognizerDelegate,
        UIPointerInteractionDelegate
    {
        private var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }

        @objc func handleHover(_ r: UIHoverGestureRecognizer) {
            switch r.state {
            case .began, .changed:
                if !binding.wrappedValue { binding.wrappedValue = true }
            case .ended, .cancelled:
                binding.wrappedValue = false
            default: break
            }
        }

        func pointerInteraction(
            _ interaction: UIPointerInteraction,
            styleFor region: UIPointerRegion
        ) -> UIPointerStyle? {
            // UIPointerStyle.lift(_:) was removed in iOS 26 SDK.
            // Hover state is already driven by UIHoverGestureRecognizer;
            // return nil for default system pointer appearance.
            return nil
        }
    }
}

// MARK: - View extension

extension View {
    /// Add Pencil hover detection with contextual action overlay to an agent card.
    func pencilHoverActions(
        onAnnotate: @escaping () -> Void,
        onExpand:   @escaping () -> Void,
        onPin:      @escaping () -> Void
    ) -> some View {
        modifier(PencilHoverModifier(
            onAnnotate: onAnnotate,
            onExpand:   onExpand,
            onPin:      onPin
        ))
    }
}
