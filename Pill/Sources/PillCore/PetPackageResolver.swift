// PetPackageResolver.swift — resolve Codex-compatible v2 pet packages.
//
// Package layout:
//   <package-root>/<pet-id>/{pet.json,spritesheet.webp}
//
// Roots come from `PetPaths` (shared with agent memory). Agent-memory roots are
// never treated as a spritesheet store.

import Foundation

/// Resolved Codex pet package, or a procedural-fallback sentinel.
public struct PetPackage: Sendable, Equatable {
    public let petId: String
    public let root: URL?
    public let petJSONURL: URL?
    public let spritesheetURL: URL?
    public let spriteVersion: Int
    public let displayName: String
    public let description: String
    /// When true, draw procedural CompanionArt — package missing or unusable.
    public let useProcedural: Bool
    public let notes: [String]

    public var isV2: Bool { spriteVersion >= 2 }

    public static func procedural(petId: String, notes: [String] = []) -> PetPackage {
        PetPackage(
            petId: petId,
            root: nil,
            petJSONURL: nil,
            spritesheetURL: nil,
            spriteVersion: 0,
            displayName: petId,
            description: "",
            useProcedural: true,
            notes: notes.isEmpty
                ? ["no Codex v2 package found; using procedural companion art"]
                : notes
        )
    }
}

public enum PetPackageResolver {

    public static let defaultPetId = "shannon"

    /// Search roots (first hit wins). Never includes agent-memory roots.
    /// Delegates to `PetPaths.packageRootsExcludingMemory`.
    public static func defaultRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        PetPaths.packageRootsExcludingMemory(home: home, env: env)
    }

    /// Shannon agent-memory root — never used for spritesheet discovery.
    public static func agentMemoryRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        PetPaths.agentMemoryRoot(home: home, env: env)
    }

    /// Resolve package by id. Always succeeds: missing → procedural.
    public static func resolve(
        petId: String = defaultPetId,
        roots: [URL]? = nil,
        fileManager: FileManager = .default,
        requireV2: Bool = false,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> PetPackage {
        let pid = petId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPetId
            : petId.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = roots
            ?? PetPaths.packageRootsExcludingMemory(home: home, env: env, fileManager: fileManager)
        let memory = PetPaths.agentMemoryRoot(home: home, env: env).standardizedFileURL

        for root in search {
            let standardized = root.standardizedFileURL
            if standardized == memory { continue }

            let candidate = root.appendingPathComponent(pid)
            if let pkg = package(from: candidate, petId: pid, fileManager: fileManager) {
                if requireV2 && !pkg.isV2 { continue }
                return pkg
            }
            if root.lastPathComponent == pid,
               let pkg = package(from: root, petId: pid, fileManager: fileManager) {
                if requireV2 && !pkg.isV2 { continue }
                return pkg
            }
        }
        return .procedural(petId: pid)
    }

    // MARK: - Internals

    private static func package(
        from directory: URL,
        petId: String,
        fileManager: FileManager
    ) -> PetPackage? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }

        let metaURL = directory.appendingPathComponent("pet.json")
        guard fileManager.fileExists(atPath: metaURL.path),
              let data = try? Data(contentsOf: metaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let declaredVersion = (json["spriteVersionNumber"] as? Int)
            ?? (json["sprite_version"] as? Int)
        let sheetRel = (json["spritesheetPath"] as? String)
            ?? (json["spritesheet_path"] as? String)
            ?? "spritesheet.webp"

        var sheet = directory.appendingPathComponent(sheetRel)
        if !fileManager.fileExists(atPath: sheet.path) {
            let alts = ["spritesheet.webp", "spritesheet.png", "spritesheet.jpg"]
            var found: URL?
            for alt in alts {
                let c = directory.appendingPathComponent(alt)
                if fileManager.fileExists(atPath: c.path) {
                    found = c
                    break
                }
            }
            guard let f = found else { return nil }
            sheet = f
        }

        let display = (json["displayName"] as? String)
            ?? (json["display_name"] as? String)
            ?? petId
        let desc = (json["description"] as? String) ?? ""
        let id = (json["id"] as? String) ?? petId
        // B1: missing version + sheet present → infer v2 so requireV2 atlas draws.
        let inferred = inferredSpriteVersion(declared: declaredVersion, sheetPresent: true)
        var notes: [String] = []
        if let note = inferred.note {
            notes.append(note)
        }

        return PetPackage(
            petId: id,
            root: directory,
            petJSONURL: metaURL,
            spritesheetURL: sheet,
            spriteVersion: inferred.version,
            displayName: display,
            description: desc,
            useProcedural: false,
            notes: notes
        )
    }

    /// Resolve sprite version for a package with a found sheet (B1).
    ///
    /// - Explicit `spriteVersionNumber` / `sprite_version` wins when > 0
    /// - Missing / zero with a sheet → **2** so `requireV2` atlas path works
    ///   (oc-an / stitch-style packages that ship sheet + pet.json without version)
    /// - Explicit 1 stays 1 (incomplete atlas is intentional)
    public static func inferredSpriteVersion(
        declared: Int?,
        sheetPresent: Bool
    ) -> (version: Int, note: String?) {
        if let d = declared, d > 0 {
            if d < 2 {
                return (d, "spriteVersionNumber=\(d) (<2); atlas rows may be incomplete")
            }
            return (d, nil)
        }
        if sheetPresent {
            return (2, "spriteVersionNumber missing; inferred 2 from spritesheet presence")
        }
        return (0, nil)
    }
}
