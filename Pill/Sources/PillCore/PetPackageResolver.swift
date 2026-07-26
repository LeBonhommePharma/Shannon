// PetPackageResolver.swift — resolve Codex-compatible v2 pet packages.
//
// Package layout:
//   <package-root>/<pet-id>/{pet.json,spritesheet.webp}
//
// Roots come from `PetPaths` (shared with agent memory). Agent-memory roots are
// never treated as a spritesheet store.
//
// O2: process-wide resolve cache keyed by (petId, roots mtime, requireV2,
// path-env fingerprint). Invalidates when roots mtime or path env changes.

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

    // MARK: - Process-wide resolve cache (O2)

    /// Clear the process-wide package resolve cache (tests / path-env rebind).
    public static func clearResolveCache() {
        resolveCache.clear()
    }

    /// Cache hits since last clear (for pure cache tests).
    public static var resolveCacheHitCount: Int { resolveCache.hitCount }

    /// Cache misses since last clear (for pure cache tests).
    public static var resolveCacheMissCount: Int { resolveCache.missCount }

    private static let resolveCache = PackageResolveCache()

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
    ///
    /// Results are cached process-wide (O2) keyed by pet id, requireV2, search
    /// roots, max roots/package mtime, and path-env fingerprint. Call
    /// `clearResolveCache()` after tests or when path env is rebound in-process.
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
        let pathEnv = pathEnvFingerprint(env)
        let mtime = rootsMtimeSignature(roots: search, petId: pid, fileManager: fileManager)
        let key = PackageResolveCache.Key(
            petId: pid,
            requireV2: requireV2,
            rootsPaths: search.map { $0.standardizedFileURL.path },
            rootsMtime: mtime,
            pathEnv: pathEnv,
            memoryPath: memory.path
        )

        // Global invalidation when path env fingerprint changes mid-process.
        resolveCache.invalidateIfPathEnvChanged(pathEnv)

        if let hit = resolveCache.get(key) {
            return hit
        }

        let result = resolveUncached(
            pid: pid,
            search: search,
            memory: memory,
            requireV2: requireV2,
            fileManager: fileManager
        )
        resolveCache.set(key, result)
        return result
    }

    // MARK: - Uncached resolve

    private static func resolveUncached(
        pid: String,
        search: [URL],
        memory: URL,
        requireV2: Bool,
        fileManager: FileManager
    ) -> PetPackage {
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

    // MARK: - Cache key helpers

    /// Fingerprint of path-related env vars that affect root / memory resolution.
    static func pathEnvFingerprint(_ env: [String: String]) -> String {
        let keys = [
            PetPaths.envUnified,
            PetPaths.envPackages,
            PetPaths.envAgents,
            PetPaths.envCodexHome,
            PetPaths.envShannonHome,
            PetPaths.envFlexaidHome,
        ]
        return keys.map { key in
            let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "\(key)=\(raw)"
        }.joined(separator: "\u{1e}")
    }

    /// Max mtime (ms) over package roots and the candidate package / pet.json.
    /// Changing pet.json or package dir content updates this and busts the cache.
    static func rootsMtimeSignature(
        roots: [URL],
        petId: String,
        fileManager: FileManager
    ) -> Int64 {
        var maxMs: Int64 = 0
        func consider(_ path: String) {
            guard let date = try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
            else { return }
            let ms = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
            if ms > maxMs { maxMs = ms }
        }
        for root in roots {
            consider(root.path)
            let pkg = root.appendingPathComponent(petId)
            consider(pkg.path)
            consider(pkg.appendingPathComponent("pet.json").path)
            consider(pkg.appendingPathComponent("spritesheet.webp").path)
            consider(root.appendingPathComponent("pet.json").path)
        }
        return maxMs
    }


    /// List discoverable packages under search roots (first id wins; sorted by petId).
    /// Parity with hub `list_pet_packages`. Agent-memory roots are skipped.
    public static func listPetPackages(
        roots: [URL]? = nil,
        requireV2: Bool = true,
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [PetPackage] {
        let search = roots
            ?? PetPaths.packageRootsExcludingMemory(home: home, env: env, fileManager: fileManager)
        let memory = PetPaths.agentMemoryRoot(home: home, env: env).standardizedFileURL
        var found: [String: PetPackage] = [:]

        for root in search {
            let standardized = root.standardizedFileURL
            if standardized == memory { continue }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            let children = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            var scan = children
            scan.append(root)

            for child in scan {
                var childIsDir: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &childIsDir),
                      childIsDir.boolValue else { continue }
                let petId = child.lastPathComponent
                guard let pkg = package(from: child, petId: petId, fileManager: fileManager) else {
                    continue
                }
                if requireV2 && !pkg.isV2 { continue }
                if found[pkg.petId] == nil {
                    found[pkg.petId] = pkg
                }
            }
        }
        return found.values.sorted { $0.petId < $1.petId }
    }

    /// Package ids only — pure path for Settings pickers (E1).
    public static func listPetPackageIds(
        roots: [URL]? = nil,
        requireV2: Bool = true,
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        listPetPackages(
            roots: roots,
            requireV2: requireV2,
            fileManager: fileManager,
            home: home,
            env: env
        ).map(\.petId)
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

// MARK: - Process-wide cache store

/// Thread-safe process-wide cache for `PetPackageResolver.resolve` (O2).
private final class PackageResolveCache: @unchecked Sendable {
    struct Key: Hashable {
        let petId: String
        let requireV2: Bool
        let rootsPaths: [String]
        let rootsMtime: Int64
        let pathEnv: String
        let memoryPath: String
    }

    private let lock = NSLock()
    private var entries: [Key: PetPackage] = [:]
    private var lastPathEnv: String?
    private(set) var hitCount = 0
    private(set) var missCount = 0

    func get(_ key: Key) -> PetPackage? {
        lock.lock()
        defer { lock.unlock() }
        if let value = entries[key] {
            hitCount += 1
            return value
        }
        missCount += 1
        return nil
    }

    func set(_ key: Key, _ value: PetPackage) {
        lock.lock()
        entries[key] = value
        lock.unlock()
    }

    /// Drop all entries when path-env fingerprint changes (O2 invalidation).
    func invalidateIfPathEnvChanged(_ pathEnv: String) {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastPathEnv, last != pathEnv {
            entries.removeAll(keepingCapacity: false)
        }
        lastPathEnv = pathEnv
    }

    func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: false)
        lastPathEnv = nil
        hitCount = 0
        missCount = 0
        lock.unlock()
    }
}
