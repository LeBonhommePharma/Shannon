import SwiftUI
import ShannonTheme
#if canImport(PencilKit)
import PencilKit
#endif

/// A Pencil canvas laid over a card.
///
/// Vector paths only — the drawing is persisted as `PKDrawing` data, never as a
/// rasterised image, so a note scribbled on an 11" iPad still reads sharp when
/// the same record is opened on a 13".
struct AnnotationOverlayView: View {
    /// Namespaces the saved drawing. Agent cards pass the agent id; the docking
    /// card passes its benchmark id, so an ROI sketch does not overwrite notes.
    var scopeID: String
    var name: String = "canvas"
    var title: String
    /// Docking ROI mode draws over a pocket wireframe rather than a blank sheet.
    var showsPocketWireframe: Bool = false
    var onClose: () -> Void

    @State private var drawingData: Data?
    @State private var isEmpty = true

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                if showsPocketWireframe {
                    PocketWireframe()
                        .padding(ShannonSpacing.lg)
                }

                #if canImport(PencilKit)
                PencilCanvas(data: $drawingData, isEmpty: $isEmpty)
                #else
                Text("Pencil annotation needs PencilKit.")
                    .shannonText(.shannonBody, color: .shannonSecondary)
                #endif
            }
            .background(Color.shannonSurface)
        }
        .background(Color.shannonBackground)
        .onAppear { drawingData = AnnotationStore.load(agentID: scopeID, name: name) }
        .onChange(of: drawingData) { newValue in
            guard let newValue else { return }
            AnnotationStore.save(newValue, agentID: scopeID, name: name)
        }
    }

    private var header: some View {
        HStack(spacing: ShannonSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .shannonText(.shannonHeadline)
                Text(AnnotationStore.relativePath(agentID: scopeID, name: name))
                    .shannonNumeric(color: .shannonTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            Button("Erase All") {
                drawingData = Data()
                AnnotationStore.delete(agentID: scopeID, name: name)
            }
            .disabled(isEmpty)
            .keyboardShortcut(.delete, modifiers: [.command, .shift])

            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .font(.shannonCallout)
        .padding(ShannonSpacing.md)
        .background(Color.shannonSurfaceElevated)
    }
}

/// Placeholder for the binding-pocket render. Real geometry arrives with the
/// FlexAID∆S pocket export; until then the ROI is drawn over a stand-in that is
/// obviously schematic rather than a fake structure.
private struct PocketWireframe: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 24)
            let stroke = GraphicsContext.Shading.color(.shannonTertiary.opacity(0.55))

            for ring in 0..<4 {
                let inset = CGFloat(ring) * min(rect.width, rect.height) / 12
                let path = Path(ellipseIn: rect.insetBy(dx: inset, dy: inset * 1.4))
                context.stroke(path, with: stroke, lineWidth: 0.75)
            }
            for spoke in 0..<12 {
                let angle = Double(spoke) / 12 * 2 * .pi
                var path = Path()
                path.move(to: CGPoint(x: rect.midX, y: rect.midY))
                path.addLine(to: CGPoint(
                    x: rect.midX + cos(angle) * rect.width / 2,
                    y: rect.midY + sin(angle) * rect.height / 2
                ))
                context.stroke(path, with: stroke, lineWidth: 0.5)
            }
        }
        .overlay(alignment: .bottom) {
            Text("Binding pocket · schematic placeholder")
                .shannonText(.shannonCaption, color: .shannonTertiary)
        }
        .allowsHitTesting(false)
    }
}

#if canImport(PencilKit)

/// `PKCanvasView` bridged with the two pieces of state SwiftUI needs: the
/// serialised drawing, and whether there is anything to erase.
private struct PencilCanvas: UIViewRepresentable {
    @Binding var data: Data?
    @Binding var isEmpty: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Finger input stays available: a Magic Keyboard trackpad and a finger
        // are both legitimate ways to annotate when the Pencil is not to hand.
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        canvas.tool = PKInkingTool(.pen, color: .systemBlue, width: 4)

        if let data, let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }

        let picker = context.coordinator.toolPicker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // An externally cleared drawing (the Erase All button writes empty
        // data) has to be pushed back down; ordinary strokes flow the other way
        // and must not be echoed, or the canvas resets mid-stroke.
        guard let data else { return }
        if data.isEmpty, !canvas.drawing.strokes.isEmpty {
            canvas.drawing = PKDrawing()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
        private let parent: PencilCanvas

        init(_ parent: PencilCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.data = canvasView.drawing.dataRepresentation()
            parent.isEmpty = canvasView.drawing.strokes.isEmpty
        }
    }
}

#endif
