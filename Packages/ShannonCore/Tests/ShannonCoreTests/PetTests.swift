import XCTest
@testable import ShannonCore

final class PetTests: XCTestCase {

    // MARK: - Mood derivation

    func testCalmWhenLowEntropyNoActivity() {
        XCTAssertEqual(PetMood.from(entropy: 0.1, errorRate: 0, idleSeconds: 0, recentInteraction: false), .calm)
    }

    func testCuriousAtModerateEntropy() {
        XCTAssertEqual(PetMood.from(entropy: 0.45, errorRate: 0, idleSeconds: 0, recentInteraction: false), .curious)
    }

    func testExcitedAtHighEntropy() {
        XCTAssertEqual(PetMood.from(entropy: 0.8, errorRate: 0, idleSeconds: 0, recentInteraction: false), .excited)
    }

    func testWorriedWhenHighErrorRate() {
        XCTAssertEqual(PetMood.from(entropy: 0.5, errorRate: 0.15, idleSeconds: 0, recentInteraction: false), .worried)
    }

    func testSleepingWhenLongIdle() {
        XCTAssertEqual(PetMood.from(entropy: 0, errorRate: 0, idleSeconds: 2_000, recentInteraction: false), .sleeping)
    }

    func testPlayfulOverridesAll() {
        // recentInteraction=true wins even over max error rate and max idle
        XCTAssertEqual(PetMood.from(entropy: 0, errorRate: 0.99, idleSeconds: 9_999, recentInteraction: true), .playful)
    }

    // MARK: - XP and leveling

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
    func testXPThresholdIsLinear() {
        XCTAssertEqual(ShannonPet.xpThreshold(forLevel: 1),  100)
        XCTAssertEqual(ShannonPet.xpThreshold(forLevel: 5),  500)
        XCTAssertEqual(ShannonPet.xpThreshold(forLevel: 10), 1_000)
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
    func testXPFractionAtHalfLevel() {
        // threshold(level 2) = 200; xp = 100 → fraction = 0.5
        let pet = ShannonPet(level: 2, xp: 100)
        XCTAssertEqual(pet.xpFraction, 0.5, accuracy: 0.001)
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
    func testXPFractionCappedAtLevel99() {
        let pet = ShannonPet(level: 99, xp: 0)
        XCTAssertEqual(pet.xpFraction,    1.0)
        XCTAssertEqual(pet.xpToNextLevel, 0)
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
    func testXPToNextLevelIsThresholdMinusXP() {
        let pet = ShannonPet(level: 3, xp: 75)
        XCTAssertEqual(pet.xpToNextLevel, 225) // threshold(3)=300, 300-75=225
    }

    // MARK: - CloudKit round-trip

    func testPetCloudRecordRoundTrips() throws {
        let rec = PetCloudRecord(
            id: "pet-abc", name: "Shan", species: "orb",
            level: 5, xp: 230, avatarSeed: 0xDEAD_BEEF,
            lastInteracted: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(try rec.reencoded(), rec)
    }

    func testPetCloudRecordMissingFieldThrows() {
        var fields = PetCloudRecord(
            id: "p1", name: "n", species: "orb",
            level: 1, xp: 0, avatarSeed: 0, lastInteracted: Date()
        ).cloudFields
        fields.removeValue(forKey: "level")
        XCTAssertThrowsError(try PetCloudRecord(cloudFields: fields))
    }

    func testPetCloudRecordUnknownSpeciesPreserved() throws {
        // species is a plain String in the record, unknown values pass through
        let rec = PetCloudRecord(
            id: "p2", name: "n", species: "dragon",
            level: 1, xp: 0, avatarSeed: 1,
            lastInteracted: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(try rec.reencoded(), rec)
    }

    // MARK: - Avatar descriptor determinism

    func testSameSeedGivesSameParams() {
        let seed: UInt64 = 0x1234_5678_90AB_CDEF
        XCTAssertEqual(PetAvatarDescriptor.params(for: seed),
                       PetAvatarDescriptor.params(for: seed))
    }

    func testDifferentSeedsGiveDifferentParams() {
        XCTAssertNotEqual(PetAvatarDescriptor.params(for: 1),
                          PetAvatarDescriptor.params(for: 2))
    }

    func testParamsHashIsDeterministic() {
        let seed: UInt64 = 0xCAFE_BABE
        XCTAssertEqual(PetAvatarDescriptor.paramsHash(seed: seed),
                       PetAvatarDescriptor.paramsHash(seed: seed))
    }

    func testBodyShapeAndEyeStyleInRange() {
        for seed: UInt64 in [0, 1, 999, 0xFFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF] {
            let p = PetAvatarDescriptor.params(for: seed)
            XCTAssertTrue((0...3).contains(p.bodyShape),    "bodyShape out of range for seed \(seed)")
            XCTAssertTrue((0...3).contains(p.eyeStyle),     "eyeStyle out of range for seed \(seed)")
            XCTAssertTrue((0...3).contains(p.particleCount),"particleCount out of range for seed \(seed)")
            XCTAssertTrue(p.hue >= 0 && p.hue <= 1,         "hue out of range for seed \(seed)")
            XCTAssertTrue(p.saturation >= 0.6 && p.saturation <= 1.0, "saturation out of range")
        }
    }

    // MARK: - Memory append / read round-trip

    func testMemoryStoreAppendAndReadback() async throws {
        let id = "test-pet-\(UUID().uuidString)"
        let store = PetMemoryStore(petID: id)
        let entry = PetMemoryEntry(kind: .interaction, text: "a unit-test entry")

        await store.append(entry: entry)
        // Wait for the 2-second debounce to flush.
        try await Task.sleep(nanoseconds: 2_200_000_000)

        let recent = await store.recentEntries(limit: 5)
        XCTAssertTrue(recent.contains { $0.text == entry.text },
                      "Expected to find the appended entry in readback")

        // Cleanup
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shannon/pets/\(id)")
        try? FileManager.default.removeItem(at: dir)
    }

    func testMemoryStoreMultipleEntriesOrdered() async throws {
        let id = "test-pet-order-\(UUID().uuidString)"
        let store = PetMemoryStore(petID: id)

        await store.append(entry: PetMemoryEntry(kind: .interaction, text: "first"))
        try await Task.sleep(nanoseconds: 2_200_000_000)
        await store.append(entry: PetMemoryEntry(kind: .interaction, text: "second"))
        try await Task.sleep(nanoseconds: 2_200_000_000)

        let recent = await store.recentEntries(limit: 10)
        // recentEntries returns newest first
        XCTAssertEqual(recent.first?.text, "second")

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shannon/pets/\(id)")
        try? FileManager.default.removeItem(at: dir)
    }
}
