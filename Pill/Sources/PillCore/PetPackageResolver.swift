// PetPackageResolver.swift — resolve Codex-compatible v2 pet packages.
//
// Package layout:
//   ${CODEX_HOME:-~/.codex}/pets/<pet-id>/{pet.json,spritesheet.webp}
//
// Shannon agent memory (~/.shannon/pets/{agent_id}/) is a different root and
// is never treated as a spritesheet store.

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

    /// Search roots (first hit wins). Never includes ~/.shannon/pets memory.
    public static func defaultRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var roots: [URL] = []
        if let extra = env["SHANNON_CODEX_PETS"], !extra.isEmpty {
            roots.append(URL(fileURLWithPath: (extra as NSString).expandingTildeInPath))
        }
        if let codexHome = env["CODEX_HOME"], !codexHome.isEmpty {
            roots.append(
                URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                    .appendingPathComponent("pets")
            )
        }
        roots.append(home.appendingPathComponent(".codex/pets"))
        return roots
    }

    public static func agentMemoryRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: URL
        if let log = env["SHANNON_LOG_DIR"], !log.isEmpty {
            base = URL(fileURLWithPath: (log as NSString).expandingTildeInPath)
        } else {
            base = home.appendingPathComponent(".shannon")
        }
        return base.appendingPathComponent("pets")
    }

    /// Resolve package by id. Always succeeds: missing → procedural.
    public static func resolve(
        petId: String = defaultPetId,
        roots: [URL]? = nil,
        fileManager: FileManager = .default,
        requireV2: Bool = false
    ) -> PetPackage {
        let pid = petId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPetId
            : petId.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = roots ?? defaultRoots()
        let memory = agentMemoryRoot().standardizedFileURL

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

        let version = (json["spriteVersionNumber"] as? Int)
            ?? (json["sprite_version"] as? Int)
            ?? 0
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
        var notes: [String] = []
        if version > 0 && version < 2 {
            notes.append("spriteVersionNumber=\(version) (<2); atlas rows may be incomplete")
        }

        return PetPackage(
            petId: id,
            root: directory,
            petJSONURL: metaURL,
            spritesheetURL: sheet,
            spriteVersion: version > 0 ? version : 1,
            displayName: display,
            description: desc,
            useProcedural: false,
            notes: notes
        )
    }
}
