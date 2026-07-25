// PetCompanion.swift — per-agent companion creatures for the Shannon pill.
//
// This is the third life of the pets idea, and the first one that is wired to
// evidence rather than to a file that nobody clears.
//
//   Gen 1  hub/pet_manager.py + ~/.shannon/pets/{agent}/ — durable per-agent
//          identity: memory.md, history.jsonl, config.json, state.json.
//   Gen 2  ShannonCore.ShannonPet / PetStore — one *global* pet with species,
//          XP and levels, synced to CloudKit. `PetPillView` bound to
//          `PetStore.shared`, whose `mood` nobody ever recomputed, so it sat on
//          its hardcoded `.calm` default forever. It was never instantiated.
//   Gen 3  hub/Pet/* — seven Canvas-drawn characters with four moods derived
//          from real card signals. It only ever reached the hub app.
//
// What lands here is Gen 3's art and honesty, Gen 1's persistence, and none of
// Gen 2's XP: see `CompanionBond` for why tenure replaced levels.
//
// THE ONE RULE. `~/.shannon/pets/*/state.json` is an *observation*. ⌘D writes
// "status": "active" from whichever macOS app happened to be frontmost, and
// nothing ever clears it — there are records on this machine claiming "active"
// from two days ago. A pet must never launder that into a claim of work.
// `CompanionMood.alert` is therefore reachable only when
// `AgentPresence.canBeBusy` is true, i.e. only from live gate telemetry.
// `CompanionMoodTests` pins this over the full presence × status matrix.

import Foundation
#if canImport(SwiftUI)
import SwiftUI
import ShannonTheme
#endif

// MARK: - CompanionKind

/// One drawable character per agent, keyed off the *pet name* rather than the
/// agent id so the drawing side and the identity side stay decoupled.
///
/// Only the seven designed characters exist. Agents whose pet has no artwork
/// (parrot, tortoise, gecko, cat, ladybug) fail `init?(petName:)` and fall back
/// to `AgentStyle.petSymbol`. That fallback is deliberate and load-bearing: a
/// missing drawing must never silently render as the wrong animal.
public enum CompanionKind: String, CaseIterable, Hashable, Sendable {
    case owl, raven, fox, dolphin, wolf, beaver, gear

    /// Maps `AgentStyle.pet` onto a drawable character, or nil when there is
    /// no artwork for it.
    public init?(petName: String) {
        guard let k = CompanionKind(rawValue:
            petName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else { return nil }
        self = k
    }

    /// Silhouette-level noun, used for the accessibility label.
    public var accessibilityNoun: String { rawValue }

    /// The companion for a known agent id, or nil when that agent's pet has no
    /// artwork.
    public static func forAgent(id: String) -> CompanionKind? {
        CompanionKind(petName: AgentStyleCatalog.style(for: id).pet)
    }
}

// MARK: - CompanionPersonality

/// Per-kind resting rhythm. Every value here is a *resting behaviour*
/// parameter only — it never changes what a pet is, just the tempo it idles at.
/// Consumed analytically by `CompanionMotion`, so it costs no timers and stays
/// phase-locked to the shared clock.
///
/// Recovered from `stash@{0}` (WIP on ec5cc41), where it was written and then
/// never committed.
public struct CompanionPersonality: Sendable, Equatable {
    /// Seconds per idle breathing cycle. Small animals breathe faster.
    public let breathPeriod: Double
    /// 0…1 offset into the breath cycle, so two pets of different kinds are
    /// caught mid-breath at different moments.
    public let breathPhase: Double
    /// Seconds between blinks.
    public let blinkPeriod: Double
    /// A second blink close behind the first — reads as a nervous or busy tic.
    public let doubleBlink: Bool
    /// Design-space horizontal drift while idle. 0 = dead still.
    public let swayAmp: Double
    /// Eyelid aperture in `alert`. Higher = a wider, more startled stare.
    public let alertEyeWiden: Double

