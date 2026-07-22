import SwiftUI
import ShannonTheme
import ShannonCore
#if canImport(PencilKit)
import PencilKit
#endif

// MARK: - AnnotationOverlayView

/// Full-featured Pencil annotation sheet.
///
/// What this gives you compared to the basic PKCanvasView wrapper:
///  - `drawingPolicy = .pencilOnly` — finger touches pass through to the hub
///  - Pressure / tilt / azimuth → live `PencilStrokeMetrics` stream
///  - Barrel-roll orientation (Pencil Pro, iPadOS 17.5+)
///  - Hover preview ring before the tip touches (iPadOS 16+)
///  - Double-tap respects system Settings → Apple Pencil preference
///  - Squeeze (Pencil Pro) shows radial quick-action menu at tip position
///  - OCR: after 1 s idle, Vision scans the drawing; confident text appears inline
///  - UIScribbleInteraction on the search / name field
///  - Export as PNG via PKDrawing snapshot
///  - Persists via `PencilAnnotationStore` (FileProtection.complete)
struct AnnotationOverlayView: View {

    var scopeID: String
    var name:    String = "canvas"
    var title:   String

    /// Docking ROI mode overlays a binding-pocket wireframe schematic.
    var showsPocketWireframe: Bool = false
    var onClose: () -> Void

    // MARK: State

    @State private var drawingData: Data?
    @State private var isEmpty     = true
    @State private var ocrLabel:   String?
    @State private var ocrConfidence: Float = 0

    @State private var lastMetrics:   PencilStrokeMetrics?
    @State private var squeezeOrigin: CGPoint?
    @State private var showRadialMenu = false

    @State private var exportedImage: UIImage?
    @State private var showingExport  = false

    private let annotationStore: PencilAnnotationStore

    init(
        scopeID: String,
        name:    String = "canvas",
        title:   String,
        showsPocketWireframe: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.scopeID  = scopeID
        self.name     = name
        self.title    = title
        self.showsPocketWireframe = showsPocketWireframe
        self.onClose  = onClose
        self.annotationStore = PencilAnnotationStore(agentID: scopeID)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                ZStack(alignment: .topLeading) {
                    if showsPocketWireframe { PocketWireframe().padding(ShannonSpacing.lg) }

                    #if canImport(PencilKit)
                    PencilCanvasRepresentable(
                        drawingData:     $drawingData,
                        isEmpty:         $isEmpty,
                        accentColor:     UIColor(Color.shannonAccent),
                        onMetrics:       { lastMetrics = $0 },
                        onOCRComplete:   handleOCR,
                        onSqueezeAction: handleSqueeze
                    )
                    #else
                    Text("Pencil annotation requires PencilKit.")
                        .shannonText(.shannonBody, color: .shannonSecondary)
                    #endif

                    // OCR label overlay (non-destructive, floats above strokes)
                    if let label = ocrLabel {
                        ocrOverlay(label)
                    }
                }
                .background(Color.shannonSurface)
            }

