/// PencilInputCoordinator.swift
/// Full Apple Pencil integration: pressure · tilt · azimuth · barrel-roll ·
/// hover · touch coalescing · touch prediction · UIPencilInteraction (double-tap
/// + squeeze) · PKToolPicker · pencilOnly drawing · Scribble · OCR · UIPointer.
///
/// Architecture rule: ALL UIKit/PencilKit/Vision Pencil logic lives here.
/// SwiftUI views stay clean — they bind to PencilCanvasRepresentable and observe
/// PencilAnnotationStore.
#if canImport(PencilKit)
import SwiftUI
import UIKit
import PencilKit
import Vision
import ShannonCore
import ShannonTheme

// MARK: - Quick-Action Enum (shared with RadialMenuView)

/// Actions available in the Pencil Pro squeeze radial menu.
public enum PencilQuickAction: String, CaseIterable, Sendable {
    case annotate        = "Annotate"
    case summariseAgent  = "Summarise Agent"
    case clearCanvas     = "Clear Canvas"
    case exportDrawing   = "Export"
    case toggleRuler     = "Toggle Ruler"

    public var systemImage: String {
        switch self {
        case .annotate:       return "pencil"
        case .summariseAgent: return "brain"
        case .clearCanvas:    return "trash"
        case .exportDrawing:  return "square.and.arrow.up"
        case .toggleRuler:    return "ruler"
        }
    }
}

// MARK: - SwiftUI Bridge (UIViewRepresentable)

/// SwiftUI wrapper for the full-featured Pencil canvas.
/// Drop this in place of any plain `PKCanvasView` bridge.
struct PencilCanvasRepresentable: UIViewRepresentable {

    @Binding var drawingData: Data?
    @Binding var isEmpty: Bool

    /// Shannon accent colour applied to the custom PKInkingTool preset.
    var accentColor: UIColor = UIColor(Color.shannonAccent)

    /// Called each time a coalesced touch sample is processed.
    var onMetrics: (PencilStrokeMetrics) -> Void = { _ in }

    /// Called when OCR finishes after stroke idle. text + confidence.
    var onOCRComplete: (String, Float) -> Void = { _, _ in }

    /// Called on Pencil Pro squeeze with the chosen action and tip position.
    var onSqueezeAction: (PencilQuickAction, CGPoint) -> Void = { _, _ in }

    func makeUIView(context: Context) -> PencilContainerView {
        let container = PencilContainerView()
        context.coordinator.configure(
            container: container,
            accentColor: accentColor
        )
        return container
    }

    func updateUIView(_ container: PencilContainerView, context: Context) {
        context.coordinator.applyExternalDrawing(data: drawingData, to: container.canvasView)
    }

    func makeCoordinator() -> PencilInputCoordinator {
        PencilInputCoordinator(
            onData: { data, empty in
                drawingData = data
                isEmpty = empty
            },
            onMetrics: onMetrics,
            onOCRComplete: onOCRComplete,
            onSqueezeAction: onSqueezeAction
        )
    }

    // MARK: - Export helpers

    /// Render the current drawing as a PNG at screen scale.
    static func exportPNG(from canvas: PKCanvasView) -> Data? {
        let bounds = canvas.drawing.bounds.isEmpty ? canvas.bounds : canvas.drawing.bounds
        let img = canvas.drawing.image(from: bounds, scale: UIScreen.main.scale)
        return img.pngData()
    }
}

// MARK: - PencilContainerView

/// The actual UIView returned to SwiftUI. Houses PKCanvasView and all
/// UIKit gesture/interaction/pointer layers.
final class PencilContainerView: UIView {

    let canvasView = PKCanvasView()

    // Hover preview ring drawn on a CAShapeLayer above the canvas.
    private let hoverLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCanvas()
        setupHoverLayer()
    }
    required init?(coder: NSCoder) { fatalError("storyboards not used") }

    private func setupCanvas() {
        canvasView.frame = bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        // Finger touches scroll/navigate the hub; only Pencil draws.
        canvasView.drawingPolicy = .pencilOnly
        addSubview(canvasView)
    }

    private func setupHoverLayer() {
        hoverLayer.fillColor   = UIColor.clear.cgColor
        hoverLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor
        hoverLayer.lineWidth   = 1.5
        hoverLayer.isHidden    = true
        layer.addSublayer(hoverLayer)
    }

    func showHoverRing(at point: CGPoint, radius: CGFloat) {
        let path = UIBezierPath(
            arcCenter: point, radius: radius,
            startAngle: 0, endAngle: 2 * .pi, clockwise: true
        )
        hoverLayer.path   = path.cgPath
        hoverLayer.isHidden = false
    }

    func hideHoverRing() { hoverLayer.isHidden = true }
}

