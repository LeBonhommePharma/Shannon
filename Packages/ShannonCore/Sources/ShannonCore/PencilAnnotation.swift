import Foundation

/// One Pencil annotation attached to an agent workspace or the global canvas.
///
/// ``pkDrawingData`` is treated opaquely by ShannonCore — only the iPadOS
/// target deserialises it into a `PKDrawing`. The Mac backup layer can
/// forward the bytes to iCloud without understanding their internal structure,
/// which keeps PencilKit out of the shared model layer.
public struct PencilAnnotation: Identifiable, Sendable, Codable, Equatable {

    // MARK: - Stored properties

    public var id: UUID

    /// Raw bytes from `PKDrawing.dataRepresentation()`. The iPadOS target
    /// reconstructs the drawing via `PKDrawing(data:)`.
    public var pkDrawingData: Data

    /// Text recognised from the stroke via Vision's `VNRecognizeTextRequest`.
    /// Nil until OCR completes (idle > 1 s after the last stroke ends).
    public var ocrText: String?

    /// Confidence of the highest-scoring recognised text fragment [0, 1].
    public var ocrConfidence: Float

    /// Stable `AgentState.id` this annotation is associated with.
    /// Nil when the annotation lives on the shared background canvas.
    public var linkedAgentID: String?

    public var createdAt: Date

    // MARK: - OCR threshold

    /// Minimum `ocrConfidence` for a recognised label to be shown inline.
    /// Fragments below this value show a review badge instead.
    public static let ocrDisplayThreshold: Float = 0.7

    /// True when OCR has produced a high-confidence result worth showing.
    public var ocrShouldDisplay: Bool {
        ocrText != nil && ocrConfidence >= Self.ocrDisplayThreshold
    }

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        pkDrawingData: Data = Data(),
        ocrText: String? = nil,
        ocrConfidence: Float = 0,
        linkedAgentID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.pkDrawingData = pkDrawingData
        self.ocrText = ocrText
        self.ocrConfidence = ocrConfidence
        self.linkedAgentID = linkedAgentID
        self.createdAt = createdAt
    }
}