    public init(breathPeriod: Double, breathPhase: Double, blinkPeriod: Double,
                doubleBlink: Bool, swayAmp: Double, alertEyeWiden: Double) {
        self.breathPeriod  = breathPeriod
        self.breathPhase   = breathPhase
        self.blinkPeriod   = blinkPeriod
        self.doubleBlink   = doubleBlink
        self.swayAmp       = swayAmp
        self.alertEyeWiden = alertEyeWiden
    }
}

public extension CompanionKind {
    /// Hand-tuned so each animal reads as itself at rest: the owl is near
    /// motionless and slow to blink, the raven is twitchy, the beaver fidgets.
    var personality: CompanionPersonality {
        switch self {
        case .owl:      // still, deliberate, a rare wide blink
            return .init(breathPeriod: 2.6, breathPhase: 0.00, blinkPeriod: 6.4,
                         doubleBlink: false, swayAmp: 0.10, alertEyeWiden: 1.45)
        case .raven:    // quick, nervous, double-blinks
            return .init(breathPeriod: 1.7, breathPhase: 0.15, blinkPeriod: 3.8,
                         doubleBlink: true,  swayAmp: 0.32, alertEyeWiden: 1.30)
        case .fox:      // light and alert on its feet
            return .init(breathPeriod: 1.9, breathPhase: 0.35, blinkPeriod: 4.2,
                         doubleBlink: false, swayAmp: 0.30, alertEyeWiden: 1.35)
        case .dolphin:  // smooth, bobbing, slow single eye
            return .init(breathPeriod: 2.2, breathPhase: 0.55, blinkPeriod: 5.6,
                         doubleBlink: false, swayAmp: 0.42, alertEyeWiden: 1.25)
        case .wolf:     // composed, steady, a hard alert stare
            return .init(breathPeriod: 2.4, breathPhase: 0.70, blinkPeriod: 5.8,
                         doubleBlink: false, swayAmp: 0.14, alertEyeWiden: 1.45)
        case .beaver:   // busy worker, fidgets, blinks in pairs
            return .init(breathPeriod: 2.0, breathPhase: 0.85, blinkPeriod: 4.0,
                         doubleBlink: true,  swayAmp: 0.36, alertEyeWiden: 1.20)
        case .gear:     // machinery — the animator ignores lungs and lids
            return .init(breathPeriod: 2.0, breathPhase: 0.00, blinkPeriod: 5.0,
                         doubleBlink: false, swayAmp: 0.0,  alertEyeWiden: 1.0)
        }
    }
}

// MARK: - CompanionMood

/// What a companion is allowed to say about its agent.
///
/// Each mood maps to a signal we can *prove*, never to decoration:
///
///   wary   → Shannon reports an entropy collapse on this agent's live stream
///   happy  → a human approved one of this agent's asks moments ago (0.4 s)
///   alert  → live gate telemetry says the agent is working, right now
///   sleepy → the agent hung up, or has not been seen in `sleepyAfter`
///   idle   → seen recently, nothing to claim
public enum CompanionMood: String, CaseIterable, Hashable, Sendable {
    case wary, happy, alert, idle, sleepy

    /// How long an agent must go unseen before its companion nods off.
    public static let sleepyAfter: TimeInterval = 300      // 5 min

    /// How long the `happy` bounce runs before falling back to the underlying
    /// mood.
    public static let happyDuration: TimeInterval = 0.4

    /// Shannon's shipping collapse threshold, δ < -3.2 bits (see CLAUDE.md).
    public static let defaultCollapseThreshold: Double = -3.2

    /// One-word label for the board's mood column.
    public var label: String {
        switch self {
        case .wary:   return "uneasy"
        case .happy:  return "celebrating"
        case .alert:  return "focused"
        case .idle:   return "resting"
        case .sleepy: return "sleeping"
        }
    }

    /// True only for the mood that asserts the agent is doing work. Exactly one
    /// mood may do that, and only from live telemetry.
    public var claimsWork: Bool { self == .alert }