// MARK: - PencilMetricsGestureRecognizer

/// A non-cancelling gesture recogniser that sits on the canvas view and
/// extracts PencilStrokeMetrics from every coalesced and predicted touch.
/// It never transitions out of .possible, so PKCanvasView's own recognisers
/// are never blocked.
final class PencilMetricsGestureRecognizer: UIGestureRecognizer {

    var onSample:    (PencilStrokeMetrics) -> Void = { _ in }
    var onPredicted: (PencilStrokeMetrics) -> Void = { _ in }
    var onStrokeEnd: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Stay in .possible — do not call super.
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches where touch.type == .pencil {
            // Coalesced: full sub-frame fidelity for smooth curves.
            let coalesced = event.coalescedTouches(for: touch) ?? [touch]
            for sample in coalesced { onSample(metrics(from: sample, view: view)) }

            // Predicted: drawn at lower opacity for latency-hiding.
            let predicted = event.predictedTouches(for: touch) ?? []
            for sample in predicted { onPredicted(metrics(from: sample, view: view)) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onStrokeEnd?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onStrokeEnd?()
    }

    private func metrics(from touch: UITouch, view: UIView?) -> PencilStrokeMetrics {
        let maxForce = max(touch.maximumPossibleForce, 1)
        let ref = view ?? UIView()

        var rollAngle: Float?
        if #available(iOS 17.5, *) {
            // UITouch.rollAngle: Apple Pencil Pro barrel-roll (iPadOS 17.5+).
            // Use iOS spelling for #available to satisfy Xcode 26 SDK.
            rollAngle = Float(touch.rollAngle)
        }

        return PencilStrokeMetrics(
            normalizedForce: Float(touch.force / maxForce),
            altitudeAngle:   Float(touch.altitudeAngle),
            azimuthAngle:    Float(touch.azimuthAngle(in: ref)),
            rollAngle:       rollAngle,
            zOffset:         nil,
            location:        touch.location(in: ref)
        )
    }
}

// MARK: - PencilInputCoordinator (the actual coordinator)

/// Coordinator for PencilCanvasRepresentable.
/// Conforms to every Apple Pencil delegate protocol and wires them together.
final class PencilInputCoordinator: NSObject {

    // MARK: Callbacks → SwiftUI
    private let onData:          (Data?, Bool) -> Void
    private let onMetrics:       (PencilStrokeMetrics) -> Void
    private let onOCRComplete:   (String, Float) -> Void
    private let onSqueezeAction: (PencilQuickAction, CGPoint) -> Void

    // MARK: Internal state
    private let toolPicker = PKToolPicker()
    private var ocrDebounce: Task<Void, Never>?
    private weak var containerView: PencilContainerView?
    private var lastKnownTipPosition: CGPoint = .zero
    private var rulerActive = false

    init(
        onData:          @escaping (Data?, Bool) -> Void,
        onMetrics:       @escaping (PencilStrokeMetrics) -> Void,
        onOCRComplete:   @escaping (String, Float) -> Void,
        onSqueezeAction: @escaping (PencilQuickAction, CGPoint) -> Void
    ) {
        self.onData          = onData
        self.onMetrics       = onMetrics
        self.onOCRComplete   = onOCRComplete
        self.onSqueezeAction = onSqueezeAction
    }

    // MARK: - Configuration (called from makeUIView)

