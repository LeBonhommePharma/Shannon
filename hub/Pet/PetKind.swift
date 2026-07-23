// PetKind.swift — Shannon Hub companion pets
//
// One drawable character per agent. The mapping from an agent id to a pet is
// owned by hub/agent_identity.py (`AgentIdentity.pet`) and mirrored into
// AgentHubApp.swift's `AgentIdentity.petName`; this enum is the drawing side of
// that same contract, keyed off the pet *name* rather than the agent id so the
// two stay decoupled.
//
// Only the seven designed pets exist here. Agents whose pet has no artwork yet
// (parrot, ant, tortoise, gecko) fail `init?(petName:)` and fall back to their
// SF Symbol glyph — a missing drawing must never silently render as the wrong
// animal.

import SwiftUI

enum PetKind: String, CaseIterable, Hashable {
    case owl, raven, fox, dolphin, wolf, beaver, gear

    /// Maps `AgentIdentity.petName` onto a drawable character.
    /// Returns nil for pets that have no artwork.
    init?(petName: String) {
        guard let k = PetKind(rawValue: petName.lowercased()) else { return nil }
        self = k
    }

    /// Silhouette-level description, used for the accessibility label.
    var accessibilityNoun: String { rawValue }
}

// MARK: - Palette

/// Three fills plus an ink. Two-to-three colours per pet is a hard budget: at
/// 32pt a fourth fill reads as noise, not detail.
struct PetPalette {
    let primary:   Color   // body
    let secondary: Color   // belly / muzzle / underside
    let accent:    Color   // eye sclera, or the warm highlight
    let ink:       Color   // pupils and the 1.5pt outline

    init(primary: UInt32, secondary: UInt32, accent: UInt32, ink: UInt32) {
        self.primary   = Color(hex: primary)
        self.secondary = Color(hex: secondary)
        self.accent    = Color(hex: accent)
        self.ink       = Color(hex: ink)
    }
}

extension PetKind {
    /// Each palette is hand-derived from the owning agent's `color_rgb` in
    /// agent_identity.py, pulled toward a warmer, more saturated reading so the
    /// characters sit on the #FAF8F5 card without going muddy or grey.
    ///
    /// The one deliberate exception is the wolf: Dispatch's brown reads as mud
    /// at this size, so the wolf goes cool grey-blue and takes its warmth from
    /// an amber eye instead.
    var palette: PetPalette {
        switch self {
        case .owl:      // science  (1.00, 0.72, 0.10) — ochre, cream, amber eye
            return PetPalette(primary: 0xC8862A, secondary: 0xF2DCA8,
                              accent: 0xFFC531, ink: 0x3A2410)
        case .raven:    // grok_build (0.68, 0.28, 0.98) — near-black w/ violet sheen
            return PetPalette(primary: 0x1E1B2E, secondary: 0x5B4A9E,
                              accent: 0xE8D24A, ink: 0x110F1C)
        case .fox:      // claude_code (1.00, 0.50, 0.08) — rust + cream
            return PetPalette(primary: 0xD2601A, secondary: 0xF7E3C8,
                              accent: 0xFFB347, ink: 0x3B1D08)
        case .dolphin:  // codex (0.30, 0.55, 1.00) — teal, pale belly
            return PetPalette(primary: 0x1F7A8C, secondary: 0xD9EEF2,
                              accent: 0x7FD4E0, ink: 0x0C2E36)
        case .wolf:     // dispatch (0.72, 0.50, 0.28) — cool grey-blue, amber eye
            return PetPalette(primary: 0x5A6E88, secondary: 0xE3E7EF,
                              accent: 0xF2B441, ink: 0x1E2836)
        case .beaver:   // cowork (0.20, 0.85, 0.45) — warm brown, ivory teeth
            return PetPalette(primary: 0x8B5A2B, secondary: 0xFFF6E2,
                              accent: 0x3FBF6A, ink: 0x2E1A0B)
        case .gear:     // dataset_runner (0.15, 0.70, 0.80) — teal + amber spark
            return PetPalette(primary: 0x1FA6B8, secondary: 0x0E5F6B,
                              accent: 0xFFC531, ink: 0x08343B)
        }
    }
}

// MARK: - Hex helper

extension Color {
    /// 0xRRGGBB in sRGB. Local to the pet system so it does not collide with
    /// the hub's own `HubRGBA(hex:)`.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF)         / 255,
                  opacity: 1)
    }
}