    /// Resolve a mood from evidence.
    ///
    /// - Parameters:
    ///   - presence: how much we actually know. `.observed` is a statement
    ///     about window focus, never about work.
    ///   - status: the agent's reported run status.
    ///   - secondsSinceSeen: age of the freshest evidence for this agent.
    ///   - secondsSinceApproval: age of the last human approval, nil if none.
    ///   - entropyDelta: live z-scored entropy delta in bits, nil when we have
    ///     no current distribution for this agent.
    ///   - collapseThreshold: δ at or below which the companion goes `wary`.
    ///
    /// Precedence is deliberate:
    ///
    ///  1. `wary` outranks everything. A companion must not bounce happily
    ///     through an entropy collapse — that is the exact "all fine" lie
    ///     Shannon exists to catch. It requires `.live` presence, because a
    ///     collapse is a claim about a token stream we are currently reading;
    ///     attributing one to an app we merely *saw* would be fabrication.
    ///  2. `happy` — the approval itself is the evidence, so it stands whatever
    ///     the presence, and it is time-boxed to 0.4 s.
    ///  3. `alert` — gated on `presence.canBeBusy`, so only live telemetry can
    ///     ever light a companion up.
    ///  4. `sleepy` / `idle` — honest fallbacks.
    public static func resolve(
        presence: AgentPresence,
        status: AgentRunStatus,
        secondsSinceSeen: TimeInterval,
        secondsSinceApproval: TimeInterval? = nil,
        entropyDelta: Double? = nil,
        collapseThreshold: Double = CompanionMood.defaultCollapseThreshold
    ) -> CompanionMood {
        if presence == .live, let delta = entropyDelta, delta <= collapseThreshold {
            return .wary
        }
        if let since = secondsSinceApproval, since >= 0, since <= happyDuration {
            return .happy
        }
        // The load-bearing line: observation may never become a claim of work.
        if presence.canBeBusy, status.isBusy {
            return .alert
        }
        if presence == .offline || secondsSinceSeen > sleepyAfter {
            return .sleepy
        }
        return .idle
    }

    /// Convenience over a live snapshot.
    public static func resolve(
        for agent: AgentActivitySnapshot,
        now: Date = Date(),
        approvedAt: Date? = nil,
        entropyDelta: Double? = nil,
        collapseThreshold: Double = CompanionMood.defaultCollapseThreshold
    ) -> CompanionMood {
        resolve(
            presence: agent.presence,
            status: agent.status,
            secondsSinceSeen: max(0, now.timeIntervalSince(agent.updatedAt)),
            secondsSinceApproval: approvedAt.map { max(0, now.timeIntervalSince($0)) },
            entropyDelta: entropyDelta,
            collapseThreshold: collapseThreshold
        )
    }
}

// MARK: - CompanionBond

/// How much history this agent's pet has actually accumulated.
///
/// Gen 2 shipped XP and levels (100 XP/level, capped at 99) awarded for nodding
/// at an AirPod. That is a number about the *user*, dressed as a number about
/// the agent, and it made the pet feel earned when nothing had been. Tenure
/// replaces it: `historyCount` is a count of real lines in the pet's
/// `history.jsonl`, it only ever goes up, and no gesture can inflate it.
public enum CompanionBond: Int, CaseIterable, Comparable, Sendable {
    case fresh, familiar, seasoned, veteran

    public static func < (l: CompanionBond, r: CompanionBond) -> Bool {
        l.rawValue < r.rawValue
    }

    /// Thresholds are turn counts, not points.
    public static func from(historyCount: Int) -> CompanionBond {
        switch historyCount {
        case ..<10:    return .fresh
        case ..<100:   return .familiar
        case ..<1_000: return .seasoned
        default:       return .veteran
        }
    }

    public var label: String {
        switch self {
        case .fresh:    return "new"
        case .familiar: return "familiar"
        case .seasoned: return "seasoned"
        case .veteran:  return "veteran"
        }
    }
}

// MARK: - CompanionFrame

/// One resolved animation frame. All offsets are in the pet's 32×32 design
/// space; `CompanionArt` scales them to the view's actual size.
public struct CompanionFrame: Sendable, Equatable {
    /// Body scale, ~0.95…1.02. Breathing.
    public var breath: Double = 1
    /// Eyelid aperture. 0 = shut, 1 = resting, >1 = widened in alert.
    public var eyeOpen: Double = 1
    /// Vertical offset, negative is up. Drives the happy bounce.
    public var yOffset: Double = 0
    /// Horizontal drift in design units — the per-kind idle sway.
    public var sway: Double = 0
    /// Forward lean, -1…1. Shears the body; negative is a flinch backwards.
    public var lean: Double = 0
    /// How far the head hangs, in design units. Sleepy only.
    public var headDroop: Double = 0
    /// Gear rotation in radians.
    public var spin: Double = 0
    /// Sparkle burst envelope, 0…1. The gear's happy state.
    public var sparkle: Double = 0

    public init() {}
}

// MARK: - CompanionMotion

/// Continuous motion computed analytically from a wall clock rather than held
/// in `@State`. Every companion on the board therefore stays phase-locked to
/// the same clock, costs no timers, and a row that scrolls out of view and back
/// does not restart mid-breath.
///
/// Pure and synchronous so the curves are unit-testable without a view.
public enum CompanionMotion {

