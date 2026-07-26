import XCTest
@testable import PillCore

/// Pure process-wide cache tests for O2 (`PetPackageResolver` resolve cache).
final class PetPackageResolverCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PetPackageResolver.clearResolveCache()
    }

    override func tearDown() {
        PetPackageResolver.clearResolveCache()
        super.tearDown()
    }

    /// Second resolve with identical inputs is a cache hit (no re-parse).
    func testProcessCacheHitsOnSecondResolve() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-cache-hit-\(UUID().uuidString)")
        let pkgDir = root.appendingPathComponent("cache-pet")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta: [String: Any] = [
            "id": "cache-pet",
            "displayName": "Cache Pet",
            "spriteVersionNumber": 2,
            "spritesheetPath": "spritesheet.webp",
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: pkgDir.appendingPathComponent("pet.json"))
        try Data("RIFF....WEBP".utf8)
            .write(to: pkgDir.appendingPathComponent("spritesheet.webp"))

        PetPackageResolver.clearResolveCache()
        let first = PetPackageResolver.resolve(petId: "cache-pet", roots: [root], requireV2: true)
        XCTAssertEqual(PetPackageResolver.resolveCacheMissCount, 1)
        XCTAssertEqual(PetPackageResolver.resolveCacheHitCount, 0)
        XCTAssertFalse(first.useProcedural)

        let second = PetPackageResolver.resolve(petId: "cache-pet", roots: [root], requireV2: true)
        XCTAssertEqual(second, first)
        XCTAssertEqual(PetPackageResolver.resolveCacheMissCount, 1)
        XCTAssertEqual(PetPackageResolver.resolveCacheHitCount, 1)

        // Procedural miss also caches.
        _ = PetPackageResolver.resolve(petId: "missing-xyz", roots: [root])
        _ = PetPackageResolver.resolve(petId: "missing-xyz", roots: [root])
        XCTAssertEqual(PetPackageResolver.resolveCacheMissCount, 2)
        XCTAssertEqual(PetPackageResolver.resolveCacheHitCount, 2)
    }

    /// Changing package mtime (pet.json rewrite) busts the roots-mtime key.
    func testProcessCacheInvalidatesOnRootsMtimeChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-cache-mtime-\(UUID().uuidString)")
        let pkgDir = root.appendingPathComponent("mtime-pet")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let metaURL = pkgDir.appendingPathComponent("pet.json")
        try Data("RIFF....WEBP".utf8)
            .write(to: pkgDir.appendingPathComponent("spritesheet.webp"))

        var meta: [String: Any] = [
            "id": "mtime-pet",
            "displayName": "Before",
            "spriteVersionNumber": 2,
            "spritesheetPath": "spritesheet.webp",
        ]
        try JSONSerialization.data(withJSONObject: meta).write(to: metaURL)

        PetPackageResolver.clearResolveCache()
        let before = PetPackageResolver.resolve(petId: "mtime-pet", roots: [root], requireV2: true)
        XCTAssertEqual(before.displayName, "Before")
        XCTAssertEqual(PetPackageResolver.resolveCacheMissCount, 1)

        _ = PetPackageResolver.resolve(petId: "mtime-pet", roots: [root], requireV2: true)
        XCTAssertEqual(PetPackageResolver.resolveCacheHitCount, 1)

        // Advance mtime past ms resolution used by the cache key.
        Thread.sleep(forTimeInterval: 0.02)
        meta["displayName"] = "After"
        try JSONSerialization.data(withJSONObject: meta).write(to: metaURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: metaURL.path
        )

        let after = PetPackageResolver.resolve(petId: "mtime-pet", roots: [root], requireV2: true)
        XCTAssertEqual(after.displayName, "After", "mtime change must re-resolve package")
        XCTAssertEqual(PetPackageResolver.resolveCacheMissCount, 2)
    }

    /// Path-env fingerprint change invalidates the whole process cache (O2).
    func testProcessCacheInvalidatesOnPathEnvChange() throws {
        let rootA = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-env-a-\(UUID().uuidString)")
        let rootB = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-env-b-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

        func writePackage(root: URL, id: String, name: String) throws {
            let pkgDir = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
            let meta: [String: Any] = [
                "id": id,
                "displayName": name,
                "spriteVersionNumber": 2,
                "spritesheetPath": "spritesheet.webp",
            ]
            try JSONSerialization.data(withJSONObject: meta)
                .write(to: pkgDir.appendingPathComponent("pet.json"))
            try Data("RIFF....WEBP".utf8)
                .write(to: pkgDir.appendingPathComponent("spritesheet.webp"))
        }
        try writePackage(root: rootA, id: "shared-id", name: "From A")
        try writePackage(root: rootB, id: "shared-id", name: "From B")

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        PetPackageResolver.clearResolveCache()
        let envA: [String: String] = [PetPaths.envPackages: rootA.path]
        let envB: [String: String] = [PetPaths.envPackages: rootB.path]

        let a = PetPackageResolver.resolve(
            petId: "shared-id", roots: nil, requireV2: true, home: home, env: envA
        )
        XCTAssertEqual(a.displayName, "From A")
        XCTAssertEqual(PetPackageResolver.resolveCacheMissCount, 1)

        _ = PetPackageResolver.resolve(
            petId: "shared-id", roots: nil, requireV2: true, home: home, env: envA
        )
        XCTAssertEqual(PetPackageResolver.resolveCacheHitCount, 1)

        let missesBeforeB = PetPackageResolver.resolveCacheMissCount
        let b = PetPackageResolver.resolve(
            petId: "shared-id", roots: nil, requireV2: true, home: home, env: envB
        )
        XCTAssertEqual(b.displayName, "From B")
        XCTAssertNotEqual(a.spritesheetURL, b.spritesheetURL)
        XCTAssertEqual(
            PetPackageResolver.resolveCacheMissCount, missesBeforeB + 1,
            "path-env change must invalidate prior entries (miss for B)"
        )

        let missesBeforeA2 = PetPackageResolver.resolveCacheMissCount
        let a2 = PetPackageResolver.resolve(
            petId: "shared-id", roots: nil, requireV2: true, home: home, env: envA
        )
        XCTAssertEqual(a2.displayName, "From A")
        XCTAssertEqual(PetPackageResolver.resolveCacheMissCount, missesBeforeA2 + 1)

        let fpA = PetPackageResolver.pathEnvFingerprint(envA)
        let fpB = PetPackageResolver.pathEnvFingerprint(envB)
        XCTAssertNotEqual(fpA, fpB)
    }

    /// requireV2 true vs false are separate cache entries.
    func testProcessCacheSeparatesRequireV2() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-pet-cache-v2-\(UUID().uuidString)")
        let pkgDir = root.appendingPathComponent("v1-pet")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta: [String: Any] = [
            "id": "v1-pet",
            "displayName": "V1 Only",
            "spriteVersionNumber": 1,
            "spritesheetPath": "spritesheet.webp",
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: pkgDir.appendingPathComponent("pet.json"))
        try Data("RIFF....WEBP".utf8)
            .write(to: pkgDir.appendingPathComponent("spritesheet.webp"))

        PetPackageResolver.clearResolveCache()
        let loose = PetPackageResolver.resolve(petId: "v1-pet", roots: [root], requireV2: false)
        let strict = PetPackageResolver.resolve(petId: "v1-pet", roots: [root], requireV2: true)
        XCTAssertFalse(loose.useProcedural)
        XCTAssertEqual(loose.spriteVersion, 1)
        XCTAssertTrue(strict.useProcedural, "requireV2 skips explicit v1")
        XCTAssertEqual(PetPackageResolver.resolveCacheMissCount, 2)
        XCTAssertEqual(PetPackageResolver.resolveCacheHitCount, 0)

        _ = PetPackageResolver.resolve(petId: "v1-pet", roots: [root], requireV2: false)
        _ = PetPackageResolver.resolve(petId: "v1-pet", roots: [root], requireV2: true)
        XCTAssertEqual(PetPackageResolver.resolveCacheHitCount, 2)
    }
}