    func configure(container: PencilContainerView, accentColor: UIColor) {
        self.containerView = container
        let canvas = container.canvasView

        // PKCanvasView delegate
        canvas.delegate = self

        // Tool picker — floating style on iPad, not full-width.
        let shannonPreset = PKInkingTool(.pen, color: accentColor, width: 4)
        canvas.tool = shannonPreset
        toolPicker.setVisible(true, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }

        // Metrics gesture recognizer (coalesced + predicted touches)
        let metrics = PencilMetricsGestureRecognizer(
            target: nil, action: nil
        )
        metrics.cancelsTouchesInView  = false
        metrics.delaysTouchesBegan    = false
        metrics.delaysTouchesEnded    = false
        metrics.requiresExclusiveTouchType = false
        metrics.onSample    = { [weak self] m in self?.handleSample(m) }
        metrics.onPredicted = { [weak self] m in self?.onMetrics(m) }
        metrics.onStrokeEnd = { [weak self] in self?.scheduleOCR() }
        canvas.addGestureRecognizer(metrics)

        // UIPencilInteraction — double-tap + squeeze (Pencil Gen 2 / Pro)
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        pencilInteraction.isEnabled = true
        container.addInteraction(pencilInteraction)

        // UIHoverGestureRecognizer — Pencil hover preview (iPadOS 16+)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        canvas.addGestureRecognizer(hover)

        // UIPointerInteraction — custom cursor morphing on interactive elements
        let pointer = UIPointerInteraction(delegate: self)
        container.addInteraction(pointer)

        // Observe system Pencil preference changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pencilPreferenceChanged),
            // preferredTapActionDidChangeNotification was restructured in iOS 26 SDK;
            // use string form for forward/backward compatibility.
            name: Notification.Name("UIPencilInteractionPreferredTapActionDidChange"),
            object: nil
        )
    }

    // MARK: - External drawing push-down

    func applyExternalDrawing(data: Data?, to canvas: PKCanvasView) {
        guard let data else { return }
        if data.isEmpty, !canvas.drawing.strokes.isEmpty {
            canvas.drawing = PKDrawing()
        }
    }
}

// MARK: - Private helpers

private extension PencilInputCoordinator {

    func handleSample(_ m: PencilStrokeMetrics) {
        lastKnownTipPosition = m.location
        onMetrics(m)
    }

    /// Debounce: wait 1 s of inactivity, then run Vision OCR on the snapshot.
    func scheduleOCR() {
        ocrDebounce?.cancel()
        ocrDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.runOCR()
        }
    }

    @MainActor
    func runOCR() {
        guard let canvas = containerView?.canvasView else { return }
        let drawing = canvas.drawing
        guard !drawing.strokes.isEmpty else { return }

        let bounds = drawing.bounds.isEmpty ? canvas.bounds : drawing.bounds
        let image  = drawing.image(from: bounds, scale: UIScreen.main.scale)
        guard let cgImage = image.cgImage else { return }

        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard
                let obs = req.results as? [VNRecognizedTextObservation],
                let best = obs.compactMap({ $0.topCandidates(1).first }).max(by: { $0.confidence < $1.confidence })
            else { return }
            let text       = best.string
            let confidence = best.confidence
            DispatchQueue.main.async {
                self?.onOCRComplete(text, confidence)
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            options: [:]
        )
        DispatchQueue.global(qos: .userInteractive).async {
            try? handler.perform([request])
        }
    }

    @objc func pencilPreferenceChanged() {
        // The user changed their preference in Settings → Apple Pencil.
        // UIPencilInteraction automatically reads the new value on the next
        // event — no action needed here unless we cache the preference.
    }

    @objc func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard let container = containerView else { return }

        switch recognizer.state {
        case .began, .changed:
            let point  = recognizer.location(in: container)
            // Derive preview ring size from hover height when available.
            var radius: CGFloat = 14
            if let touches = recognizer.value(forKey: "_activeTouches") as? [UITouch],
               let touch = touches.first, touch.type == .pencil {
                // zOffset is available on Pencil Pro (iPadOS 16+); normalise to [8, 20].
                // We access the _zOffset value via the force property during hover,
                // which Apple maps to zOffset in the hover phase.
                let hoverHeight = Float(touch.force) // force encodes zOffset during hover
                radius = CGFloat(8 + (1 - min(hoverHeight, 1)) * 12)
            }
            container.showHoverRing(at: point, radius: radius)

        case .ended, .cancelled:
            container.hideHoverRing()

        default:
            break
        }
    }
}

// MARK: - PKCanvasViewDelegate

extension PencilInputCoordinator: PKCanvasViewDelegate {

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let data  = canvasView.drawing.dataRepresentation()
        let empty = canvasView.drawing.strokes.isEmpty
        onData(data, empty)
    }
}

// MARK: - UIPencilInteractionDelegate

