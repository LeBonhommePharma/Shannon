import Foundation

// MARK: - PetSpecies

/// The visual species of a Shannon pet — determines the default shape
/// vocabulary in `PetAvatarDescriptor`.
public enum PetSpecies: String, Codable, Sendable, CaseIterable {
    case sprite   // humanoid silhouette with wings
    case orb      // floating sphere
    case crystal  // geometric polyhedron
    case wisp     // drifting flame tendril
}

// MARK: - PetMood

/// The pet's current emotional state, always derived from live agent metrics.
///
/// `PetMood` is never persisted — it is recomputed on every `AgentState` update
/// so it reflects real-time conditions and never shows stale data.
public enum PetMood: String, Codable, Sendable, CaseIterable {
    case calm, curious, excited, worried, sleeping, playful

    /// Derive mood from the live metrics Shannon already computes.
    /// `recentInteraction` takes precedence so a tap always gets a playful
    /// response, regardless of background entropy.
    public static func from(
        entropy: Double,
        errorRate: Double,
        idleSeconds: Double,
        recentInteraction: Bool
    ) -> PetMood {
        if recentInteraction   { return .playful }
        if idleSeconds > 1_800 { return .sleeping }
        if errorRate   > 0.10  { return .worried }
        if entropy     > 0.6   { return .excited }
        if entropy     > 0.3   { return .curious }
        return .calm
    }

    /// Semantic color role for each mood. Resolved by each platform against
    /// ShannonTheme so this enum stays SwiftUI-free.
    public var colorRole: MoodColorRole {
        switch self {
        case .calm:     return .blue
        case .curious:  return .teal
        case .excited:  return .amber
        case .worried:  return .red
        case .sleeping: return .gray
        case .playful:  return .purple
        }
    }

    /// Human-readable label for UI display.
    public var label: String {
        switch self {
        case .calm:     return "calm"
        case .curious:  return "curious"
        case .excited:  return "excited!"
        case .worried:  return "worried…"
        case .sleeping: return "sleeping"
        case .playful:  return "playful"
        }
    }

    /// SF Symbol name for the mood icon in complications and notifications.
    public var symbol: String {
        switch self {
        case .calm:     return "circle.fill"
        case .curious:  return "magnifyingglass.circle.fill"
        case .excited:  return "star.fill"
        case .worried:  return "exclamationmark.triangle.fill"
        case .sleeping: return "moon.zzz.fill"
        case .playful:  return "heart.fill"
        }
    }
}

/// Lightweight colour role resolved per-platform to the correct semantic Color
/// without introducing a SwiftUI dependency into ShannonCore.
public enum MoodColorRole: String, Sendable {
    case blue, teal, amber, red, gray, purple
}

// MARK: - ShannonPet

#if canImport(Observation)
import Observation

/// The first-class Shannon companion — one per user (or agent identity).
///
/// Stored to `~/.shannon/pets/{id}/pet.json` with `FileProtection.complete`.
/// CloudKit syncs via `PetCloudRecord` to the **private** database only.
/// `mood` is never persisted: recomputed from live `AgentState` each update.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
@Observable
public final class ShannonPet: @unchecked Sendable {
    // MARK: Persistent identity

    public var id: String
    public var name: String
    public var species: PetSpecies
    public var level: Int           // 1–99
    public var xp: Int
    /// Deterministic seed for the procedural avatar. Same seed → same shape on
    /// every device — no image assets required.
    public var avatarSeed: UInt64
    public var lastInteracted: Date

    // MARK: Computed / transient

    /// Recomputed from live AgentState; never stored.
    public var mood: PetMood = .calm

    public var isAsleep: Bool { mood == .sleeping }

    // MARK: File paths

    /// Diary file. Append-only; coexists with the Python pet_manager.py layout.
    public var memoryURL: URL

    /// Pet state JSON. Protected by `FileProtection.complete`.
    public var stateURL: URL

    public init(
        id: String = UUID().uuidString,
        name: String = "Shan",
        species: PetSpecies = .orb,
        level: Int = 1,
        xp: Int = 0,
        avatarSeed: UInt64 = UInt64.random(in: 0 ..< .max),
        lastInteracted: Date = Date()
    ) {
        self.id            = id
        self.name          = name
        self.species       = species
        self.level         = level
        self.xp            = xp
        self.avatarSeed    = avatarSeed
        self.lastInteracted = lastInteracted
        #if os(macOS)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shannon/pets/\(id)", isDirectory: true)
        #else
        let dir = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("shannon/pets/\(id)", isDirectory: true)
        #endif
        self.memoryURL = dir.appendingPathComponent("memory.md")
        self.stateURL  = dir.appendingPathComponent("pet.json")
    }

    // MARK: XP

    /// XP required to reach the given level (100 XP per level, flat).
    public static func xpThreshold(forLevel level: Int) -> Int { level * 100 }

    /// Remaining XP to the next level; zero when capped at 99.
    public var xpToNextLevel: Int {
        guard level < 99 else { return 0 }
        return Self.xpThreshold(forLevel: level) - xp
    }

    /// Progress 0.0…1.0 within the current level, for XP bars.
    public var xpFraction: Double {
        guard level < 99 else { return 1 }
        return min(Double(xp) / Double(Self.xpThreshold(forLevel: level)), 1)
    }
}

#endif // canImport(Observation)
