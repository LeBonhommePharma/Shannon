import Foundation

/// Where Pencil annotations live.
///
/// The Mac keeps per-agent scratch state under `~/.shannon/pets/{agent_id}/`.
/// An iPad app cannot write there, so the same relative tree is mirrored inside
/// the app container: `Documents/pets/{agent_id}/annotations/`. Keeping the
/// suffix identical means a future sync can copy the subtree across verbatim
/// instead of translating paths.
enum AnnotationStore {
    /// Relative path shared with the Mac, for the eventual sync and for logs.
    static func relativePath(agentID: String, name: String) -> String {
        "pets/\(sanitize(agentID))/annotations/\(sanitize(name)).drawing"
    }

    static func url(agentID: String, name: String = "canvas") -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        return documents.appendingPathComponent(relativePath(agentID: agentID, name: name))
    }

    /// Vector path data as produced by `PKDrawing.dataRepresentation()`.
    static func load(agentID: String, name: String = "canvas") -> Data? {
        guard let url = url(agentID: agentID, name: name) else { return nil }
        return try? Data(contentsOf: url)
    }

    @discardableResult
    static func save(_ data: Data, agentID: String, name: String = "canvas") -> Bool {
        guard let url = url(agentID: agentID, name: name) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func delete(agentID: String, name: String = "canvas") -> Bool {
        guard let url = url(agentID: agentID, name: name) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    static func hasAnnotation(agentID: String, name: String = "canvas") -> Bool {
        guard let url = url(agentID: agentID, name: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Agent ids arrive from the Mac and are not guaranteed to be path-safe.
    private static func sanitize(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scrubbed = component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return scrubbed.isEmpty ? "unknown" : String(scrubbed)
    }
}