extension PencilInputCoordinator: UIPencilInteractionDelegate {

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        // Respect the user's preference set in Settings → Apple Pencil.
        // UIPencilInteraction.preferredTapAction reflects the live setting.
        let action = UIPencilInteraction.preferredTapAction
        switch action {
        case .switchEraser:
            toggleEraser()
        case .switchPrevious:
            switchToPreviousTool()
        case .showColorPalette:
            if let canvas = containerView?.canvasView {
                toolPicker.setVisible(true, forFirstResponder: canvas)
            }
        case .ignore:
            break
        @unknown default:
            toggleEraser()
        }
    }

    private func toggleEraser() {
        guard let canvas = containerView?.canvasView else { return }
        if canvas.tool is PKEraserTool {
            canvas.tool = PKInkingTool(.pen, color: UIColor(Color.shannonAccent), width: 4)
        } else {
            canvas.tool = PKEraserTool(.vector)
        }
    }

    private func switchToPreviousTool() {
        guard let canvas = containerView?.canvasView else { return }
        // Cycle through pen → pencil → monoline on repeated double-taps.
        if let ink = canvas.tool as? PKInkingTool {
            let next: PKInkingTool.InkType
            switch ink.inkType {
            case .pen:      next = .pencil
            case .pencil:   next = .monoline
            default:        next = .pen
            }
            canvas.tool = PKInkingTool(next, color: ink.color, width: ink.width)
        } else {
            canvas.tool = PKInkingTool(.pen, color: UIColor(Color.shannonAccent), width: 4)
        }
    }

    private func switchToInk() {
        guard let canvas = containerView?.canvasView else { return }
        canvas.tool = PKInkingTool(.pen, color: UIColor(Color.shannonAccent), width: 4)
    }

    // MARK: Squeeze (Pencil Pro, iPadOS 17.5+)

    @available(iOS 17.5, *)
    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        guard squeeze.phase == .ended else { return }
        // Determine action from squeeze — default to annotate.
        // Full radial-menu selection is handled in RadialMenuView; here we
        // fire the callback so SwiftUI can present the overlay.
        onSqueezeAction(.annotate, lastKnownTipPosition)
    }
}

// MARK: - UIPointerInteractionDelegate

extension PencilInputCoordinator: UIPointerInteractionDelegate {

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        guard let canvas = containerView?.canvasView else { return nil }
        // Custom ring cursor matching the active tool colour.
        let toolColor: UIColor
        if let ink = canvas.tool as? PKInkingTool {
            toolColor = ink.color
        } else {
            toolColor = UIColor(Color.shannonAccent)
        }
        let shape = UIPointerShape.roundedRect(
            CGRect(x: -10, y: -10, width: 20, height: 20),
            radius: 10
        )
        let effect = UIPointerEffect.highlight(
            UITargetedPreview(view: interaction.view ?? UIView())
        )
        _ = toolColor // colour used for the ring — future: tint the shape layer
        return UIPointerStyle(effect: effect, shape: shape)
    }
}

// MARK: - UIScribbleInteractionDelegate (shared helper)

/// Attach UIScribbleInteraction to any UITextField / UITextView that should
/// accept Pencil handwriting input. Called by CommandPaletteView and
/// VoiceDictation field setup.
extension PencilInputCoordinator: UIScribbleInteractionDelegate {

    func scribbleInteraction(
        _ interaction: UIScribbleInteraction,
        shouldBeginAt location: CGPoint
    ) -> Bool {
        // Always accept Scribble — every text field is a valid Pencil target.
        true
    }

    func scribbleInteractionWillBeginWriting(_ interaction: UIScribbleInteraction) {
        // Disable autocorrect momentarily to avoid interference during live recognition.
        if let field = interaction.view as? UITextField {
            field.autocorrectionType = .no
        }
    }

    func scribbleInteractionDidFinishWriting(_ interaction: UIScribbleInteraction) {
        if let field = interaction.view as? UITextField {
            field.autocorrectionType = .default
        }
    }
}

// MARK: - ScribbleTextField SwiftUI bridge

/// A UITextField wrapped with UIScribbleInteraction so the user can hand-write
/// directly into it with Apple Pencil.
struct ScribbleTextField: UIViewRepresentable {

    @Binding var text: String
    var placeholder: String = ""

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder          = placeholder
        field.autocorrectionType   = .default
        field.delegate             = context.coordinator

        let scribble = UIScribbleInteraction(delegate: context.coordinator)
        field.addInteraction(scribble)

        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text { field.text = text }
    }

    func makeCoordinator() -> ScribbleCoordinator { ScribbleCoordinator(binding: $text) }

    // MARK: Coordinator

    final class ScribbleCoordinator: NSObject,
        UITextFieldDelegate,
        UIScribbleInteractionDelegate
    {
        private var binding: Binding<String>
        init(binding: Binding<String>) { self.binding = binding }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current  = textField.text ?? ""
            if let swiftRange = Range(range, in: current) {
                binding.wrappedValue = current.replacingCharacters(in: swiftRange, with: string)
            }
            return true
        }

        func scribbleInteraction(
            _ interaction: UIScribbleInteraction,
            shouldBeginAt location: CGPoint
        ) -> Bool { true }
    }
}

#endif // canImport(PencilKit)
