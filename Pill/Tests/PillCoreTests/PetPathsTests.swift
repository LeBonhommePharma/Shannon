import XCTest
@testable import PillCore

/// Unified path policy for Codex packages + Shannon agent memory.
final class PetPathsTests: XCTestCase {

    private var home: URL!
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        home = tmp.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testDefaultRootsAreDualAndSeparate() {
        let env: [String: String] = [:]
        let packages = PetPaths.packageRoots(home: home, env: env)
        let agents = PetPaths.agentMemoryRoot(home: home, env: env)

        XCTAssertTrue(packages.contains(where: {
            $0.path.hasSuffix(".codex/pets") || $0.lastPathComponent == "pets"
        }))
        XCTAssertTrue(agents.path.hasSuffix(".shannon/pets") || agents.path.contains("Home/.shannon/pets"))
        XCTAssertFalse(PetPaths.isAgentMemoryRoot(packages[0], home: home, env: env))
        XCTAssertTrue(PetPaths.isAgentMemoryRoot(agents, home: home, env: env))
        // Memory never appears in package search.
        let filtered = PetPaths.packageRootsExcludingMemory(home: home, env: env)
        XCTAssertFalse(filtered.contains(where: { $0.standardizedFileURL == agents.standardizedFileURL }))
    }

    func testUnifiedSHANNON_PETSCoversBothRoles() throws {
        let unified = tmp.appendingPathComponent("unified-pets", isDirectory: true)
        try FileManager.default.createDirectory(at: unified, withIntermediateDirectories: true)
        let packagesSub = unified.appendingPathComponent("packages", isDirectory: true)
        try FileManager.default.createDirectory(at: packagesSub, withIntermediateDirectories: true)

        let env = [PetPaths.envUnified: unified.path]
        let roots = PetPaths.packageRoots(home: home, env: env)
        XCTAssertTrue(roots.contains(where: { $0.standardizedFileURL == packagesSub.standardizedFileURL }))
        XCTAssertTrue(roots.contains(where: { $0.standardizedFileURL == unified.standardizedFileURL }))

        let agents = PetPaths.agentMemoryRoot(home: home, env: env)
        XCTAssertEqual(
            agents.standardizedFileURL.path,
            unified.appendingPathComponent("agents", isDirectory: true).standardizedFileURL.path
        )
    }

    func testPackagesOnlyOverrideStillWorks() {
        let custom = tmp.appendingPathComponent("custom-codex", isDirectory: true)
        let env = [PetPaths.envPackages: custom.path]
        let roots = PetPaths.packageRoots(home: home, env: env)
        XCTAssertEqual(roots.first?.standardizedFileURL, custom.standardizedFileURL)
        // Agents stay under shannon default when SHANNON_PETS unset.
        let agents = PetPaths.agentMemoryRoot(home: home, env: env)
        XCTAssertTrue(agents.path.contains(".shannon"))
    }

    func testAgentsOnlyOverride() {
        let custom = tmp.appendingPathComponent("custom-agents", isDirectory: true)
        let env = [PetPaths.envAgents: custom.path]
        XCTAssertEqual(
            PetPaths.agentMemoryRoot(home: home, env: env).standardizedFileURL,
            custom.standardizedFileURL
        )
    }

    func testResolveUsesUnifiedPackagesPath() throws {
        let unified = tmp.appendingPathComponent("pets-home", isDirectory: true)
        let petDir = unified.appendingPathComponent("shannon", isDirectory: true)
        try FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "id": "shannon",
            "displayName": "Shannon",
            "spriteVersionNumber": 2,
            "spritesheetPath": "spritesheet.webp",
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: petDir.appendingPathComponent("pet.json"))
        try Data("RIFF....WEBP".utf8)
            .write(to: petDir.appendingPathComponent("spritesheet.webp"))

        let env = [PetPaths.envUnified: unified.path]
        let pkg = PetPackageResolver.resolve(
            petId: "shannon",
            requireV2: true,
            home: home,
            env: env
        )
        XCTAssertFalse(pkg.useProcedural)
        XCTAssertEqual(pkg.displayName, "Shannon")
        XCTAssertEqual(
            pkg.root?.standardizedFileURL,
            petDir.standardizedFileURL
        )

        // Agent memory is under unified/agents — not the package dir.
        let mem = PetPaths.agentMemoryRoot(home: home, env: env)
        XCTAssertEqual(mem.lastPathComponent, "agents")
        XCTAssertNotEqual(mem.standardizedFileURL, unified.standardizedFileURL)
    }

    func testPetBootstrapPetsRootFollowsPetPaths() {
        // Without env, petsRoot is under .shannon/pets.
        let root = PetBootstrap.petsRoot
        XCTAssertTrue(root.path.contains("pets"))
        XCTAssertEqual(root.standardizedFileURL, PetPaths.agentMemoryRoot().standardizedFileURL)
    }

    func testSnapshotKeys() {
        let snap = PetPaths.snapshot(home: home, env: [:])
        XCTAssertNotNil(snap["packages"])
        XCTAssertNotNil(snap["agents"])
        XCTAssertNotNil(snap["shannonHome"])
        XCTAssertEqual(snap["unified"], "")
    }

    /// Real machine: ~/.codex/pets is the default package root and is searchable.
    func testRealCodexPetsOnSearchPath() {
        let roots = PetPaths.packageRoots()
        let codex = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets")
        XCTAssertTrue(
            roots.contains(where: { $0.standardizedFileURL == codex.standardizedFileURL }),
            "default package roots must include ~/.codex/pets"
        )
    }
}