    /// Resolve the frame for a companion at time `t` (seconds, monotonic).
    ///
    /// - Parameter happyElapsed: seconds since the approval that triggered
    ///   `happy`. The one genuinely stateful input; the caller owns the instant.
    public static func frame(kind: CompanionKind,
                             mood: CompanionMood,
                             t: Double,
                             happyElapsed: Double = 0) -> CompanionFrame {
        let p = kind.personality
        var f = CompanionFrame()

        switch mood {
        case .idle:
            // Breathing at the kind's own tempo and phase, so a board of pets
            // no longer rises and falls as one body.
            f.breath  = 0.975 + 0.025 * sin(2 * .pi * (t / p.breathPeriod + p.breathPhase))
            f.eyeOpen = blink(t: t, period: p.blinkPeriod,
                              phase: p.breathPhase, double: p.doubleBlink)
            // A slow lateral sway, offset from the breath, so idle reads as
            // alive rather than as a mechanical pulse.
            f.sway = p.swayAmp * sin(2 * .pi * (t / (p.breathPeriod * 2.3) + p.breathPhase))

        case .alert:
            // Tighter, shallower breath — attention, not exertion.
            f.breath  = 0.99 + 0.01 * sin(2 * .pi * t / max(0.4, p.breathPeriod * 0.35))
            f.eyeOpen = p.alertEyeWiden
            f.lean    = 1
            f.yOffset = -0.5

        case .wary:
            // Eyes locked open — no blink at all — a fast shallow breath and a
            // flinch backwards. Reads as "something is wrong", not "busy".
            f.breath  = 0.985 + 0.008 * sin(2 * .pi * t / 0.55)
            f.eyeOpen = p.alertEyeWiden * 1.12
            f.lean    = -0.55
            // A fine tremble, an order of magnitude faster than any sway.
            f.sway    = 0.22 * sin(2 * .pi * t / 0.13)
            f.yOffset = -0.2

        case .happy:
            let u = min(max(happyElapsed / CompanionMood.happyDuration, 0), 1)
            // Up 4pt and back down.
            f.yOffset = -4 * sin(.pi * u)
            f.breath  = 1 + 0.02 * sin(.pi * u)
            f.eyeOpen = 1.15

        case .sleepy:
            // Slower, deeper breath; lids at a quarter; head hangs 3pt.
            f.breath    = 0.955 + 0.02 * sin(2 * .pi * t / 3.4)
            f.eyeOpen   = 0.22
            f.headDroop = 3
        }

        if kind == .gear {
            f.spin    = gearSpin(mood: mood, t: t)
            f.sparkle = mood == .happy ? sparkleEnvelope(elapsed: happyElapsed) : 0
            // A gear has no lungs, no eyelids, and no reason to sway.
            f.breath    = mood == .happy ? f.breath : 1
            f.eyeOpen   = 1
            f.headDroop = 0
            f.lean      = 0
            f.sway      = 0
        }
        return f
    }

    // MARK: Curves

    /// Eyelid multiplier on a per-kind cadence: 1 for most of the cycle,
    /// dipping to 0.1 across a 160 ms window once every `period` seconds. When
    /// `double` is set a second blink follows just behind the first — a nervous
    /// tic rather than a single calm blink.
    static func blink(t: Double, period: Double, phase: Double, double: Bool) -> Double {
        let width = 0.16
        guard period > width * 4 else { return 1 }
        // Offset the blink within the cycle by the kind's phase so pets do not
        // all shut their eyes on the same frame.
        let local = (t / period + phase).truncatingRemainder(dividingBy: 1) * period
        func dip(at start: Double) -> Double {
            guard local >= start, local <= start + width else { return 1 }
            let u = (local - start) / width           // 0…1 through the blink
            return 0.1 + 0.9 * abs(cos(.pi * u))      // shut and reopen
        }
        let first = dip(at: period - 0.5)
        guard double else { return first }
        return min(first, dip(at: period - 0.5 + width + 0.06))
    }

