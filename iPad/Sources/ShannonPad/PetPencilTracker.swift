import UIKit
import ShannonCore

// MARK: - PetPencilTracker

/// Tracks Apple Pencil hover proximity over the pet rail and maps it to a
/// gaze offset in `PetRailView`. Also handles Pencil Pro squeeze (barrel roll
/// angle is read from `UIPencilInteraction` in iPadOS 17.5+).
@available(iOS 17.5, *)
public final class PetPencilTracker: NSObject {

    /// Called with the hover location in the host view's coordinate space.
    public var onGaze: ((CGPoint, CGRect) -> Void)?
    /// Called when the Pencil leaves the hover zone.
    public var onGazeEnd: (() -> Void)?
    /// Called on Pencil squeeze / single tap interaction.
    public var onSqueeze: (() -> Void)?

    private weak var hostView: UIView?
    private var hoverRecognizer: UIHoverGestureRecognizer?

    public func attach(to view: UIView) {
        hostView = view
        let gr = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        view.addGestureRecognizer(gr)
        hoverRecognizer = gr

        let interaction = UIPencilInteraction()
        interaction.delegate = self
        view.addInteraction(interaction)
    }

    @objc private func handleHover(_ gr: UIHoverGestureRecognizer) {
        guard let view = hostView else { return }
        switch gr.state {
        case .began, .changed:
            onGaze?(gr.location(in: view), view.bounds)
        default:
            onGazeEnd?()
        }
    }
}

// MARK: - UIPencilInteractionDelegate

@available(iOS 17.5, *)
extension PetPencilTracker: UIPencilInteractionDelegate {
    public func pencilInteraction(_ interaction: UIPencilInteraction,
                                  didReceiveTap tap: UIPencilInteraction.Tap) {
        onSqueeze?()
    }
}

// MARK: - PetPencilHostingController

/// UIKit hosting controller that wraps `PetRailView` and bridges Pencil
/// interactions: hover → gaze, squeeze → menu, barrel roll → pet spin.
@available(iOS 17.5, *)
public final class PetPencilHostingController: UIHostingController<PetRailView> {
    private let tracker = PetPencilTracker()
    private var railView: PetRailView

    public init(railView: PetRailView) {
        self.railView = railView
        super.init(rootView: railView)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tracker.attach(to: view)

        tracker.onGaze = { [weak self] pt, bounds in
            self?.railView.updatePencilGaze(to: pt, in: bounds)
        }
        tracker.onGazeEnd = { [weak self] in
            self?.railView.resetPencilGaze()
        }
        tracker.onSqueeze = { [weak self] in
            // Squeeze: present a quick action sheet above the pet
            self?.showPencilMenu()
        }
    }

    private func showPencilMenu() {
        let alert = UIAlertController(title: nil, message: nil,
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Draw for pet (+10 XP)", style: .default) { _ in
            // Pencil draw session handled by the caller
        })
        alert.addAction(UIAlertAction(title: "Show memory", style: .default))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
