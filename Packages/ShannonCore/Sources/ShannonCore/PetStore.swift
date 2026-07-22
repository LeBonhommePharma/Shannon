import Foundation

// MARK: - Notifications

public extension Notification.Name {
    /// Posted on the main thread when the pet levels up.
    /// `userInfo["level"]` → new level (Int), `userInfo["petID"]` → pet id (String).
    static let petLevelUp = Notification.Name("ShannonPetLevelUp")
}

// MARK: - PetCloudRecord

/// CloudKit serialisation for `ShannonPet`.
/// Synced to `CKContainer.default().privateCloudDatabase` ONLY — never public.
/// Excludes `memoryURL` (synced via iCloud Drive) and `mood` (recomputed).
/// Conflict resolution: the record with the higher `level` wins.
public struct PetCloudRecord: CloudSyncable {
    public var id: String
    public var name: String
    public var species: String
    public var level: Int
    public var xp: Int
    public var avatarSeed: UInt64
    public var lastInteracted: Date
    public var updatedAt: Date

    public init(id: String, name: String, species: String,
                level: Int, xp: Int, avatarSeed: UInt64,
                lastInteracted: Date, updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.species = species
        self.level = level; self.xp = xp; self.avatarSeed = avatarSeed
        self.lastInteracted = lastInteracted; self.updatedAt = updatedAt
    }

    public static let recordType = "ShannonPet"
    public var recordName: String { "pet-\(id)" }

    enum Field {
        static let petID         = "petID"
        static let name          = "name"
        static let species       = "species"
        static let level         = "level"
        static let xp            = "xp"
        static let avatarSeed    = "avatarSeed"
        static let lastInteracted = "lastInteracted"
    }

    public var cloudFields: CloudFields {
        [
            Field.petID:          .string(id),
            Field.name:           .string(name),
            Field.species:        .string(species),
            Field.level:          .int(level),
            Field.xp:             .int(xp),
            Field.avatarSeed:     .string(String(avatarSeed)),
            Field.lastInteracted: .date(lastInteracted),
            CloudKeys.updatedAt:  .date(updatedAt),
        ]
    }

    public init(cloudFields f: CloudFields) throws {
        self.init(
            id:             try f.string(Field.petID),
            name:           try f.string(Field.name),
            species:        try f.string(Field.species),
            level:          try f.int(Field.level),
            xp:             try f.int(Field.xp),
            avatarSeed:     UInt64(try f.string(Field.avatarSeed)) ?? 0,
            lastInteracted: try f.date(Field.lastInteracted),
            updatedAt:      try f.date(CloudKeys.updatedAt)
        )
    }
}

// MARK: - PetStore

#if canImport(Observation)
import Observation

/// JSON snapshot written to disk — excludes transient `mood`.
private struct PetSnapshot: Codable {
    var id: String
    var name: String
    var species: String
    var level: Int
    var xp: Int
    var avatarSeed: UInt64
    var lastInteracted: Date
}

/// Thread-safe, observable backing store for the Shannon pet.
///
/// Persistence: `~/.shannon/pets/{id}/pet.json` with `FileProtection.complete`.
/// CloudKit: private DB only — see `PetCloudRecord`.
/// On sign-out / device wipe: call `deleteAll()`.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
@MainActor
@Observable
public final class PetStore {
    public static let shared = PetStore()

    public private(set) var pet: ShannonPet
    private var lastUserInteraction: Date = .distantPast
    private var saveTask: Task<Void, Never>?

    private init() { pet = PetStore.load() ?? ShannonPet() }

    // MARK: Mood

    /// Re-derive mood from current agent-state metrics.
    public func computeMood(entropy: Double, errorRate: Double, idleSeconds: Double) {
        let recent = Date().timeIntervalSince(lastUserInteraction) < 60
        pet.mood = PetMood.from(
            entropy: entropy, errorRate: errorRate,
            idleSeconds: idleSeconds, recentInteraction: recent
        )
    }

    // MARK: XP

    /// Award XP and level up at threshold (100 XP / level, capped at Lv 99).
    public func awardXP(_ amount: Int) {
        guard pet.level < 99 else { return }
        pet.xp += amount
        while pet.xp >= ShannonPet.xpThreshold(forLevel: pet.level), pet.level < 99 {
            pet.xp -= ShannonPet.xpThreshold(forLevel: pet.level)
            pet.level += 1
            NotificationCenter.default.post(
                name: .petLevelUp,
                object: nil,
                userInfo: ["level": pet.level, "petID": pet.id]
            )
        }
        markInteracted()
        scheduleSave()
    }

    public func markInteracted() {
        lastUserInteraction = Date()
        pet.lastInteracted  = Date()
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.save() }
        }
    }

    private func save() {
        let snap = PetSnapshot(
            id: pet.id, name: pet.name, species: pet.species.rawValue,
            level: pet.level, xp: pet.xp,
            avatarSeed: pet.avatarSeed, lastInteracted: pet.lastInteracted
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(
            at: pet.stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: pet.stateURL, options: [.atomic, .completeFileProtection])
    }

    private static func load() -> ShannonPet? {
        let probe = ShannonPet()
        guard let data = try? Data(contentsOf: probe.stateURL),
              let snap = try? JSONDecoder().decode(PetSnapshot.self, from: data)
        else { return nil }
        return ShannonPet(
            id: snap.id, name: snap.name,
            species: PetSpecies(rawValue: snap.species) ?? .orb,
            level: snap.level, xp: snap.xp,
            avatarSeed: snap.avatarSeed, lastInteracted: snap.lastInteracted
        )
    }

    // MARK: CloudKit helpers

    public var cloudRecord: PetCloudRecord {
        PetCloudRecord(id: pet.id, name: pet.name, species: pet.species.rawValue,
                       level: pet.level, xp: pet.xp, avatarSeed: pet.avatarSeed,
                       lastInteracted: pet.lastInteracted)
    }

    /// Merge an incoming cloud record: higher level wins.
    public func mergeFromCloud(_ record: PetCloudRecord) {
        guard record.level > pet.level else { return }
        pet.name = record.name
        pet.level = record.level
        pet.xp = record.xp
        pet.avatarSeed = record.avatarSeed
        pet.lastInteracted = record.lastInteracted
        scheduleSave()
    }

    // MARK: Device wipe / sign-out

    /// Remove all pet data from disk. Call on sign-out or device wipe.
    public func deleteAll() {
        #if os(macOS)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shannon/pets")
        #else
        let root = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("shannon/pets")
        #endif
        try? FileManager.default.removeItem(at: root)
    }
}

#endif // canImport(Observation)
