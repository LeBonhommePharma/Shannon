import Foundation

// MARK: - PencilAnnotationStore

/// Persistent, observable store for ``PencilAnnotation`` records.
///
/// One store per agent-id. Annotation files are written with
/// `Data.WritingOptions.completeFileProtection` on iOS so their bytes are
/// unreadable while the device is locked.
///
/// Path layout:
/// `Documents/shannon/annotations/{sanitised-agentID}.annotations`
///
/// Availability: iOS 17 / macOS 14 / watchOS 10 so the `@Observable`
/// macro's expansion (ObservationRegistrar etc.) is always available.
/// Call sites inside `#if canImport(PencilKit)` blocks are already iOS 17+.
#if canImport(Observation)
import Observation

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
@Observable
public final class PencilAnnotationStore {

    // MARK: - Observable state

    public private(set) var annotations: [PencilAnnotation] = []

    // MARK: - Private

    private let agentID: String

    // MARK: - Init

    public init(agentID: String) {
        self.agentID = agentID
        load()
    }

    // MARK: - Public API

    public func upsert(_ annotation: PencilAnnotation) {
        if let idx = annotations.firstIndex(where: { $0.id == annotation.id }) {
            annotations[idx] = annotation
        } else {
            annotations.append(annotation)
        }
        persist()
    }

    public func remove(id: UUID) {
        annotations.removeAll { $0.id == id }
        persist()
    }

    public func removeAll() {
        annotations.removeAll()
        persist()
    }

    // MARK: - Persistence

    /// URL for this agent's annotation bundle.
    public static func fileURL(agentID: String) -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        return documents
            .appendingPathComponent("shannon")
            .appendingPathComponent("annotations")
            .appendingPathComponent("\(sanitize(agentID)).annotations")
    }

    private func load() {
        guard
            let url = Self.fileURL(agentID: agentID),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([PencilAnnotation].self, from: data)
        else { return }
        annotations = decoded
    }

    private func persist() {
        guard
            let url = Self.fileURL(agentID: agentID),
            let data = try? JSONEncoder().encode(annotations)
        else { return }

        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #if os(iOS) || targetEnvironment(macCatalyst)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }

    // MARK: - Helpers

    private static func sanitize(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scrubbed = component.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : Character("-") }
        return scrubbed.isEmpty ? "unknown" : String(scrubbed)
    }
}

#else

// MARK: - iOS 16 / pre-Observation fallback

import Combine

public final class PencilAnnotationStore: ObservableObject {

    @Published public private(set) var annotations: [PencilAnnotation] = []
    private let agentID: String

    public init(agentID: String) {
        self.agentID = agentID
        load()
    }

    public func upsert(_ annotation: PencilAnnotation) {
        if let idx = annotations.firstIndex(where: { $0.id == annotation.id }) {
            annotations[idx] = annotation
        } else {
            annotations.append(annotation)
        }
        persist()
    }

    public func remove(id: UUID) {
        annotations.removeAll { $0.id == id }
        persist()
    }

    public func removeAll() {
        annotations.removeAll()
        persist()
    }

    public static func fileURL(agentID: String) -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        return documents
            .appendingPathComponent("shannon")
            .appendingPathComponent("annotations")
            .appendingPathComponent("\(sanitize(agentID)).annotations")
    }

    private func load() {
        guard
            let url = Self.fileURL(agentID: agentID),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([PencilAnnotation].self, from: data)
        else { return }
        annotations = decoded
    }

    private func persist() {
        guard
            let url = Self.fileURL(agentID: agentID),
            let data = try? JSONEncoder().encode(annotations)
        else { return }

        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #if os(iOS) || targetEnvironment(macCatalyst)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }

    private static func sanitize(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scrubbed = component.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : Character("-") }
        return scrubbed.isEmpty ? "unknown" : String(scrubbed)
    }
}

#endif