    /// Gear rotation in radians at time `t`.
    static func gearSpin(mood: CompanionMood, t: Double) -> Double {
        func radiansPerSecond(rpm: Double) -> Double { rpm * 2 * .pi / 60 }
        switch mood {
        case .idle:  return t * radiansPerSecond(rpm: 1)
        case .alert: return t * radiansPerSecond(rpm: 4)
        case .happy: return t * radiansPerSecond(rpm: 12)
        case .wary:  return t * radiansPerSecond(rpm: 2)
        case .sleepy:
            // Barely ticking: still for 80% of a 2.5 s cycle, then steps one
            // tooth (2π/8) across the remaining fifth.
            let period = 2.5, step = 2 * Double.pi / 8
            let cycles = (t / period).rounded(.down)
            let phase  = t / period - cycles
            let moving = max(0, (phase - 0.8) / 0.2)
            let eased  = moving * moving * (3 - 2 * moving)   // smoothstep
            return (cycles + eased) * step
        }
    }

    /// Sparkle burst: snaps on, decays over the happy window.
    static func sparkleEnvelope(elapsed: Double) -> Double {
        let u = elapsed / CompanionMood.happyDuration
        guard u >= 0, u <= 1 else { return 0 }
        return pow(1 - u, 1.6)
    }
}

// MARK: - CompanionState

/// Everything the board needs to draw one agent's companion, resolved from a
/// single `AgentActivitySnapshot`. Built by `CompanionRoster` so the view layer
/// never derives a mood of its own.
public struct CompanionState: Sendable, Equatable, Identifiable {
    public var id: String { agent.id }
    public let agent: AgentActivitySnapshot
    /// nil when this agent's pet has no artwork — draw `symbolFallback`.
    public let kind: CompanionKind?
    /// SF Symbol to use when `kind` is nil.
    public let symbolFallback: String
    /// The pet name as branded in `AgentStyle` / `hub/agent_identity.py`.
    public let petName: String
    public let mood: CompanionMood
    public let bond: CompanionBond
    /// Seconds since the approval driving `happy`, or nil.
    public let happyElapsed: Double?

    public init(agent: AgentActivitySnapshot,
                now: Date = Date(),
                approvedAt: Date? = nil,
                entropyDelta: Double? = nil) {
        let style = AgentStyleCatalog.style(for: agent.id)
        self.agent          = agent
        self.kind           = CompanionKind(petName: style.pet)
        self.symbolFallback = style.petSymbol
        self.petName        = style.pet
        self.mood           = CompanionMood.resolve(for: agent, now: now,
                                                    approvedAt: approvedAt,
                                                    entropyDelta: entropyDelta)
        self.bond           = CompanionBond.from(historyCount: agent.historyCount)
        self.happyElapsed   = approvedAt.map { max(0, now.timeIntervalSince($0)) }
    }

    /// The companion's line on the board. It *restates* the agent's status more
    /// softly and is never the only place that status appears — the honest
    /// `statusLine` always sits beside it.
    ///
    /// Deliberately never phrased as a claim: "focused" is a mood word, and it
    /// is only reachable when `AgentActivitySnapshot.statusLine` already says
    /// the agent is live and working.
    public var moodLine: String {
        "\(petName) · \(mood.label)"
    }

    /// Full accessibility sentence, mood *and* the underlying evidence.
    public var accessibilityLine: String {
        "\(agent.displayName), \(petName), \(mood.label). \(agent.statusLine)."
    }
}

// MARK: - CompanionRoster

/// Builds the companion board from an activity summary.
public enum CompanionRoster {

    /// One companion per agent, ordered the way the board should read:
    /// provably working first, then live, then most recently seen.
    ///
    /// - Parameter entropyDeltas: per-agent measured ΔH (or collapse proxy),
    ///   from `EntropyProvenance.companionDeltas`. Only agents present in the
    ///   map and reported `.live` can go `wary`. Prefer this over the shared
    ///   `entropyDelta` fallback so one collapsed agent does not alarm every pet.
    /// - Parameter entropyDelta: legacy single delta applied to every live
    ///   agent when that agent has no entry in `entropyDeltas`. Pass nil when
    ///   nothing measured is available.
    public static func build(from summary: AgentActivitySummary,
                             now: Date = Date(),
                             approvals: [String: Date] = [:],
                             entropyDeltas: [String: Double] = [:],
                             entropyDelta: Double? = nil) -> [CompanionState] {
        summary.agents
            .map { agent in
                let perAgent = entropyDeltas[agent.id]
                let shared = entropyDelta
                let delta: Double? = {
                    guard agent.presence == .live else { return nil }
                    if let perAgent { return perAgent }
                    return shared
                }()
                return CompanionState(agent: agent,
                                      now: now,
                                      approvedAt: approvals[agent.id],
                                      entropyDelta: delta)
            }
            .sorted { l, r in
                let lb = l.mood.claimsWork, rb = r.mood.claimsWork
                if lb != rb { return lb }
                let ll = l.agent.presence == .live, rl = r.agent.presence == .live
                if ll != rl { return ll }
                return l.agent.updatedAt > r.agent.updatedAt
            }
    }
}

// MARK: - CompanionPalette

#if canImport(SwiftUI)

/// Three fills plus an ink. Two-to-three colours per pet is a hard budget: at
/// 32pt a fourth fill reads as noise, not detail.
public struct CompanionPalette: Sendable {
    public let primary: Color    // body
    public let secondary: Color  // belly / muzzle / underside
    public let accent: Color     // eye sclera, or the warm highlight
    public let ink: Color        // pupils and the 1.5pt outline