            // Squeeze radial menu (Pencil Pro)
            if showRadialMenu, let origin = squeezeOrigin {
                #if canImport(PencilKit)
                RadialMenuView(
                    origin:   origin,
                    onAction: performQuickAction,
                    onDismiss: { showRadialMenu = false }
                )
                .transition(.opacity)
                .zIndex(50)
                #endif
            }
        }
        .background(Color.shannonBackground)
        .onAppear { loadDrawing() }
        .onChange(of: drawingData) { persist($0) }
        .sheet(isPresented: $showingExport) { exportSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: ShannonSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).shannonText(.shannonHeadline)
                Text(AnnotationStore.relativePath(agentID: scopeID, name: name))
                    .shannonNumeric(color: .shannonTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()

            Button { exportCanvas() } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(isEmpty)

            Button("Erase All") {
                drawingData = Data()
                AnnotationStore.delete(agentID: scopeID, name: name)
                annotationStore.removeAll()
                ocrLabel = nil
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

    // MARK: - OCR overlay

    private func ocrOverlay(_ text: String) -> some View {
        HStack(spacing: ShannonSpacing.xs) {
            Image(systemName: ocrConfidence >= PencilAnnotation.ocrDisplayThreshold
                  ? "text.viewfinder"
                  : "questionmark.circle")
                .font(.caption2)
            Text(text)
                .shannonText(.shannonCaption)
                .lineLimit(2)
        }
        .padding(.horizontal, ShannonSpacing.sm)
        .padding(.vertical, ShannonSpacing.xs)
        .background(
            ocrConfidence >= PencilAnnotation.ocrDisplayThreshold
                ? Color.shannonAccent.opacity(0.15)
                : Color.shannonSurfaceElevated
        )
        .clipShape(RoundedRectangle(cornerRadius: ShannonRadius.sm))
        .padding(ShannonSpacing.sm)
    }

    // MARK: - Export sheet

    private var exportSheet: some View {
        VStack(spacing: ShannonSpacing.lg) {
            if let img = exportedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: ShannonRadius.lg))
            }
            ShareLink(
                "Share PNG",
                item: exportedImage.map { Image(uiImage: $0) } ?? Image(systemName: "exclamationmark"),
                preview: SharePreview(title, image: exportedImage.map { Image(uiImage: $0) } ?? Image(systemName: "pencil"))
            )
            .buttonStyle(.borderedProminent)

            Button("Close", action: { showingExport = false })
        }
        .padding(ShannonSpacing.xl)
        .presentationDetents([.medium])
    }

    // MARK: - Persistence

    private func loadDrawing() {
        drawingData = AnnotationStore.load(agentID: scopeID, name: name)
    }

    private func persist(_ newData: Data?) {
        guard let data = newData else { return }
        AnnotationStore.save(data, agentID: scopeID, name: name)

        // Also persist in PencilAnnotationStore for sync
        var annotation = annotationStore.annotations.first
            ?? PencilAnnotation(linkedAgentID: scopeID)
        annotation.pkDrawingData = data
        if let label = ocrLabel {
            annotation.ocrText       = label
            annotation.ocrConfidence = ocrConfidence
        }
        annotationStore.upsert(annotation)
    }

    // MARK: - Event handlers

    private func handleOCR(text: String, confidence: Float) {
        ocrLabel       = text
        ocrConfidence  = confidence
    }

    private func handleSqueeze(action: PencilQuickAction, at point: CGPoint) {
        squeezeOrigin = point
        withAnimation(.shannonSnap) { showRadialMenu = true }
    }

    private func exportCanvas() {
        #if canImport(PencilKit)
        guard let data = drawingData,
              let drawing = try? PKDrawing(data: data) else { return }
        let bounds = drawing.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 1024, height: 768)
            : drawing.bounds
        exportedImage = drawing.image(from: bounds, scale: UIScreen.main.scale)
        showingExport = true
        #endif
    }

    private func performQuickAction(_ action: PencilQuickAction) {
        switch action {
        case .annotate:
            break // Already in annotate mode
        case .summariseAgent:
            break // Hook into AgentHubViewModel — caller's responsibility
        case .clearCanvas:
            drawingData = Data()
            AnnotationStore.delete(agentID: scopeID, name: name)
            annotationStore.removeAll()
            ocrLabel = nil
        case .exportDrawing:
            exportCanvas()
        case .toggleRuler:
            break // PKToolPicker manages the ruler toggle via its own UI
        }
    }
}

// MARK: - PocketWireframe (unchanged from prior commit)

private struct PocketWireframe: View {
    var body: some View {
        Canvas { context, size in
            let rect   = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 24)
            let stroke = GraphicsContext.Shading.color(.shannonTertiary.opacity(0.55))
            for ring in 0..<4 {
                let inset = CGFloat(ring) * min(rect.width, rect.height) / 12
                let path  = Path(ellipseIn: rect.insetBy(dx: inset, dy: inset * 1.4))
                context.stroke(path, with: stroke, lineWidth: 0.75)
            }
            for spoke in 0..<12 {
                let angle = Double(spoke) / 12 * 2 * .pi
                var path  = Path()
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