    init(primary: UInt32, secondary: UInt32, accent: UInt32, ink: UInt32) {
        self.primary   = companionHex(primary)
        self.secondary = companionHex(secondary)
        self.accent    = companionHex(accent)
        self.ink       = companionHex(ink)
    }
}

/// `0xRRGGBB` literal → sRGB `Color`, via ShannonTheme's own literal type.
///
/// The pet palettes are fixed character artwork, not semantic tokens: an owl is
/// ochre in both light and dark, so these deliberately do not adapt.
func companionHex(_ hex: UInt32) -> Color { ShannonRGBA(hex: hex).color }

public extension CompanionKind {
    /// Each palette is hand-derived from the owning agent's brand colour in
    /// `AgentStyleCatalog`, pulled toward a warmer, more saturated reading so
    /// the characters hold up on both a light and a dark pill without going
    /// muddy or grey.
    ///
    /// The one deliberate exception is the wolf: Dispatch's brown reads as mud
    /// at this size, so the wolf goes cool grey-blue and takes its warmth from
    /// an amber eye instead.
    var palette: CompanionPalette {
        switch self {
        case .owl:      // science — ochre, cream, amber eye
            return .init(primary: 0xC8862A, secondary: 0xF2DCA8, accent: 0xFFC531, ink: 0x3A2410)
        case .raven:    // grok_build — near-black with a violet sheen
            return .init(primary: 0x1E1B2E, secondary: 0x5B4A9E, accent: 0xE8D24A, ink: 0x110F1C)
        case .fox:      // claude_code — rust and cream
            return .init(primary: 0xD2601A, secondary: 0xF7E3C8, accent: 0xFFB347, ink: 0x3B1D08)
        case .dolphin:  // codex — teal with a pale belly
            return .init(primary: 0x1F7A8C, secondary: 0xD9EEF2, accent: 0x7FD4E0, ink: 0x0C2E36)
        case .wolf:     // dispatch — cool grey-blue, amber eye
            return .init(primary: 0x5A6E88, secondary: 0xE3E7EF, accent: 0xF2B441, ink: 0x1E2836)
        case .beaver:   // cowork — warm brown, ivory teeth
            return .init(primary: 0x8B5A2B, secondary: 0xFFF6E2, accent: 0x3FBF6A, ink: 0x2E1A0B)
        case .gear:     // dataset_runner — teal with an amber spark
            return .init(primary: 0x1FA6B8, secondary: 0x0E5F6B, accent: 0xFFC531, ink: 0x08343B)
        }
    }
}

public extension CompanionMood {
    /// Ring colour for the mood. Semantic roles only — the companion never
    /// invents a hue that the rest of the pill does not already use.
    var ringColor: Color {
        switch self {
        case .wary:   return .shannonError
        case .happy:  return .shannonSuccess
        case .alert:  return .shannonAccent
        case .idle:   return .shannonNeutral
        case .sleepy: return .shannonNeutral
        }
    }

    /// How loudly the ring is drawn. Idle and sleeping companions are nearly
    /// silent by design — the pill is recessive when nothing is happening and
    /// pets must not undo that.
    var ringOpacity: Double {
        switch self {
        case .wary:   return 0.85
        case .happy:  return 0.75
        case .alert:  return 0.60
        case .idle:   return 0.22
        case .sleepy: return 0.14
        }
    }
}

#endif
