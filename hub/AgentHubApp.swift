// AgentHubApp.swift — Shannon Hub
// Premium macOS menu-bar command centre for multi-agent AI collaboration.
// Directives A–L + Pet system fully implemented.
//
// Requirements: macOS 13+, Swift 5.9+, Xcode 15+
// Frameworks: SwiftUI, AppKit, AVFoundation, IOKit, SQLite3
// RAM target: <100 MB

import AppKit
import AVFoundation
import Combine
import Foundation
import IOKit
import IOKit.ps
import Network
import Security
import SQLite3
import SwiftUI

// MARK: - Constants

private let kSocketPath  = "/tmp/shannon.sock"
private let kShannonDir  = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".shannon")
private let kDBPath      = kShannonDir.appendingPathComponent("agent_hub.db")
private let kPetsDir     = kShannonDir.appendingPathComponent("pets")
private let kKeychainSvc = "Shannon.AgentHub"
private let kPollInterval: Double = 0.5   // fast DB poll for near-instant status updates
private let kH_threshold:  Double = 3.5   // bits — entropy warning
private let kH_block:      Double = 5.0   // bits — hard block
private let kD_threshold:  Double = 1.8   // bits — disagreement flag

// MARK: - Hub palette  (mirrors Packages/ShannonTheme SemanticColors)
//
// The hub ships as a single standalone Swift file, so it cannot import
// ShannonTheme. These tokens are a hand-mirror of that package — same names,
// same values — so the popup and the notch pill stay one visual language. When
// a token changes there, change it here.
//
// Everything resolves per appearance. The hub used to be pinned to dark with
// `.preferredColorScheme(.dark)` and a stack of `Color.white.opacity(…)` values,
// which is exactly what made it unreadable on a bright desk.

/// A literal sRGB colour with straight alpha.
struct HubRGBA {
    let red: Double, green: Double, blue: Double, alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    func withAlpha(_ a: Double) -> HubRGBA {
        HubRGBA(red: red, green: green, blue: blue, alpha: a)
    }

    func scaled(by k: Double) -> HubRGBA {
        HubRGBA(red: red * k, green: green * k, blue: blue * k, alpha: alpha)
    }

    func blendedTowardWhite(_ t: Double) -> HubRGBA {
        HubRGBA(red: red + (1 - red) * t,
                green: green + (1 - green) * t,
                blue: blue + (1 - blue) * t,
                alpha: alpha)
    }
}

enum HubAdaptive {
    /// Builds a Color that follows the live system appearance, including inside
    /// an NSPopover, which is why this is an NSColor provider and not a
    /// `@Environment(\.colorScheme)` branch.
    static func color(day: HubRGBA, night: HubRGBA) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? night.nsColor : day.nsColor
        })
    }

    static func color(day: UInt32, night: UInt32) -> Color {
        color(day: HubRGBA(hex: day), night: HubRGBA(hex: night))
    }
}

// Day palette is warm paper, never grey. Every day surface and grey keeps red
// above blue so it reads as cream under daylight and under warm indoor light,
// instead of going clinical. Day ladder, lightest to darkest:
//
//   background #FAF8F3   surface    #FFFFFF   sunken   #F6F2EA
//   elevated   #F2EEE5   quaternary #DED6C8   tertiary #7D7365
//   secondary  #6B6257   primary    #1C1917
//
// Hairlines and shadows are warm brown at low alpha (#7A5C3A / #5C482D) rather
// than neutral black — a black hairline over cream desaturates the edge to grey,
// which is what made the first light pass still feel grey.
extension Color {
    // Surfaces
    static let hubBackground      = HubAdaptive.color(day: 0xFAF8F3, night: 0x0D0D10)
    static let hubSurface         = HubAdaptive.color(day: 0xFFFFFF, night: 0x18181C)
    static let hubSurfaceElevated = HubAdaptive.color(day: 0xF2EEE5, night: 0x222228)
    static let hubSurfaceSunken   = HubAdaptive.color(day: 0xF6F2EA, night: 0x101014)
    static let hubSurfaceHover    = HubAdaptive.color(
        day: HubRGBA(hex: 0x7A5C3A, alpha: 0.07),
        night: HubRGBA(hex: 0xFFFFFF, alpha: 0.06)
    )
    static let hubSeparator = HubAdaptive.color(
        day: HubRGBA(hex: 0x7A5C3A, alpha: 0.18),
        night: HubRGBA(hex: 0xFFFFFF, alpha: 0.10)
    )
    static let hubShadow = HubAdaptive.color(
        day: HubRGBA(hex: 0x5C482D, alpha: 0.12),
        night: HubRGBA(hex: 0x000000, alpha: 0.28)
    )

    // Text — contrast on white: 17.5:1 / 6.0:1 / 4.7:1
    static let hubPrimary    = HubAdaptive.color(day: 0x1C1917, night: 0xF0F0F5)
    static let hubSecondary  = HubAdaptive.color(day: 0x6B6257, night: 0x8A8D9F)
    static let hubTertiary   = HubAdaptive.color(day: 0x7D7365, night: 0x6A6D80)
    /// Non-textual warm grey: empty gauge tracks, disabled glyphs, rules.
    static let hubQuaternary = HubAdaptive.color(day: 0xDED6C8, night: 0x3C3F4E)

    // Accent
    static let hubAccent       = HubAdaptive.color(day: 0x3A5CF5, night: 0x6B8FFF)
    static let hubAccentSubtle = HubAdaptive.color(day: 0xEEF1FE, night: 0x1A2140)

    // States
    static let hubSuccess = HubAdaptive.color(day: 0x1A7F4B, night: 0x34C77A)
    static let hubWarning = HubAdaptive.color(day: 0xC47A0A, night: 0xF5B934)
    static let hubError   = HubAdaptive.color(day: 0xC0392B, night: 0xFF6B6B)
    static let hubNeutral = HubAdaptive.color(day: 0x857C6E, night: 0x5A5D6E)
}

// MARK: - Agent colour roles  (mirrors ShannonTheme AgentIdentityColor)

/// The four daylight-corrected roles derived from one agent brand colour.
/// `ink` is the only one safe for text — see the package for the full rationale.
struct HubAgentPalette {
    let ink: Color, tint: Color, wash: Color, edge: Color
}

enum HubAgentColor {
    static let dayInkMaxLuminance: Double = 0.183
    static let nightInkMinLuminance: Double = 0.223

    static func luminance(_ c: HubRGBA) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    static func darkened(_ c: HubRGBA, toAtMost target: Double) -> HubRGBA {
        guard luminance(c) > target else { return c }
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 18 {
            let mid = (lo + hi) / 2
            if luminance(c.scaled(by: mid)) > target { hi = mid } else { lo = mid }
        }
        return c.scaled(by: lo)
    }

    static func brightened(_ c: HubRGBA, toAtLeast target: Double) -> HubRGBA {
        guard luminance(c) < target else { return c }
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 18 {
            let mid = (lo + hi) / 2
            if luminance(c.blendedTowardWhite(mid)) < target { lo = mid } else { hi = mid }
        }
        return c.blendedTowardWhite(hi)
    }

    static func palette(red: Double, green: Double, blue: Double) -> HubAgentPalette {
        let base = HubRGBA(red: red, green: green, blue: blue)
        let dayInk = darkened(base, toAtMost: dayInkMaxLuminance)
        let nightInk = brightened(base, toAtLeast: nightInkMinLuminance)
        let dayTint = darkened(base, toAtMost: 0.42)
        let nightTint = brightened(base, toAtLeast: 0.20)
        return HubAgentPalette(
            ink: HubAdaptive.color(day: dayInk, night: nightInk),
            tint: HubAdaptive.color(day: dayTint, night: nightTint),
            wash: HubAdaptive.color(day: dayTint.withAlpha(0.10),
                                    night: nightTint.withAlpha(0.16)),
            edge: HubAdaptive.color(day: dayTint.withAlpha(0.28),
                                    night: nightTint.withAlpha(0.34))
        )
    }
}

// MARK: - AgentIdentity  (central registry — replaces all switch statements)

enum AuthKind { case local, cloud }

struct AgentIdentity: Identifiable, Equatable {
    let id:        String
    let icon:      String
    /// Raw brand components, mirroring `agent_identity.py` `color_rgb`.
    /// Stored rather than a finished `Color` so the daylight roles below can be
    /// derived from them.
    let red:       Double
    let green:     Double
    let blue:      Double
    let shortKey:  String    // single-char @-shortcut
    let shortName: String
    let authKind:  AuthKind

    /// Contrast-corrected roles. Use `ink` for text, `tint` for dots and arcs,
    /// `wash` for chip fills, `edge` for hairlines.
    var palette: HubAgentPalette {
        HubAgentColor.palette(red: red, green: green, blue: blue)
    }

    /// Brand hue for non-text marks. Text must use `palette.ink` instead —
    /// several brand colours sit near 2:1 against a white card.
    var color: Color { palette.tint }

    /// Full human label — mirrors hub/agent_identity.py display_name.
    var displayName: String {
        switch id {
        case "claude_code": return "Claude Code"
        case "cowork":      return "Cowork"
        case "dispatch":    return "Dispatch"
        case "science":     return "Claude Science"
        case "grok_build":  return "Grok Build"
        case "codex":       return "Codex"
        case "chatgpt":     return "ChatGPT"
        case "browser":     return "Browser"
        case "dataset_runner": return "DatasetRunner"
        case "terminal":    return "Terminal"
        default:            return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Underlying model family — shown as a small tag next to the agent name.
    var modelTag: String {
        switch id {
        case "claude_code", "cowork", "dispatch": return "Claude"
        case "science":     return "Claude Fable 5"
        case "grok_build":  return "Grok · xAI"
        case "codex", "chatgpt": return "GPT · OpenAI"
        case "browser":     return "web"
        default:            return "local"
        }
    }

    /// Companion animal — a fixed identity cue, one per agent. Mirrors
    /// `pet` in hub/agent_identity.py. Never varies with runtime state.
    ///
    /// Distinct from `PetState` / `PetManager` below, which use "pet" to mean
    /// the agent's persistent memory directory under ~/.shannon/pets/.
    var petName: String {
        switch id {
        case "science":        return "owl"
        case "grok_build":     return "raven"
        case "claude_code":    return "fox"
        case "codex":          return "dolphin"
        case "dispatch":       return "wolf"
        case "cowork":         return "beaver"
        case "chatgpt":        return "parrot"
        case "dataset_runner": return "ant"
        case "terminal":       return "tortoise"
        case "browser":        return "gecko"
        default:               return "creature"
        }
    }

    /// SF Symbol standing in for `petName`. SF Symbols ships no owl/raven/fox/
    /// wolf/beaver/dolphin glyph, so these are nearest matches chosen to stay
    /// visually distinct from each other — the animal name carries the identity.
    var petSymbol: String {
        switch id {
        case "science":        return "bird.fill"
        case "grok_build":     return "bird"
        case "claude_code":    return "hare.fill"
        case "codex":          return "fish.fill"
        case "dispatch":       return "dog.fill"
        case "cowork":         return "pawprint.fill"
        case "chatgpt":        return "bird.circle"
        case "dataset_runner": return "ant.fill"
        case "terminal":       return "tortoise.fill"
        case "browser":        return "lizard.fill"
        default:               return "pawprint.fill"
        }
    }

    // Per-agent Apple TTS voice — distinct identifier + pitch per directive E
    var voiceIdentifier: String {
        switch id {
        case "science":     return "com.apple.ttsbundle.Karen-compact"
        case "grok_build":  return "com.apple.ttsbundle.Moira-compact"
        case "claude_code": return "com.apple.ttsbundle.Tom-compact"
        case "cowork":      return "com.apple.ttsbundle.Samantha-compact"
        case "dispatch":    return "com.apple.ttsbundle.Daniel-compact"
        default:            return AVSpeechSynthesisVoiceIdentifierAlex
        }
    }
    var voicePitch: Float {
        switch id {
        case "science":     return 1.15
        case "grok_build":  return 0.85
        case "claude_code": return 0.95
        case "cowork":      return 1.10
        case "dispatch":    return 0.90
        default:            return 1.05   // codex / dataset_runner
        }
    }
    var voiceRate: Float { 0.52 }

    // Directive F — corrected icons
    static let all: [AgentIdentity] = [
        AgentIdentity(id: "claude_code", icon: "🟠",
                      red: 1.00, green: 0.50, blue: 0.08,
                      shortKey: "c", shortName: "CC",    authKind: .local),
        AgentIdentity(id: "cowork",      icon: "🟢",
                      red: 0.20, green: 0.85, blue: 0.45,
                      shortKey: "w", shortName: "CWork", authKind: .local),
        AgentIdentity(id: "dispatch",    icon: "🟤",
                      red: 0.72, green: 0.50, blue: 0.28,
                      shortKey: "d", shortName: "Disp",  authKind: .local),
        AgentIdentity(id: "science",     icon: "🔬",
                      red: 1.00, green: 0.72, blue: 0.10,
                      shortKey: "s", shortName: "Sci",   authKind: .local),
        AgentIdentity(id: "grok_build",  icon: "🟣",
                      red: 0.68, green: 0.28, blue: 0.98,
                      shortKey: "g", shortName: "Grok",  authKind: .cloud),
        AgentIdentity(id: "codex",       icon: "🔵",
                      red: 0.30, green: 0.55, blue: 1.00,
                      shortKey: "x", shortName: "Codex", authKind: .cloud),
        AgentIdentity(id: "chatgpt",     icon: "🟢",
                      red: 0.10, green: 0.72, blue: 0.55,
                      shortKey: "p", shortName: "GPT",   authKind: .cloud),
        AgentIdentity(id: "browser",     icon: "🌐",
                      red: 0.35, green: 0.55, blue: 0.95,
                      shortKey: "b", shortName: "Web",   authKind: .local),
    ]

    static func find(_ id: String) -> AgentIdentity? { all.first { $0.id == id } }
    static subscript(_ id: String) -> AgentIdentity {
        find(id) ?? AgentIdentity(id: id, icon: "⚙️",
                                   red: 0.55, green: 0.55, blue: 0.58,
                                   shortKey: "?", shortName: id, authKind: .local)
    }
}

// MARK: - Pet System  (directive: Pet)

struct PetState: Codable, Equatable {
    var status:       String  = "idle"        // "active" | "idle" | "mid_task"
    var lastTask:     String  = ""
    var lastCFDelta:  Double? = nil
    var memorySize:   Int     = 0
    var historyCount: Int     = 0
    var updatedAt:    Date    = .distantPast
    var resumable:    Bool    = false          // true → was mid-task when hub closed
}

final class PetManager: ObservableObject {
    static let shared = PetManager()

    @Published var states: [String: PetState] = [:]
    @Published var memoryAccessingAgents: Set<String> = []

    private var memoryTimers: [String: Timer] = [:]
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private init() { ensureBaseDir(); loadAllStates() }

    // MARK: Directory bootstrap

    func ensureBaseDir() {
        let fm = FileManager.default
        try? fm.createDirectory(at: kPetsDir, withIntermediateDirectories: true)
        for a in AgentIdentity.all { ensurePetDirectory(for: a.id) }
    }

    func ensurePetDirectory(for agentId: String) {
        let fm  = FileManager.default
        let dir = kPetsDir.appendingPathComponent(agentId)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let memory  = dir.appendingPathComponent("memory.md")
        let history = dir.appendingPathComponent("history.jsonl")
        for url in [memory, history] where !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }
        let config = dir.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: config.path) {
            let defaults: [String: Any] = ["voice_enabled": true,
                                            "notify_threshold": kH_threshold]
            if let data = try? JSONSerialization.data(withJSONObject: defaults) {
                fm.createFile(atPath: config.path, contents: data)
            }
        }
        let state = dir.appendingPathComponent("state.json")
        if !fm.fileExists(atPath: state.path) {
            if let data = try? encoder.encode(PetState()) {
                fm.createFile(atPath: state.path, contents: data)
            }
        }
    }

    // MARK: Load / Save

    func loadAllStates() {
        var loaded: [String: PetState] = [:]
        for a in AgentIdentity.all { loaded[a.id] = loadState(for: a.id) }
        DispatchQueue.main.async { self.states = loaded }
    }

    func loadState(for agentId: String) -> PetState {
        let url = kPetsDir.appendingPathComponent(agentId).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url),
              let s = try? decoder.decode(PetState.self, from: data) else { return PetState() }
        return s
    }

    func saveState(_ state: PetState, for agentId: String) {
        let url = kPetsDir.appendingPathComponent(agentId).appendingPathComponent("state.json")
        if let data = try? encoder.encode(state) { try? data.write(to: url, options: .atomic) }
        DispatchQueue.main.async { self.states[agentId] = state }
    }

    // MARK: Memory access animation (2 s auto-clear)

    func signalMemoryAccess(for agentId: String) {
        DispatchQueue.main.async {
            self.memoryAccessingAgents.insert(agentId)
            self.memoryTimers[agentId]?.invalidate()
            self.memoryTimers[agentId] = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { self?.memoryAccessingAgents.remove(agentId) }
            }
        }
    }

    // MARK: Delegation pre-fill helpers

    func readMemorySnippet(for agentId: String, maxBytes: Int = 512) -> String {
        let url = kPetsDir.appendingPathComponent(agentId).appendingPathComponent("memory.md")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        return String(data: data.prefix(maxBytes), encoding: .utf8) ?? ""
    }

    func recentHistory(for agentId: String, lines: Int = 5) -> [String] {
        let url = kPetsDir.appendingPathComponent(agentId).appendingPathComponent("history.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(lines))
    }
}

// MARK: - Keychain Helper  (SecItemAdd / SecItemCopyMatching — never plaintext)

enum KeychainHelper {
    @discardableResult
    static func store(account: String, value: Data) -> Bool {
        _ = delete(account: account)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: kKeychainSvc as CFString,
            kSecAttrAccount: account as CFString,
            kSecValueData:   value,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: kKeychainSvc as CFString,
            kSecAttrAccount: account as CFString,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: kKeychainSvc as CFString,
            kSecAttrAccount: account as CFString,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static func storeToken(_ token: String, for agentId: String) {
        guard let data = token.data(using: .utf8) else { return }
        store(account: "\(agentId).token", value: data)
    }

    static func loadToken(for agentId: String) -> String? {
        guard let data = load(account: "\(agentId).token"),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func hasToken(for agentId: String) -> Bool { loadToken(for: agentId) != nil }
}

// MARK: - Domain Models

enum AgentStatus: String, Codable {
    case idle, active, waiting, blocked, error

    /// Status colour for text and badge labels.
    ///
    /// The previous values were tuned for a #0D0D0D slab — a 0.85-green and a
    /// 0.80-amber, both of which drop to roughly 2:1 on a white card and turn
    /// a status badge into a smudge. These resolve per scheme and clear 4.5:1
    /// on either surface.
    var color: Color {
        switch self {
        case .idle:    return .hubNeutral
        case .active:  return .hubSuccess
        case .waiting: return .hubWarning
        case .blocked: return HubAdaptive.color(day: 0xB4530A, night: 0xFF9F45)
        case .error:   return .hubError
        }
    }

    /// Tinted background behind a status badge.
    var wash: Color {
        switch self {
        case .idle:    return .hubSurfaceElevated
        case .active:  return HubAdaptive.color(day: 0xE6F4E4, night: 0x123322)
        case .waiting: return HubAdaptive.color(day: 0xFBEFD6, night: 0x33270B)
        case .blocked: return HubAdaptive.color(day: 0xFCEADB, night: 0x37200D)
        case .error:   return HubAdaptive.color(day: 0xFAE6E0, night: 0x371917)
        }
    }

    /// Short human label. `waiting` reads as "needs you" so the one status that
    /// actually demands attention says so in words, not just hue.
    var label: String {
        switch self {
        case .idle:    return "idle"
        case .active:  return "active"
        case .waiting: return "needs you"
        case .blocked: return "blocked"
        case .error:   return "error"
        }
    }
}

struct AgentRow {
    var agentId:     String
    var status:      AgentStatus
    var lastSeen:    Date
    var entropy:     Double
    var taskSummary: String
    var authMethod:  String     // "socket_secret" | "keychain" | "none"
}

struct BenchmarkState {
    var agentId:   String
    var progress:  Int          // 0–100
    var stateJSON: String       // raw JSON payload
    var bestCF:    Double?      // decoded from stateJSON["cf"] or ["best_cf"]
    var bestRMSD:  Double?      // decoded from stateJSON["rmsd"] or ["best_rmsd"]
}

struct AgentInteraction: Identifiable {
    enum InteractionKind { case yesNo, choice([String]), info }
    /// Gate `agent_interactions.interaction_id` — MUST be the real id, never a fresh UUID.
    /// Resolve sends this string so AuditDB.resolve_interaction can match the row.
    let id:        String
    let agentId:   String
    let prompt:    String
    let kind:      InteractionKind
    var timeoutAt: Date? = nil
    var diff:      String? = nil   // unified diff to show in DiffReviewView
    var content:   String  = ""    // agent's detailed output (event_output) shown under the prompt
}

/// Pure helpers for the hub ask path (extract gate id + build resolve envelope).
/// Kept free of AppKit so the contract is unit-testable via the Python twin in agent_identity.
enum HubAskPipeline {
    /// Derive the gate interaction_id from an activity event.
    /// Gate stores `ask.interaction_id` in `event_output` for approval_needed rows.
    static func gateInteractionId(
        eventOutput: String,
        agentId: String,
        at: Date = Date()
    ) -> String {
        let trimmed = eventOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "ask-\(agentId)-\(Int(at.timeIntervalSince1970))"
        }
        // JSON payload with interaction_id field
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let iid = obj["interaction_id"] as? String,
           !iid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return iid.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Bare id (normal path: event_output = interaction_id)
        if !trimmed.contains("\n"), trimmed.count <= 200 {
            return trimmed
        }
        return "ask-\(agentId)-\(Int(at.timeIntervalSince1970))"
    }

    /// Payload fields GateSocketClient.sendApproval must put on the wire.
    static func resolvePayload(
        gateInteractionId: String,
        agentId: String,
        approved: Bool,
        reply: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "target_agent":   agentId,
            "approved":       approved,
            "interaction_id": gateInteractionId,
            "source":         "hub_ui",
            "kind":           "approval_response",
        ]
        if let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["user_reply"] = reply
        }
        return payload
    }
}

struct ToolEvent: Identifiable {
    enum EventKind: String { case bash="Bash", read="Read", write="Write",
                                   edit="Edit", build="Build", dock="Dock", net="Net" }
    let id        = UUID()
    let agentId:  String
    let kind:     EventKind
    let label:    String
    let detail:   String
    let timestamp = Date()
}

struct DelegationRecord: Identifiable {
    let id        = UUID()
    let agentId:  String
    let command:  String
    let outcome:  String
    let at:       Date
}

struct GateEvent {
    var eventType: String
    var agentId:   String
    var payload:   String   // event_label from agent_activity
    var output:    String   // event_output from agent_activity
    var at:        Date
    /// SQLite rowid — stable key for one-shot sound/voice/UI side effects.
    var rowid:     Int64 = 0
}

/// Pending row from agent_interactions (authoritative ask source for the hub UI).
struct PendingGateAsk: Identifiable, Equatable {
    var id: String { interactionId }
    let interactionId: String
    let agentId: String
    let prompt: String
    let status: String
}

/// One row of `agent_messages` — the gate's own message log.
///
/// Backs the per-agent detail view and the streaming indicator. Every field is
/// read straight from the table the gate writes in `AuditDB.record_message`;
/// nothing here is synthesised by the UI.
struct AgentMessageRow: Identifiable, Equatable {
    let id: Int64            // agent_messages.id
    let agentId: String      // agent_messages.agent_id
    let messageType: String  // agent_messages.message_type
    let summary: String      // decoded from payload_json (text/message/summary/task)
    let gateH: Double?       // agent_messages.gate_H — entropy the gate computed
    let gateDecision: String // agent_messages.gate_decision (allowed / flagged / blocked)
    let at: Date             // agent_messages.received_at_ns
}

// MARK: - Sound Controller  (AVFoundation 8-bit square wave synthesis — local only)

final class SoundController {
    static let shared = SoundController()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    // Per-event toggles
    var enabledEvents: Set<String> = ["task_complete", "approval_needed",
                                       "blocked", "error", "entropy_warn", "connected"]

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func play(event: String) {
        guard enabledEvents.contains(event) else { return }
        let freq: Float
        switch event {
        case "task_complete":   freq = 880
        case "approval_needed": freq = 660
        case "blocked":         freq = 220
        case "error":           freq = 110
        case "entropy_warn":    freq = 440
        case "connected":       freq = 1047
        default:                freq = 440
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let buf = makeSquareWave(freq: freq, duration: 0.12) else { return }
            player.scheduleBuffer(buf, completionHandler: nil)
            if !player.isPlaying { player.play() }
        }
    }

    private func makeSquareWave(freq: Float, duration: Float) -> AVAudioPCMBuffer? {
        let sr = Float(format.sampleRate)
        let fc = AVAudioFrameCount(sr * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: fc) else { return nil }
        buf.frameLength = fc
        let data   = buf.floatChannelData![0]
        let period = sr / freq
        let attack = Int(sr * 0.005)
        let rel    = Int(sr * 0.010)
        for i in 0 ..< Int(fc) {
            let sq: Float = fmodf(Float(i), period) < period / 2 ? 0.25 : -0.25
            var env: Float = 1.0
            if i < attack { env = Float(i) / Float(attack) }
            let tail = Int(fc) - rel
            if i > tail  { env = Float(Int(fc) - i) / Float(rel) }
            data[i] = sq * env
        }
        return buf
    }
}

// MARK: - Voice Controller  (AVSpeechSynthesizer — macOS AVFoundation only, no external API)

final class VoiceController: ObservableObject {
    static let shared = VoiceController()
    private let synth = AVSpeechSynthesizer()

    // Key = "\(agentId).\(event)"
    var enabledCallouts: Set<String> = Set(AgentIdentity.all.flatMap { a in
        ["task_complete", "approval_needed", "resource_alert"].map { "\(a.id).\($0)" }
    })

    private init() {}

    func speak(agentId: String, event: String, text: String) {
        guard enabledCallouts.contains("\(agentId).\(event)") else { return }
        let identity  = AgentIdentity[agentId]
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice           = AVSpeechSynthesisVoice(identifier: identity.voiceIdentifier)
                                 ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.pitchMultiplier = identity.voicePitch
        utterance.rate            = identity.voiceRate
        DispatchQueue.main.async { self.synth.speak(utterance) }
    }

    func taskComplete(agentId: String, summary: String) {
        speak(agentId: agentId, event: "task_complete",
              text: "\(AgentIdentity[agentId].shortName) finished. \(summary)")
    }
    func approvalNeeded(agentId: String, prompt: String) {
        speak(agentId: agentId, event: "approval_needed",
              text: "\(AgentIdentity[agentId].shortName) needs approval. \(prompt)")
    }
    func resourceAlert(_ text: String) {
        speak(agentId: "dispatch", event: "resource_alert", text: text)
    }
}

// MARK: - System Resource Monitor  (IOKit / sysctl / host_processor_info / IOKit power)

struct SystemMetrics {
    var cpuPercent:  Double = 0
    var gpuPercent:  Double = 0
    var ramUsedGB:   Double = 0
    var ramTotalGB:  Double = 0
    var ramPressure: Int    = 0   // 0=ok 1=warn 2=critical
    var ssdUsedGB:   Double = 0
    var ssdTotalGB:  Double = 0
    var thermalState: Int   = 0   // 0=nominal…3=critical
    var batteryPct:  Double = -1  // -1 = desktop / AC-only
    var batteryWatts: Double = 0
    var isCharging:  Bool   = false
}

final class SystemResourceMonitor: ObservableObject {
    @Published var metrics = SystemMetrics()
    private var timer: Timer?

    init() { startPolling() }
    deinit { timer?.invalidate() }

    func startPolling() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var m = SystemMetrics()
            m.cpuPercent   = self.cpuLoad()
            m.gpuPercent   = self.gpuLoad()
            let ram = self.ramInfo(); m.ramUsedGB = ram.0; m.ramTotalGB = ram.1; m.ramPressure = ram.2
            let ssd = self.diskInfo(); m.ssdUsedGB = ssd.0; m.ssdTotalGB = ssd.1
            m.thermalState = self.thermalState()
            let bat = self.batteryInfo(); m.batteryPct = bat.0; m.batteryWatts = bat.1; m.isCharging = bat.2
            DispatchQueue.main.async { self.metrics = m }
        }
    }

    // CPU: delta-based per-core ticks
    private func cpuLoad() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                   &numCPUs, &cpuInfo, &numCPUInfo) == KERN_SUCCESS,
              let info = cpuInfo else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(numCPUInfo)) }
        var usr = 0.0; var sys = 0.0; var idle = 0.0; var nice = 0.0
        let stride = Int(CPU_STATE_MAX)
        for i in 0 ..< Int(numCPUs) {
            let b = i * stride
            usr  += Double(info[b + Int(CPU_STATE_USER)])
            sys  += Double(info[b + Int(CPU_STATE_SYSTEM)])
            idle += Double(info[b + Int(CPU_STATE_IDLE)])
            nice += Double(info[b + Int(CPU_STATE_NICE)])
        }
        let total = usr + sys + idle + nice
        return total > 0 ? ((usr + sys + nice) / total) * 100.0 : 0
    }

    // GPU: IOAccelerator PerformanceStatistics
    private func gpuLoad() -> Double {
        let match = IOServiceMatching("IOAccelerator") as NSMutableDictionary
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == kIOReturnSuccess else { return 0 }
        defer { IOObjectRelease(iter) }
        var maxUtil = 0.0
        var svc = IOIteratorNext(iter)
        while svc != IO_OBJECT_NULL {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any] {
                let u = (perf["Device Utilization %"] as? Double)
                     ?? ((perf["GPU Core Utilization"] as? Double ?? 0) / 10_000_000.0)
                maxUtil = max(maxUtil, u)
            }
            svc = IOIteratorNext(iter)
        }
        return min(maxUtil, 100.0)
    }

    // RAM via vm_statistics64
    private func ramInfo() -> (Double, Double, Int) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                _ = host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let ps = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) +
                    Double(stats.compressor_page_count)) * ps / 1_073_741_824.0
        var size: size_t = 0; var len = size_t(MemoryLayout<size_t>.size)
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        let total = Double(size) / 1_073_741_824.0
        let pressure: Int
        switch ProcessInfo.processInfo.thermalState {
        case .critical: pressure = 2
        case .serious:  pressure = 1
        default:        pressure = 0
        }
        return (used, total, pressure)
    }

    private func diskInfo() -> (Double, Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attrs[.systemSize] as? Int64,
              let free  = attrs[.systemFreeSize] as? Int64 else { return (0, 0) }
        let gb = 1_073_741_824.0
        return (Double(total - free) / gb, Double(total) / gb)
    }

    private func thermalState() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    private func batteryInfo() -> (Double, Double, Bool) {
        guard let info    = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let src     = sources.first,
              let desc    = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any]
        else { return (-1, 0, false) }
        let pct      = desc[kIOPSCurrentCapacityKey as String] as? Double ?? -1
        let charging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
        let current  = desc["Current" as String] as? Double ?? 0
        let voltage  = desc["Voltage" as String] as? Double ?? 0
        return (pct, abs(current * voltage / 1_000_000.0), charging)
    }
}

// MARK: - Diff Model  (directive E — unified diff with syntax highlighting)

struct DiffLine: Identifiable {
    enum Kind { case header, added, removed, context }
    let id:   Int
    let kind: Kind
    let text: String

    var fg: Color {
        switch kind {
        case .header:  return HubAdaptive.color(day: 0x1F5FA8, night: 0x66C7FF)
        case .added:   return HubAdaptive.color(day: 0x14663A, night: 0x66E08C)
        case .removed: return HubAdaptive.color(day: 0x9E2B21, night: 0xFF7A7A)
        case .context: return .hubSecondary
        }
    }
    var bg: Color {
        switch kind {
        case .added:   return HubAdaptive.color(day: 0xE4F6EA, night: 0x0C2A16)
        case .removed: return HubAdaptive.color(day: 0xFBE6E3, night: 0x2E110F)
        default:       return .clear
        }
    }
}

func parseDiff(_ raw: String) -> [DiffLine] {
    raw.components(separatedBy: "\n").enumerated().map { i, line in
        let kind: DiffLine.Kind
        if line.hasPrefix("@@")     { kind = .header  }
        else if line.hasPrefix("+") { kind = .added   }
        else if line.hasPrefix("-") { kind = .removed }
        else                         { kind = .context }
        return DiffLine(id: i, kind: kind, text: line)
    }
}

// MARK: - Flow Layout  (choice chips — directive H)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        for (sv, pt) in zip(subviews, result.origins) {
            sv.place(at: CGPoint(x: pt.x + bounds.minX, y: pt.y + bounds.minY),
                     proposal: .unspecified)
        }
    }
    private func layout(proposal: ProposedViewSize, subviews: Subviews)
        -> (size: CGSize, origins: [CGPoint]) {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        var origins: [CGPoint] = []
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            origins.append(CGPoint(x: x, y: y))
            rowH = max(rowH, sz.height); x += sz.width + spacing
        }
        return (CGSize(width: maxW, height: y + rowH), origins)
    }
}

// MARK: - Gate Socket Client  (Unix socket → shannon_gate.py, persistent, auto-reconnect)

final class GateSocketClient {
    static let shared = GateSocketClient()

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "shannon.gate.client", qos: .utility)
    private var _connected = false
    var isConnected: Bool { _connected }

    private init() { reconnect() }

    func reconnect() {
        connection?.cancel()
        _connected = false
        let ep     = NWEndpoint.unix(path: kSocketPath)
        let params = NWParameters.tcp
        let conn   = NWConnection(to: ep, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?._connected = true
                self?.register()
            case .failed(_), .cancelled:
                self?._connected = false
                self?.queue.asyncAfter(deadline: .now() + 3.0) { self?.reconnect() }
            default:
                break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }

    private func register() {
        sendRaw(["agent_id": "local_test", "task_id": "hub_ui"])
    }

    // Thread-safe JSON send with automatic reconnect on failure
    func sendMessage(_ dict: [String: Any]) {
        queue.async { self.sendRaw(dict) }
    }

    private func sendRaw(_ dict: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(0x0A) // \n delimiter the gate expects
        connection?.send(content: data, completion: .contentProcessed({ [weak self] err in
            if err != nil { self?._connected = false; self?.reconnect() }
        }))
    }

    func sendDelegation(agentId: String?, command: String) {
        sendMessage([
            "agent_id":     "local_test",
            "task_id":      "hub_ui",
            "message_type": "system_event",
            "confidence":   1.0,
            "shannon_H":    0.0,
            "payload": [
                "command":      command,
                "target_agent": agentId ?? "broadcast",
                "source":       "hub_ui",
            ] as [String: Any],
        ])
    }

    /// Nudge one agent over the gate.
    ///
    /// Real delivery: `_dispatch` gates this like any other message and then
    /// `_broadcast`s the envelope to every *other* connected agent, with
    /// `payload.target_agent` naming the intended recipient. It reaches an agent
    /// only if that agent currently holds a socket connection — which is exactly
    /// what the UI claims, since the button is offered for agents the registry
    /// shows as known and idle.
    func sendPing(agentId: String) {
        sendMessage([
            "agent_id":     "local_test",
            "task_id":      "hub_ui",
            "message_type": "system_event",
            "confidence":   1.0,
            "shannon_H":    0.0,
            "payload": [
                "kind":         "ping",
                "target_agent": agentId,
                "source":       "hub_ui",
                "text":         "hub ping",
            ] as [String: Any],
        ])
    }

    /// Free-text message aimed at one agent. Same delivery path as `sendPing`.
    func sendAgentMessage(agentId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendMessage([
            "agent_id":     "local_test",
            "task_id":      "hub_ui",
            "message_type": "system_event",
            "confidence":   1.0,
            "shannon_H":    0.0,
            "payload": [
                "kind":         "user_message",
                "target_agent": agentId,
                "source":       "hub_ui",
                "text":         trimmed,
            ] as [String: Any],
        ])
    }

    func sendApproval(agentId: String, interactionId: String, approved: Bool,
                      reply: String? = nil) {
        // HubAskPipeline builds the wire payload so interaction_id is the gate id.
        let payload = HubAskPipeline.resolvePayload(
            gateInteractionId: interactionId,
            agentId: agentId,
            approved: approved,
            reply: reply
        )
        sendMessage([
            "agent_id":     "local_test",
            "task_id":      "hub_ui",
            "message_type": "approval_response",
            "confidence":   1.0,
            "shannon_H":    0.0,
            "payload":      payload,
        ])
    }
}

// MARK: - AuditDB Reader  (SQLite WAL — polls agent_hub.db every 0.5 s)

final class AuditDBReader: ObservableObject {
    @Published var agents:      [String: AgentRow]       = [:]
    @Published var benchmarks:  [String: BenchmarkState] = [:]
    @Published var events:      [GateEvent]               = []
    /// Pending human asks from agent_interactions (gate interaction_id is authoritative).
    @Published var pendingAsks: [PendingGateAsk]         = []
    /// Last ~12 gate messages per agent, newest first — source: agent_messages.
    @Published var messages:    [String: [AgentMessageRow]] = [:]
    /// Wall-clock of each agent's most recent gate message — source: agent_messages.
    /// This is what distinguishes "streaming right now" from status == active,
    /// which persists long after the agent stops emitting.
    @Published var lastMessageAt: [String: Date]         = [:]
    @Published var isConnected  = false

    /// An agent counts as *streaming* when the gate logged a message from it
    /// within this window. Tuned to the 0.5 s poll: two empty polls and the
    /// indicator drops.
    static let streamingWindow: TimeInterval = 3.0

    /// Agents that emitted a gate message inside `streamingWindow`.
    var streamingAgents: Set<String> {
        let cutoff = Date().addingTimeInterval(-Self.streamingWindow)
        return Set(lastMessageAt.filter { $0.value > cutoff }.keys)
    }

    private var db:    OpaquePointer?
    private var timer: Timer?

    init() { openDB(); startPolling() }
    deinit { timer?.invalidate(); sqlite3_close(db) }

    private func openDB() {
        try? FileManager.default.createDirectory(at: kShannonDir, withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(kDBPath.path, &db, flags, nil) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            isConnected = true
        }
    }

    func startPolling() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: kPollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let db else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let a = self.fetchAgents(db)
            let b = self.fetchBenchmarks(db)
            let e = self.fetchEvents(db)
            let p = self.fetchPendingAsks(db)
            let (m, seen) = self.fetchMessages(db)
            DispatchQueue.main.async {
                self.agents = a
                self.benchmarks = b
                self.events = e
                self.pendingAsks = p
                self.messages = m
                self.lastMessageAt = seen
            }
        }
    }

    private func fetchAgents(_ db: OpaquePointer) -> [String: AgentRow] {
        // last_seen_ns is stored as nanoseconds; convert to seconds for Date()
        let sql = """
            SELECT agent_id, status,
                   CAST(last_seen_ns / 1000000000.0 AS REAL) AS last_seen,
                   entropy_score, task_summary, auth_method
            FROM agents;
            """
        var stmt: OpaquePointer?; var result: [String: AgentRow] = [:]
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = str(stmt, 0)
            result[id] = AgentRow(agentId: id,
                status:      AgentStatus(rawValue: str(stmt, 1)) ?? .idle,
                lastSeen:    Date(timeIntervalSince1970: dbl(stmt, 2)),
                entropy:     dbl(stmt, 3),
                taskSummary: str(stmt, 4),
                authMethod:  str(stmt, 5))
        }
        return result
    }

    private func fetchBenchmarks(_ db: OpaquePointer) -> [String: BenchmarkState] {
        // JOIN agents on task_id so the dict is keyed by agent_id (for vm.db.benchmarks[a.id])
        let sql = """
            SELECT COALESCE(a.agent_id, b.task_id), b.completed, b.state_json
            FROM benchmark_state b
            LEFT JOIN agents a ON a.task_id = b.task_id
            ORDER BY b.updated_at DESC;
            """
        var stmt: OpaquePointer?; var result: [String: BenchmarkState] = [:]
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key  = str(stmt, 0)
            let json = str(stmt, 2)
            var cf: Double?; var rmsd: Double?
            if let data = json.data(using: .utf8),
               let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                cf   = obj["cf"]   as? Double ?? obj["best_cf"]   as? Double
                rmsd = obj["rmsd"] as? Double ?? obj["best_rmsd"] as? Double
            }
            result[key] = BenchmarkState(agentId: key,
                progress:  Int(sqlite3_column_int(stmt, 1)),
                stateJSON: json, bestCF: cf, bestRMSD: rmsd)
        }
        return result
    }

    private func fetchEvents(_ db: OpaquePointer) -> [GateEvent] {
        // Fixed columns: event_label (not payload), event_at_ns→seconds (not timestamp)
        // rowid is included so processGateEvents can fire side-effects once per row.
        let sql = """
            SELECT event_type, agent_id,
                   event_label,
                   CAST(event_at_ns / 1000000000.0 AS REAL) AS at,
                   COALESCE(event_output, ''),
                   rowid
            FROM agent_activity
            ORDER BY rowid DESC LIMIT 60;
            """
        var stmt: OpaquePointer?; var result: [GateEvent] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(GateEvent(eventType: str(stmt, 0), agentId: str(stmt, 1),
                                    payload: str(stmt, 2), output: str(stmt, 4),
                                    at: Date(timeIntervalSince1970: dbl(stmt, 3)),
                                    rowid: sqlite3_column_int64(stmt, 5)))
        }
        return result
    }

    private func fetchPendingAsks(_ db: OpaquePointer) -> [PendingGateAsk] {
        let sql = """
            SELECT interaction_id, agent_id, prompt, status
            FROM agent_interactions
            WHERE status = 'pending'
            ORDER BY created_at_ns DESC
            LIMIT 20;
            """
        var stmt: OpaquePointer?; var result: [PendingGateAsk] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(PendingGateAsk(
                interactionId: str(stmt, 0),
                agentId: str(stmt, 1),
                prompt: str(stmt, 2),
                status: str(stmt, 3)
            ))
        }
        return result
    }

    /// Recent gate messages grouped by agent.
    ///
    /// Source: `agent_messages`, written by `AuditDB.record_message` in
    /// shannon_gate.py for every message that reaches the gate. Returns both the
    /// grouped rows (detail view) and each agent's newest timestamp (streaming
    /// indicator), so one query serves both.
    private func fetchMessages(_ db: OpaquePointer)
        -> ([String: [AgentMessageRow]], [String: Date]) {
        let sql = """
            SELECT id, agent_id, message_type, payload_json,
                   gate_H, COALESCE(gate_decision, ''),
                   CAST(received_at_ns / 1000000000.0 AS REAL) AS at
            FROM agent_messages
            ORDER BY id DESC LIMIT 240;
            """
        var stmt: OpaquePointer?
        var grouped: [String: [AgentMessageRow]] = [:]
        var newest: [String: Date] = [:]
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return (grouped, newest)
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let agent = str(stmt, 1)
            let at = Date(timeIntervalSince1970: dbl(stmt, 6))
            let row = AgentMessageRow(
                id: sqlite3_column_int64(stmt, 0),
                agentId: agent,
                messageType: str(stmt, 2),
                summary: Self.summarise(payloadJSON: str(stmt, 3)),
                gateH: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : dbl(stmt, 4),
                gateDecision: str(stmt, 5),
                at: at
            )
            // Rows arrive newest-first, so the first sighting is the newest.
            if newest[agent] == nil { newest[agent] = at }
            if grouped[agent, default: []].count < 12 {
                grouped[agent, default: []].append(row)
            }
        }
        return (grouped, newest)
    }

    /// Human-readable one-liner from a gate payload. Mirrors the key order in
    /// `agent_identity.status_from_payload` so the detail view and the card
    /// summary agree on what the message "said".
    static func summarise(payloadJSON: String) -> String {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        for key in ["text", "message", "summary", "task", "output", "label"] {
            if let v = obj[key] as? String, !v.isEmpty { return String(v.prefix(240)) }
        }
        return ""
    }

    // Write a delegation record directly to SQLite so the gate picks it up
    func insertDelegation(agentId: String, taskText: String) {
        guard let db else { return }
        let sql = "INSERT INTO delegations (agent_id, task_text, dispatched_at_ns) VALUES (?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let ns = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        sqlite3_bind_text(stmt, 1, agentId,  -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, taskText, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 3, ns)
        sqlite3_step(stmt)
    }

    private func str(_ s: OpaquePointer?, _ col: Int32) -> String {
        guard let s, let p = sqlite3_column_text(s, col) else { return "" }
        return String(cString: p)
    }
    private func dbl(_ s: OpaquePointer?, _ col: Int32) -> Double {
        guard let s else { return 0 }; return sqlite3_column_double(s, col)
    }
}

// MARK: - Hub View Model

final class HubViewModel: ObservableObject {
    @Published var interactions:   [AgentInteraction]    = []
    @Published var toolEvents:     [ToolEvent]           = []
    @Published var delegations:    [DelegationRecord]    = []
    @Published var selectedAgent:  String?               = nil
    @Published var delegateText:   String                = ""
    @Published var showDelegateBar = false
    @Published var showSettings    = false
    /// Agent whose message history is expanded in the Agents tab.
    @Published var expandedAgentId: String?              = nil
    /// Agent whose inline composer is open, plus its draft text.
    @Published var composingAgentId: String?             = nil
    @Published var composeText:    String                = ""
    /// Transient per-agent confirmation ("sent", "pinged") shown on the card.
    @Published var actionFeedback: [String: String]      = [:]
    /// Suspends this hub's own sound and voice output. Does NOT pause the agents
    /// — the gate has no such control — so the UI labels it "Mute alerts", not
    /// "Pause all". Real local state: consulted before every sound/voice call.
    @Published var alertsMuted     = false

    let db       = AuditDBReader()
    let sysmon   = SystemResourceMonitor()
    let pets     = PetManager.shared
    let voice    = VoiceController.shared
    let sound    = SoundController.shared

    private var cancellables = Set<AnyCancellable>()
    /// Side-effect keys already handled (rowid or interaction id) — prevents 0.5s poll spam.
    private var seenSideEffectKeys = Set<String>()

    init() {
        // Watch events from DB → signal pet memory access + dispatch voice/sound
        db.$events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] events in self?.processGateEvents(events) }
            .store(in: &cancellables)

        // Authoritative pending asks from agent_interactions (correct gate ids)
        db.$pendingAsks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] asks in self?.syncPendingAsks(asks) }
            .store(in: &cancellables)

        // Thermal alerts → voice
        sysmon.$metrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] m in self?.checkResourceAlerts(m) }
            .store(in: &cancellables)
    }

    private func processGateEvents(_ events: [GateEvent]) {
        // Map DB events → ToolEvent objects for the Feed tab
        let kindMap: [String: ToolEvent.EventKind] = [
            "bash": .bash, "dock": .dock, "build": .build,
            "edit": .edit, "read": .read, "write": .write,
            "net": .net, "tool_call": .bash,
        ]
        toolEvents = events.map { evt in
            ToolEvent(agentId: evt.agentId,
                      kind:    kindMap[evt.eventType] ?? .bash,
                      label:   evt.payload,
                      detail:  evt.output)
        }

        // Sound / voice / interaction callouts — each activity row fires at most once.
        for evt in events {
            let key: String
            if evt.rowid != 0 {
                key = "row:\(evt.rowid)"
            } else {
                key = "evt:\(evt.eventType)|\(evt.agentId)|\(evt.payload)|\(evt.output)|\(evt.at.timeIntervalSince1970)"
            }
            if seenSideEffectKeys.contains(key) { continue }
            seenSideEffectKeys.insert(key)
            // Bound memory: keep only recent keys
            if seenSideEffectKeys.count > 500 {
                seenSideEffectKeys = Set(seenSideEffectKeys.suffix(250))
            }

            switch evt.eventType {
            case "pet_memory_access":
                pets.signalMemoryAccess(for: evt.agentId)
            case "task_complete":
                if !alertsMuted {
                    sound.play(event: "task_complete")
                    voice.taskComplete(agentId: evt.agentId, summary: evt.payload)
                }
            case "approval_needed":
                if !alertsMuted {
                    sound.play(event: "approval_needed")
                    voice.approvalNeeded(agentId: evt.agentId, prompt: evt.payload)
                }
                // The card itself is never suppressed — muting silences output,
                // it does not hide a pending approval.
                pushInteraction(for: evt)
            case "entropy_warn":
                if !alertsMuted { sound.play(event: "entropy_warn") }
            case "blocked":
                if !alertsMuted { sound.play(event: "blocked") }
            default: break
            }
        }
    }

    /// Source of truth for open asks: agent_interactions rows with status=pending.
    /// IDs are always the real gate interaction_id (never a fresh UUID).
    private func syncPendingAsks(_ asks: [PendingGateAsk]) {
        let pendingIds = Set(asks.map(\.interactionId))
        // Drop cards that are no longer pending (resolved via UI or elsewhere).
        interactions.removeAll { !pendingIds.contains($0.id) }
        // Ensure every pending row has a card with the gate id.
        for ask in asks {
            if interactions.contains(where: { $0.id == ask.interactionId }) { continue }
            interactions.append(AgentInteraction(
                id: ask.interactionId,
                agentId: ask.agentId,
                prompt: ask.prompt,
                kind: .yesNo,
                timeoutAt: Date().addingTimeInterval(60),
                content: ask.interactionId
            ))
        }
    }

    private func checkResourceAlerts(_ m: SystemMetrics) {
        if m.thermalState >= 3 {
            voice.resourceAlert("CPU thermal throttling.")
        } else if m.cpuPercent > 95 {
            voice.resourceAlert("CPU above 95 percent.")
        }
    }

    private func pushInteraction(for evt: GateEvent) {
        // Gate writes interaction_id into event_output — never invent a UUID.
        let gateId = HubAskPipeline.gateInteractionId(
            eventOutput: evt.output,
            agentId: evt.agentId,
            at: evt.at
        )
        if interactions.contains(where: { $0.id == gateId }) { return }
        seenSideEffectKeys.insert("ask:\(gateId)")
        let interaction = AgentInteraction(
            id: gateId,
            agentId: evt.agentId,
            prompt: evt.payload,
            kind: .yesNo,
            timeoutAt: Date().addingTimeInterval(30),
            content: evt.output
        )
        interactions.append(interaction)
    }

    func resolveInteraction(_ id: String, approved: Bool, reply: String? = nil) {
        guard let ia = interactions.first(where: { $0.id == id }) else { return }
        // MUST send the gate interaction_id (ia.id), never a fresh UUID.
        GateSocketClient.shared.sendApproval(
            agentId:       ia.agentId,
            interactionId: ia.id,
            approved:      approved,
            reply:         reply
        )
        interactions.removeAll { $0.id == id }
    }

    /// Ping an agent over the gate socket. Real wire traffic — see
    /// GateSocketClient.sendPing for the delivery guarantee.
    func ping(_ agentId: String) {
        GateSocketClient.shared.sendPing(agentId: agentId)
        flash("pinged", for: agentId)
    }

    /// Send the inline composer's text to one agent, then close the composer.
    func sendComposed(to agentId: String) {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        GateSocketClient.shared.sendAgentMessage(agentId: agentId, text: text)
        // Persist alongside delegations so there is an on-disk record, matching
        // what submitDelegation already does for the broadcast bar.
        db.insertDelegation(agentId: agentId, taskText: text)
        delegations.insert(
            DelegationRecord(agentId: agentId, command: text, outcome: "sent", at: Date()),
            at: 0
        )
        composeText = ""
        composingAgentId = nil
        flash("sent", for: agentId)
    }

    func toggleComposer(for agentId: String) {
        if composingAgentId == agentId {
            composingAgentId = nil
        } else {
            composingAgentId = agentId
            composeText = ""
        }
    }

    func toggleExpanded(_ agentId: String) {
        expandedAgentId = expandedAgentId == agentId ? nil : agentId
    }

    /// Two-second confirmation chip on an agent card.
    private func flash(_ label: String, for agentId: String) {
        actionFeedback[agentId] = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.actionFeedback[agentId] == label else { return }
            self.actionFeedback[agentId] = nil
        }
    }

    func submitDelegation() {
        let text = delegateText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let target = selectedAgent ?? "broadcast"
        // Persist to SQLite (gate picks this up on next poll / query)
        db.insertDelegation(agentId: target, taskText: text)
        // Also deliver in real-time via the socket
        GateSocketClient.shared.sendDelegation(agentId: selectedAgent, command: text)
        let rec = DelegationRecord(agentId: target, command: text, outcome: "pending", at: Date())
        delegations.insert(rec, at: 0)
        delegateText    = ""
        showDelegateBar = false
    }

    func prefillDelegation(for agentId: String) {
        let snippet  = pets.readMemorySnippet(for: agentId, maxBytes: 200)
        let history  = pets.recentHistory(for: agentId, lines: 3)
        var fill     = "@\(AgentIdentity[agentId].shortKey) "
        if !history.isEmpty { fill += "\n// context: \(history.last ?? "")" }
        if !snippet.isEmpty  { fill += "\n// memory: \(snippet.prefix(80))…" }
        delegateText    = fill
        selectedAgent   = agentId
        showDelegateBar = true
    }
}

// MARK: - AgentDotView  (glow pulse, lock overlay, timeout arc, memory-access animation)

/// One dot in the popup header strip.
///
/// Data sources — every element is backed, nothing is decorative:
///   dot fill          → AgentIdentity brand colour; dimmed when agents.status
///                       is idle, so identity survives but live work stands out
///   status ring       → agents.status (absent while idle)
///   outer glow pulse  → agents.status == active
///   entropy arc       → agents.entropy_score / 12 bits, thresholded at
///                       kH_threshold (3.5) and kH_block (5.0)
///   timeout arc       → agent_interactions deadline for this agent's open ask
///   lock badge        → cloud agent with no Keychain token stored
///   cyan pulse dot    → a `pet_memory_access` row in agent_activity (2 s decay)
///   amber corner dot  → pets/<id>/state.json resumable flag
struct AgentDotView: View {
    let identity:     AgentIdentity
    let row:          AgentRow?
    let bench:        BenchmarkState?
    let interaction:  AgentInteraction?
    let isMemAccess:  Bool
    let isPetResumable: Bool

    @State private var glowPhase    = false
    @State private var memPulse     = false
    @State private var timeoutPct   = 0.0

    var body: some View {
        ZStack {
            // Outer glow — 30×30, active agents only
            if row?.status == .active {
                Circle()
                    .fill(identity.color.opacity(glowPhase ? 0.55 : 0.20))
                    .frame(width: 30, height: 30)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                               value: glowPhase)
            }

            // Entropy arc — full arc = healthy (H/12), draining arc = collapsing.
            // Color: identity.color when H ≥ kH_block (healthy ceiling),
            //        orange when approaching kH_block, red at/below kH_threshold.
            if let ent = row?.entropy {
                let frac = max(0, min(ent / 12.0, 1.0))
                let arcColor: Color = ent <= kH_threshold ? .hubError
                                    : ent < kH_block      ? .hubWarning
                                    :                        identity.palette.tint
                Circle()
                    .trim(from: 0, to: frac)
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundColor(arcColor)
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: frac)
            }

            // Core dot — 14×14. The fill is the *agent*, the ring is its
            // *status*. Colouring the fill by status (the old behaviour) made
            // all eight dots identical whenever the fleet was idle, which is
            // precisely when you most need to see who is who.
            Circle()
                .fill(dotColor)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle().strokeBorder(statusRing, lineWidth: 2)
                )
                // Keeps a light-coloured dot from dissolving into a white popup.
                .overlay(Circle().strokeBorder(Color.hubSeparator, lineWidth: 0.5))
                .overlay(
                    // Timeout countdown arc
                    Group {
                        if let ia = interaction, let deadline = ia.timeoutAt {
                            let remaining = max(0, deadline.timeIntervalSinceNow) / 30.0
                            Circle()
                                .trim(from: 0, to: CGFloat(1.0 - remaining))
                                .stroke(Color.hubWarning, lineWidth: 1.5)
                                .rotationEffect(.degrees(-90))
                        }
                    }
                )

            // Lock badge (cloud agent, no credential)
            if identity.authKind == .cloud && !KeychainHelper.hasToken(for: identity.id) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundColor(.hubError)
                    .offset(x: 7, y: -7)
            }

            // Memory-access pulsing dot (directive Pet)
            if isMemAccess {
                Circle()
                    .fill(Color.hubAccent.opacity(memPulse ? 0.9 : 0.35))
                    .frame(width: 4, height: 4)
                    .offset(x: 7, y: 7)
                    .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                               value: memPulse)
            }

            // Mid-task resume indicator
            if isPetResumable {
                Circle()
                    .fill(Color.hubWarning)
                    .frame(width: 4, height: 4)
                    .offset(x: -7, y: 7)
            }
        }
        .frame(width: 30, height: 30)
        .onAppear { glowPhase = true; memPulse = true }
        .onChange(of: isMemAccess) { _ in memPulse = isMemAccess }
        .help(tooltipText)
    }

    /// Agent identity — dimmed while idle so live work stands out.
    private var dotColor: Color {
        guard let row else { return .hubQuaternary }
        return row.status == .idle
            ? identity.palette.tint.opacity(0.40)
            : identity.palette.tint
    }

    /// Status ring around the identity dot; absent when nothing is happening.
    private var statusRing: Color {
        guard let row, row.status != .idle else { return .clear }
        return row.status.color
    }

    private var tooltipText: String {
        var parts: [String] = [identity.displayName]
        if let r = row {
            parts.append("Status: \(r.status.label)")
            let ent = r.entropy
            let verdict = ent <= kH_threshold
                ? "at/below collapse threshold \(String(format: "%.1f", kH_threshold))"
                : (ent < kH_block
                    ? "approaching block threshold \(String(format: "%.1f", kH_block))"
                    : "healthy")
            parts.append("Shannon entropy H=\(String(format: "%.2f", ent)) bits — \(verdict)")
            let secs = max(0, Int(-r.lastSeen.timeIntervalSinceNow))
            parts.append("Last gate message: \(secs)s ago")
            if !r.taskSummary.isEmpty { parts.append(r.taskSummary) }
        }
        if let b = bench {
            parts.append("Progress: \(b.progress)%")
            if let cf = b.bestCF    { parts.append("CF: \(String(format: "%.1f", cf))") }
            if let rm = b.bestRMSD  { parts.append("RMSD: \(String(format: "%.2f", rm))Å") }
        }
        if identity.authKind == .cloud && !KeychainHelper.hasToken(for: identity.id) {
            parts.append("⚠️ No API key in Keychain")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Diff Review View  (directive E — hover on @@ hunk header expands context)

struct DiffReviewView: View {
    let diff: String
    @State private var expandedHunks: Set<Int> = []

    private var lines: [DiffLine] { parseDiff(diff) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    diffRow(line: line)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 240)
        .background(Color.hubSurfaceSunken)
        .cornerRadius(8)
        .font(.system(.caption, design: .monospaced))
    }

    @ViewBuilder
    private func diffRow(line: DiffLine) -> some View {
        let isHunkHeader = line.kind == .header
        let isExpanded   = expandedHunks.contains(line.id)

        VStack(alignment: .leading, spacing: 0) {
            Text(line.text)
                .foregroundColor(line.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(line.bg)
                .background(isHunkHeader && isExpanded ? Color.hubSurfaceHover : .clear)

            // Expanded context hint
            if isHunkHeader && isExpanded {
                Text("◀ full context expanded")
                    .foregroundColor(.hubAccent)
                    .font(.system(size: 9))
                    .padding(.leading, 8)
            }
        }
        .onHover { hovering in
            if isHunkHeader && hovering {
                withAnimation(.spring(response: 0.25)) { expandedHunks.insert(line.id) }
            } else if isHunkHeader && !hovering {
                withAnimation(.spring(response: 0.25)) { expandedHunks.remove(line.id) }
            }
        }
    }
}

// MARK: - Plan Review View  (⌘Y approve, ⌘N deny, ⌘1-3 choices)

struct PlanReviewView: View {
    let interaction: AgentInteraction
    let onApprove:   () -> Void
    let onDeny:      () -> Void
    let onChoice:    (Int) -> Void
    /// Optional free-text reply — sent alongside approval when non-empty.
    var onReply:     ((String) -> Void)? = nil

    @State private var timeLeft:  Double = 30
    @State private var replyText: String = ""

    private var timer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    }

    private var identity: AgentIdentity { AgentIdentity[interaction.agentId] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header — who is asking
            HStack {
                Text(identity.icon)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(identity.shortName)
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(identity.palette.ink)
                    Text("needs your input")
                        .font(.system(size: 9))
                        .foregroundColor(.hubTertiary)
                }
                Spacer()
                // Timeout arc
                ZStack {
                    Circle().stroke(Color.hubQuaternary, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: CGFloat(1.0 - (timeLeft / 30.0)))
                        .stroke(Color.hubWarning, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 20, height: 20)
                Text("\(Int(timeLeft))s")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.hubWarning)
            }

            // Prompt — the agent's question
            Text(interaction.prompt)
                .font(.system(.body, design: .default))
                .foregroundColor(.hubPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Agent content — what the agent actually produced (scrollable)
            if !interaction.content.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(interaction.content)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.hubSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .background(Color.hubSurfaceSunken)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(identity.palette.edge, lineWidth: 1))
            }

            // Diff view (if present)
            if let d = interaction.diff, !d.isEmpty {
                DiffReviewView(diff: d)
            }

            // Optional reply — gentle invitation, never required
            if onReply != nil {
                HStack(spacing: 6) {
                    TextField("Reply to \(identity.shortName) (optional)…", text: $replyText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.hubSurface)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.hubSeparator, lineWidth: 1))
                        .onSubmit { submitReply(approved: true) }
                    if !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { submitReply(approved: true) } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(identity.palette.ink)
                        }
                        .buttonStyle(.plain)
                        .help("Send reply and approve")
                    }
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                switch interaction.kind {
                case .yesNo:
                    PlanButton(label: "Approve", key: "⌘Y", accent: .hubSuccess) { submitOrApprove() }
                    PlanButton(label: "Deny",    key: "⌘N", accent: .hubError)   { onDeny() }
                case .choice(let opts):
                    FlowLayout(spacing: 6) {
                        ForEach(Array(opts.enumerated()), id: \.offset) { i, opt in
                            PlanButton(label: "\(i+1). \(opt)", key: "⌘\(i+1)", accent: .hubAccent) {
                                onChoice(i)
                            }
                        }
                    }
                case .info:
                    PlanButton(label: "OK", key: "⌘Y", accent: .hubNeutral) { onApprove() }
                }
            }
        }
        .padding(12)
        .background(Color.hubSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(identity.palette.edge, lineWidth: 1))
        .shadow(color: .hubShadow, radius: 6, y: 2)
        .onReceive(timer) { _ in
            if timeLeft > 0 { timeLeft -= 0.5 }
        }
    }

    /// Approve, attaching the typed reply when present.
    private func submitOrApprove() {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let onReply {
            onReply(trimmed)
        } else {
            onApprove()
        }
    }

    private func submitReply(approved: Bool) {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onReply?(trimmed)
    }
}

private struct PlanButton: View {
    let label:   String
    let key:     String
    let accent:  Color
    let action:  () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Text(key).foregroundColor(.white.opacity(0.75)).font(.caption)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(isHovering ? accent : accent.opacity(0.88))
            .foregroundColor(.white)
            .cornerRadius(7)
            .shadow(color: accent.opacity(isHovering ? 0.35 : 0.20), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Tool Call Feed View  (Vibe Island style)

struct ToolCallFeedView: View {
    let events: [ToolEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(events.prefix(12)) { evt in
                ToolEventRow(evt: evt)
            }
        }
    }
}

private struct ToolEventRow: View {
    let evt: ToolEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(AgentIdentity[evt.agentId].icon).font(.caption)
                Text(evt.kind.rawValue)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(kindColor)
                Text(evt.label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.hubSecondary)
                    .lineLimit(1)
                Spacer()
                Text(timeAgo(evt.timestamp))
                    .font(.system(size: 9))
                    .foregroundColor(.hubTertiary)
            }
            if expanded && !evt.detail.isEmpty {
                Text(evt.detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.hubSecondary)
                    .padding(.leading, 22)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.spring(response: 0.2)) { expanded.toggle() } }
    }

    private var kindColor: Color {
        switch evt.kind {
        case .dock:  return HubAdaptive.color(day: 0x0E6E8C, night: 0x66E0FF)
        case .build: return HubAdaptive.color(day: 0x14663A, night: 0x66E08C)
        case .bash:  return HubAdaptive.color(day: 0x8A6708, night: 0xFFD966)
        case .edit:  return HubAdaptive.color(day: 0x7A2E9E, night: 0xE29CFF)
        case .read:  return .hubSecondary
        case .write: return HubAdaptive.color(day: 0x9C4A06, night: 0xFFAA5C)
        case .net:   return HubAdaptive.color(day: 0x1F5FA8, night: 0x7FC1FF)
        }
    }

    private func timeAgo(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60  { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        return "\(s/3600)h"
    }
}

// MARK: - Resource Bar Section  (CPU/GPU/RAM/SSD fill bars + battery)

struct ResourceBarSection: View {
    let m: SystemMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ResourceBar(label: "CPU", value: m.cpuPercent / 100,
                            warn: 0.75, critical: 0.95, color: .hubAccent)
                ResourceBar(label: "GPU", value: m.gpuPercent / 100,
                            warn: 0.80, critical: 0.95, color: HubAdaptive.color(day: 0x7A2E9E, night: 0xB07CFF))
            }
            HStack(spacing: 12) {
                ResourceBar(label: "RAM",
                            value: m.ramTotalGB > 0 ? m.ramUsedGB / m.ramTotalGB : 0,
                            warn: 0.75, critical: 0.90,
                            color: Color.hubSuccess,
                            detail: "\(String(format:"%.1f",m.ramUsedGB))/\(String(format:"%.0f",m.ramTotalGB))G")
                ResourceBar(label: "SSD",
                            value: m.ssdTotalGB > 0 ? m.ssdUsedGB / m.ssdTotalGB : 0,
                            warn: 0.85, critical: 0.95,
                            color: HubAdaptive.color(day: 0x8A6708, night: 0xFFC44D),
                            detail: "\(String(format:"%.0f",m.ssdUsedGB))/\(String(format:"%.0f",m.ssdTotalGB))G")
            }
            if m.batteryPct >= 0 {
                BatteryRow(m: m)
            }
            if m.thermalState >= 2 {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.high")
                    Text(thermalLabel(m.thermalState))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(m.thermalState >= 3 ? .hubError : .hubWarning)
            }
        }
    }
    private func thermalLabel(_ s: Int) -> String {
        switch s { case 3: return "THERMAL CRITICAL"; case 2: return "Thermal Serious"; default: return "" }
    }
}

private struct ResourceBar: View {
    let label:    String
    let value:    Double     // 0…1
    let warn:     Double
    let critical: Double
    let color:    Color
    var detail:   String = ""

    @State private var pulse = false

    private var barColor: Color {
        if value >= critical { return .hubError }
        if value >= warn     { return .hubWarning }
        return color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 9, weight: .medium))
                    .foregroundColor(.hubSecondary)
                Spacer()
                Text(detail.isEmpty ? "\(Int(value * 100))%" : detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.hubQuaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor.opacity(pulse ? 0.55 : 1.0))
                        .frame(width: geo.size.width * min(max(value, 0), 1))
                        .animation(.easeOut(duration: 0.4), value: value)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: value) { v in
            if v >= warn { withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { pulse = true } }
            else { pulse = false }
        }
    }
}

private struct BatteryRow: View {
    let m: SystemMetrics
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: m.isCharging ? "battery.100.bolt" : batteryIcon)
                .foregroundColor(batteryColor)
                .font(.caption)
            Text(m.batteryPct < 0 ? "AC" : "\(Int(m.batteryPct))%")
                .font(.system(size: 10))
                .foregroundColor(batteryColor)
            if m.batteryWatts > 0.1 {
                Text("\(String(format:"%.1f",m.batteryWatts))W")
                    .font(.system(size: 9))
                    .foregroundColor(.hubTertiary)
            }
        }
    }
    private var batteryIcon: String {
        let p = m.batteryPct
        if p > 75 { return "battery.100" }
        if p > 50 { return "battery.75" }
        if p > 25 { return "battery.50" }
        if p > 10 { return "battery.25" }
        return "battery.0"
    }
    private var batteryColor: Color {
        if m.isCharging { return .hubSuccess }
        if m.batteryPct < 15 { return .hubError }
        if m.batteryPct < 30 { return .hubWarning }
        return .hubSecondary
    }
}

// MARK: - Delegation Command Bar  (directive K — Space→mode, @ agent picker, pet pre-fill)

struct DelegationBarView: View {
    @ObservedObject var vm: HubViewModel
    @FocusState private var focused: Bool
    @State private var showAgentPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Quick-pick agents
            if showAgentPicker {
                HStack(spacing: 8) {
                    ForEach(AgentIdentity.all) { a in
                        Button {
                            vm.prefillDelegation(for: a.id)
                            showAgentPicker = false
                            focused = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(a.icon).font(.caption)
                                Text("@\(a.shortKey)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(a.palette.wash)
                            .foregroundColor(a.palette.ink)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }

            // Text field
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundColor(.hubTertiary)
                    .font(.caption)
                TextField("@agent command  ·  ⌘A=broadcast", text: $vm.delegateText)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.hubPrimary)
                    .focused($focused)
                    .onSubmit { vm.submitDelegation() }
                    .onChange(of: vm.delegateText) { text in
                        showAgentPicker = text == "@"
                    }
                Button("Send", action: vm.submitDelegation)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(
                        vm.delegateText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? .hubTertiary : .hubAccent
                    )
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.hubSurface)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(focused ? Color.hubAccent : Color.hubSeparator,
                                  lineWidth: focused ? 1.5 : 1)
            )

            // Recent delegations
            if !vm.delegations.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(vm.delegations.prefix(4)) { rec in
                        HStack(spacing: 6) {
                            Text(AgentIdentity[rec.agentId].icon).font(.caption)
                            Text(rec.command.prefix(48))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.hubSecondary)
                                .lineLimit(1)
                            Spacer()
                            Text(rec.outcome)
                                .font(.system(size: 9))
                                .foregroundColor(rec.outcome == "approved" ? Color.hubSuccess : Color.hubTertiary)
                        }
                    }
                }
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Settings View  (voice per-agent toggles, sound event toggles, Keychain)

struct SettingsView: View {
    @ObservedObject var voice: VoiceController
    @State private var cloudAuth: [String: Bool] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Voice Callouts")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.hubPrimary)
                ForEach(AgentIdentity.all) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(a.icon) \(a.shortName)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(a.palette.ink)
                        ForEach(["task_complete", "approval_needed", "resource_alert"], id: \.self) { evt in
                            let key = "\(a.id).\(evt)"
                            Toggle(evt.replacingOccurrences(of: "_", with: " "),
                                   isOn: Binding(
                                    get: { voice.enabledCallouts.contains(key) },
                                    set: { if $0 { voice.enabledCallouts.insert(key) }
                                           else  { voice.enabledCallouts.remove(key) } }
                                   ))
                            .toggleStyle(.switch)
                            .font(.system(size: 10))
                        }
                    }
                    .padding(.leading, 8)
                }

                Divider().overlay(Color.hubSeparator)
                Text("Cloud Credentials (Keychain)")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.hubPrimary)
                ForEach(AgentIdentity.all.filter { $0.authKind == .cloud }) { a in
                    HStack {
                        Text("\(a.icon) \(a.shortName)")
                        Spacer()
                        if KeychainHelper.hasToken(for: a.id) {
                            Text("🔑 Stored").foregroundColor(.hubSuccess).font(.caption)
                        } else {
                            Text("⚠️ Missing").foregroundColor(.hubWarning).font(.caption)
                        }
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(12)
        }
        .background(Color.hubBackground)
    }
}

// MARK: - Main Popover Content View

struct HubPopoverView: View {
    @ObservedObject var vm: HubViewModel
    @State private var selectedTab = 0          // 0=agents 1=feed 2=resources

    var body: some View {
        VStack(spacing: 0) {
            // ── Pill header ──────────────────────────────────────────
            pillHeader

            // ── Inline agent detail (tap a dot to expand) ────────────
            if let aid = vm.expandedAgentId,
               let identity = AgentIdentity.all.first(where: { $0.id == aid }) {
                Divider().overlay(Color.hubSeparator)
                AgentInlineDetail(
                    identity:   identity,
                    row:        vm.db.agents[aid],
                    bench:      vm.db.benchmarks[aid],
                    pet:        vm.pets.states[aid] ?? PetState(),
                    onDelegate: {
                        vm.prefillDelegation(for: aid)
                        vm.expandedAgentId = nil
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().overlay(Color.hubSeparator)

            // ── Tab selector ─────────────────────────────────────────
            tabPicker

            // ── Tab content ──────────────────────────────────────────
            ZStack {
                switch selectedTab {
                case 0: agentsTab
                case 1: feedTab
                case 2: resourcesTab
                default: EmptyView()
                }
            }
            .frame(minHeight: 220)

            // ── Pending interactions ─────────────────────────────────
            if !vm.interactions.isEmpty {
                Divider().overlay(Color.hubSeparator)
                interactionsPanel
            }

            // ── Persistent delegation bar ────────────────────────────
            Divider().overlay(Color.hubSeparator)
            DelegationBarView(vm: vm)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(width: 420)
        // Opaque, not `.ultraThinMaterial`. Blur was letting whatever window sat
        // behind the popup bleed through the agent cards; in daylight that
        // reduced a precision readout to a smear. The instrument gets its own
        // solid ground and no longer forces `.dark`.
        .background(Color.hubBackground)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: vm.expandedAgentId)
    }

    // MARK: Pill header with agent dots

    private var pillHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(AgentIdentity.all) { a in
                    AgentDotView(
                        identity:       a,
                        row:            vm.db.agents[a.id],
                        bench:          vm.db.benchmarks[a.id],
                        interaction:    vm.interactions.first { $0.agentId == a.id },
                        isMemAccess:    vm.pets.memoryAccessingAgents.contains(a.id),
                        isPetResumable: vm.pets.states[a.id]?.resumable ?? false
                    )
                    // Selection ring — appears when this dot is expanded
                    .overlay(
                        Circle()
                            .stroke(a.palette.tint, lineWidth: 1.5)
                            .opacity(vm.expandedAgentId == a.id ? 1 : 0)
                            .padding(-3)
                    )
                    .onTapGesture {
                        withAnimation {
                            vm.toggleExpanded(a.id)
                        }
                    }
                }
            }
            Spacer()
            // Worst-case entropy badge — shows min entropy across agents when
            // any agent falls below kH_block (deception risk zone).
            // Source: min(agents.entropy_score).
            if let minEnt = vm.db.agents.values.map(\.entropy).min(), minEnt < kH_block {
                Text("H=\(String(format:"%.1f",minEnt))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(minEnt <= kH_threshold ? .hubError : .hubWarning)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(minEnt <= kH_threshold ? AgentStatus.error.wash : AgentStatus.waiting.wash)
                    .cornerRadius(4)
                    .help("Lowest entropy across all agents: H=\(String(format: "%.2f", minEnt)) bits. "
                          + "Collapse threshold \(String(format: "%.1f", kH_threshold)), "
                          + "block threshold \(String(format: "%.1f", kH_block)).")
            }

            // Broadcast — opens the delegation bar with no agent selected, which
            // sends to every connected agent via the gate's own broadcast path.
            IconAction(
                systemName: "megaphone",
                tooltip: "Broadcast a command to all connected agents",
                tint: .hubAccent,
                isOn: vm.showDelegateBar && vm.selectedAgent == nil
            ) {
                vm.selectedAgent = nil
                vm.showDelegateBar.toggle()
            }

            // Mute is deliberately *not* "Pause all": the gate exposes no way to
            // suspend agents, so this only silences this hub's sound and voice.
            IconAction(
                systemName: vm.alertsMuted ? "bell.slash" : "bell",
                tooltip: vm.alertsMuted
                    ? "Alerts muted — click to unmute sound and voice"
                    : "Mute this hub's sound and voice alerts (agents keep running)",
                tint: vm.alertsMuted ? .hubWarning : .hubSecondary,
                isOn: vm.alertsMuted
            ) {
                vm.alertsMuted.toggle()
            }

            IconAction(
                systemName: "gear",
                tooltip: "Voice, sound and credential settings",
                tint: .hubSecondary,
                isOn: vm.showSettings
            ) {
                vm.showSettings = true
            }
            .popover(isPresented: $vm.showSettings) {
                SettingsView(voice: vm.voice).frame(width: 300, height: 420)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Tab picker (3 tabs — Delegate moved to persistent bar)

    /// Segmented control on a recessed track. The selected tab is a raised white
    /// chip with an accent underline — on a light ground, "selected" has to be
    /// carried by elevation and a hard accent mark, since a subtle fill tint
    /// reads as nothing at all in bright light.
    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach([("Agents","person.3"), ("Feed","bolt"),
                     ("Resources","cpu")].enumerated().map { $0 }, id: \.offset) { i, tab in
                let selected = selectedTab == i
                Button {
                    withAnimation(.spring(response: 0.25)) { selectedTab = i }
                } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.1).font(.system(size: 10, weight: .medium))
                            Text(tab.0)
                                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                        }
                        Capsule()
                            .fill(selected ? Color.hubAccent : .clear)
                            .frame(height: 2)
                            .padding(.horizontal, 10)
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity)
                    .background(selected ? Color.hubSurface : .clear)
                    .foregroundColor(selected ? .hubPrimary : .hubSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.hubSurfaceSunken)
    }

    // MARK: Agents tab

    private var agentsTab: some View {
        let streaming = vm.db.streamingAgents
        return ScrollView {
            VStack(spacing: 8) {
                ForEach(AgentIdentity.all) { a in
                    AgentRowCard(
                        identity:    a,
                        row:         vm.db.agents[a.id],
                        bench:       vm.db.benchmarks[a.id],
                        pet:         vm.pets.states[a.id] ?? PetState(),
                        isStreaming: streaming.contains(a.id),
                        isExpanded:  vm.expandedAgentId == a.id,
                        isComposing: vm.composingAgentId == a.id,
                        feedback:    vm.actionFeedback[a.id],
                        messages:    vm.db.messages[a.id] ?? [],
                        composeText: $vm.composeText,
                        onToggleExpand:  { vm.toggleExpanded(a.id) },
                        onToggleCompose: { vm.toggleComposer(for: a.id) },
                        onSend:          { vm.sendComposed(to: a.id) },
                        onPing:          { vm.ping(a.id) }
                    )
                }
            }
            .padding(10)
        }
    }

    // MARK: Feed tab

    private var feedTab: some View {
        ScrollView {
            ToolCallFeedView(events: vm.toolEvents)
                .padding(10)
        }
    }

    // MARK: Resources tab

    private var resourcesTab: some View {
        ScrollView {
            ResourceBarSection(m: vm.sysmon.metrics)
                .padding(12)
        }
    }

    // MARK: Interactions panel

    private var interactionsPanel: some View {
        VStack(spacing: 6) {
            ForEach(vm.interactions) { ia in
                PlanReviewView(
                    interaction: ia,
                    onApprove: { vm.resolveInteraction(ia.id, approved: true) },
                    onDeny:    { vm.resolveInteraction(ia.id, approved: false) },
                    onChoice:  { _ in vm.resolveInteraction(ia.id, approved: true) },
                    onReply:   { text in vm.resolveInteraction(ia.id, approved: true, reply: text) }
                )
            }
        }
        .padding(8)
    }
}

// MARK: - Agent Inline Detail  (shown when a dot in pillHeader is tapped)

private struct AgentInlineDetail: View {
    let identity:   AgentIdentity
    let row:        AgentRow?
    let bench:      BenchmarkState?
    let pet:        PetState
    let onDelegate: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Entropy arc + H value
            ZStack {
                let ent = row?.entropy ?? 0
                let frac = max(0, min(ent / 12.0, 1.0))
                let arcColor: Color = ent <= kH_threshold ? .hubError
                                    : ent < kH_block      ? .hubWarning
                                    :                        identity.palette.tint
                Circle()
                    .stroke(Color.hubQuaternary, lineWidth: 2)
                    .frame(width: 32, height: 32)
                Circle()
                    .trim(from: 0, to: frac)
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundColor(arcColor)
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(-90))
                Text(String(format: "%.1f", ent))
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(arcColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(identity.icon) \(identity.displayName)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(identity.palette.ink)
                    Text(identity.modelTag)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.hubTertiary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.hubSurfaceElevated)
                        .cornerRadius(3)
                    // Status badge
                    let s = row?.status ?? .idle
                    Text(s.label)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(s.color)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(s.wash)
                        .cornerRadius(3)
                    Spacer()
                }
                if let r = row, !r.taskSummary.isEmpty {
                    Text(r.taskSummary)
                        .font(.system(size: 9))
                        .foregroundColor(.hubSecondary)
                        .lineLimit(2)
                }
                if let b = bench, b.progress > 0 {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(b.progress) / 100.0)
                            .progressViewStyle(.linear)
                            .tint(identity.palette.tint)
                            .frame(width: 80)
                        Text("\(b.progress)%")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.hubSecondary)
                        if let cf = b.bestCF {
                            Text("CF=\(String(format:"%.1f",cf))")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(identity.palette.ink)
                        }
                        if let rm = b.bestRMSD {
                            Text("RMSD=\(String(format:"%.2f",rm))Å")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.hubTertiary)
                        }
                    }
                }
                if !pet.lastTask.isEmpty {
                    Text("pet: \(pet.lastTask.prefix(60))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.hubAccent)
                }
            }

            Button(action: onDelegate) {
                Label("Delegate", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(identity.palette.ink)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(identity.palette.wash)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(identity.palette.wash)
    }
}

// MARK: - Agent Row Card

/// One agent row in the Agents tab.
///
/// Data sources — every visual element maps to a real signal, no decoration:
///   identity rail colour   → AgentIdentity brand colour (agent_identity.py)
///   emoji glyph            → AgentIdentity.icon for this agent id
///   entropy arc            → agents.entropy_score, thresholded at
///                            kH_threshold (3.5, amber) / kH_block (5.0, red)
///   H readout + word       → same entropy_score, labelled against the thresholds
///   status badge           → agents.status (the gate's status string)
///   relative timestamp     → agents.last_seen_ns, i.e. time since this agent's
///                            last gate message
///   streaming bars         → a row in agent_messages within the last 3 s; this
///                            is strictly narrower than status == active
///   progress bar / CF      → benchmark_state.completed and state_json
///   pet line               → ~/.shannon/pets/<id>/state.json last_task
///   message list           → agent_messages rows for this agent
///
/// The one exception is the companion glyph next to the model tag
/// (AgentIdentity.petSymbol): it is fixed branding per agent and carries no
/// runtime signal, so it must never be styled to look like status.
private struct AgentRowCard: View {
    let identity:    AgentIdentity
    let row:         AgentRow?
    let bench:       BenchmarkState?
    let pet:         PetState
    let isStreaming: Bool
    let isExpanded:  Bool
    let isComposing: Bool
    let feedback:    String?
    let messages:    [AgentMessageRow]
    @Binding var composeText: String
    let onToggleExpand:  () -> Void
    let onToggleCompose: () -> Void
    let onSend:          () -> Void
    let onPing:          () -> Void

    @State private var isHovering = false

    private var status: AgentStatus { row?.status ?? .idle }
    private var isLive: Bool { status == .active || status == .waiting }
    /// Ping is only offered for agents the registry actually knows about —
    /// pinging an agent with no gate record would be a button that does nothing.
    private var canPing: Bool { row != nil && !isLive }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Identity rail — one saturated stripe per agent scans faster
                // down a column than eight tinted rectangles.
                Rectangle()
                    .fill(identity.palette.tint)
                    .frame(width: 3)
                    .opacity(isLive ? 1 : 0.45)

                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 2) {
                        ZStack {
                            entropyArc
                            Text(identity.icon).font(.title3)
                        }
                        .help(entropyTooltip)
                        Text(identity.shortName)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.hubSecondary)
                    }
                    .frame(width: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        header
                        if let r = row, !r.taskSummary.isEmpty {
                            Text(r.taskSummary)
                                .font(.system(size: 9.5))
                                .foregroundColor(.hubSecondary)
                                .lineLimit(2)
                                .help("Latest task summary the gate recorded for this agent")
                        }
                        entropyReadout
                        benchmarkRow
                        if !pet.lastTask.isEmpty {
                            Text("pet: \(pet.lastTask.prefix(50))")
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundColor(.hubTertiary)
                                .help("Last task persisted to ~/.shannon/pets/\(identity.id)/state.json")
                        }
                    }

                    Spacer(minLength: 0)
                    actionCluster
                }
                .padding(10)
            }

            if isComposing { composer }
            if isExpanded { messageList }
        }
        .background(isHovering ? Color.hubSurfaceHover : Color.clear)
        .background(Color.hubSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isExpanded ? identity.palette.edge : Color.hubSeparator,
                              lineWidth: isExpanded ? 1.5 : 1)
        )
        .shadow(color: .hubShadow, radius: isHovering ? 5 : (isLive ? 4 : 2), y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpand)
        .onHover { hovering in
            isHovering = hovering
            // Explicit affordance: the whole card is a disclosure control.
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(isExpanded ? "Click to collapse" : "Click to see recent gate messages")
        .animation(.spring(response: 0.26, dampingFraction: 0.85), value: isExpanded)
        .animation(.spring(response: 0.26, dampingFraction: 0.85), value: isComposing)
    }

    // MARK: Header line

    private var header: some View {
        HStack(spacing: 6) {
            Text(identity.displayName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(identity.palette.ink)
            Text(identity.modelTag)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.hubSecondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.hubSurfaceElevated)
                .cornerRadius(3)
                .help("Underlying model family")
            // Companion glyph — fixed per agent, part of its visual identity.
            Image(systemName: identity.petSymbol)
                .font(.system(size: 9))
                .foregroundColor(identity.palette.tint)
                .help("\(identity.displayName)'s companion: the \(identity.petName)")
            // Streaming bars: gate messages arriving right now.
            if isStreaming {
                StreamingBars(color: identity.palette.tint)
                    .help("Streaming — this agent sent a gate message in the last 3 s")
            }
            Spacer(minLength: 0)
            if let feedback {
                Text(feedback)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(.hubSuccess)
                    .transition(.opacity)
            }
            if let r = row {
                Text(relativeTime(r.lastSeen))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundColor(.hubTertiary)
                    .help("Time since this agent's last gate message (agents.last_seen_ns)")
            }
            statusBadge
        }
    }

    // MARK: Actions

    private var actionCluster: some View {
        VStack(spacing: 4) {
            IconAction(
                systemName: "bubble.left",
                tooltip: "Send a message to \(identity.displayName) via the gate",
                tint: identity.palette.ink,
                isOn: isComposing,
                action: onToggleCompose
            )
            if canPing {
                IconAction(
                    systemName: "bell",
                    tooltip: "Ping \(identity.displayName) over the gate socket",
                    tint: .hubSecondary,
                    isOn: false,
                    action: onPing
                )
            }
        }
        // Actions stay visible while the card is hovered or already engaged, so
        // they never become a hidden feature.
        .opacity(isHovering || isComposing ? 1 : 0.45)
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("Message \(identity.displayName)…", text: $composeText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.hubSurface)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(identity.palette.edge, lineWidth: 1))
                .onSubmit(onSend)
            Button(action: onSend) {
                Text("Send")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        composeText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? Color.hubQuaternary : identity.palette.ink
                    )
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(composeText.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Deliver this text to \(identity.displayName) through the gate")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        // Swallow the tap so typing in the composer does not collapse the card.
        .onTapGesture {}
    }

    // MARK: Expanded message history

    private var messageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.hubSeparator)
            if messages.isEmpty {
                Text("No gate messages recorded for this agent yet.")
                    .font(.system(size: 9.5))
                    .foregroundColor(.hubTertiary)
                    .padding(10)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(messages) { m in
                        HStack(alignment: .top, spacing: 6) {
                            Text(m.messageType)
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundColor(identity.palette.ink)
                                .frame(width: 84, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                if !m.summary.isEmpty {
                                    Text(m.summary)
                                        .font(.system(size: 9.5))
                                        .foregroundColor(.hubPrimary)
                                        .lineLimit(3)
                                }
                                HStack(spacing: 6) {
                                    if let h = m.gateH {
                                        Text("H \(String(format: "%.2f", h))")
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundColor(
                                                h <= kH_threshold ? .hubError
                                                    : (h < kH_block ? .hubWarning : .hubTertiary)
                                            )
                                            .help("Entropy the gate computed for this message")
                                    }
                                    if !m.gateDecision.isEmpty {
                                        Text(m.gateDecision)
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundColor(
                                                m.gateDecision == "allowed" ? .hubSecondary : .hubWarning
                                            )
                                            .help("Gate verdict for this message")
                                    }
                                    Spacer(minLength: 0)
                                    Text(relativeTime(m.at))
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundColor(.hubTertiary)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(Color.hubSurfaceSunken)
    }

    // MARK: Sub-elements

    @ViewBuilder
    private var benchmarkRow: some View {
        if let b = bench, b.progress > 0 {
            HStack(spacing: 6) {
                ProgressView(value: Double(b.progress) / 100.0)
                    .progressViewStyle(.linear)
                    .tint(identity.palette.tint)
                    .frame(width: 80)
                Text("\(b.progress)%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.hubSecondary)
                if let cf = b.bestCF {
                    Text("CF=\(String(format:"%.1f",cf))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(identity.palette.ink)
                        .help("Best complementarity function score so far")
                }
            }
            .help("Benchmark progress — benchmark_state.completed")
        }
    }

    /// Entropy state as a word plus the number, so reading it does not require
    /// memorising the thresholds. Source: agents.entropy_score.
    @ViewBuilder
    private var entropyReadout: some View {
        if let ent = row?.entropy {
            let collapsing = ent <= kH_threshold
            let drifting   = ent < kH_block
            let c: Color = collapsing ? .hubError : (drifting ? .hubWarning : .hubSecondary)
            HStack(spacing: 5) {
                Text("H \(String(format: "%.1f", ent))")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(c)
                Text(collapsing ? "collapse" : (drifting ? "drifting" : "healthy"))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(c)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(
                        (collapsing ? AgentStatus.error.wash
                         : drifting ? AgentStatus.waiting.wash
                         : Color.hubSurfaceElevated)
                    )
                    .cornerRadius(3)
            }
            .help(entropyTooltip)
        }
    }

    private var entropyTooltip: String {
        guard let ent = row?.entropy else {
            return "No entropy recorded for this agent yet"
        }
        let verdict: String
        if ent <= kH_threshold {
            verdict = "at or below the collapse threshold \(String(format: "%.1f", kH_threshold))"
        } else if ent < kH_block {
            verdict = "approaching the block threshold \(String(format: "%.1f", kH_block))"
        } else {
            verdict = "above the block threshold \(String(format: "%.1f", kH_block)) — healthy"
        }
        return "Shannon entropy H=\(String(format: "%.2f", ent)) bits — \(verdict)"
    }

    /// Half-circle entropy gauge behind the agent emoji.
    private var entropyArc: some View {
        let ent  = row?.entropy ?? 0
        let frac = CGFloat(min(ent / kH_block, 1.0))
        let fill: Color = ent >= kH_block       ? .hubError
                        : ent >= kH_threshold   ? .hubWarning
                        : identity.palette.tint
        return ZStack {
            Circle()
                .trim(from: 0.5, to: 1.0)
                .stroke(Color.hubQuaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0.5, to: 0.5 + frac * 0.5)
                .stroke(fill, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .animation(.easeInOut(duration: 0.5), value: frac)
        }
        .frame(width: 28, height: 28)
    }

    /// Human-readable elapsed time since an agent was last active.
    private func relativeTime(_ date: Date) -> String {
        let secs = max(0, Int(-date.timeIntervalSinceNow))
        if secs < 5  { return "now" }
        if secs < 60 { return "\(secs)s ago" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h ago"
    }

    private var statusBadge: some View {
        let s = status
        return Text(s.label)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(s.color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(s.wash)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(s.color.opacity(0.30), lineWidth: 0.5))
            .cornerRadius(4)
            .help("Gate status for this agent (agents.status)")
    }
}

/// Small square icon button with a hover state and a real cursor affordance.
private struct IconAction: View {
    let systemName: String
    let tooltip:    String
    let tint:       Color
    let isOn:       Bool
    let action:     () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isOn ? .white : tint)
                .frame(width: 22, height: 20)
                .background(isOn ? tint : (hovering ? Color.hubSurfaceElevated : .clear))
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isOn ? .clear : Color.hubSeparator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// Three bars that animate only while gate messages are actually arriving.
/// Driven by TimelineView so it costs nothing when not rendered.
private struct StreamingBars: View {
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 2, height: barHeight(i: i, t: t))
                }
            }
            .frame(height: 10)
        }
    }

    private func barHeight(i: Int, t: Double) -> CGFloat {
        let phases: [Double] = [0.0, 1.1, 2.2]
        let amp = (sin(t * 3.0 + phases[i]) + 1.0) * 0.5
        return CGFloat(3 + amp * 7)
    }
}

// MARK: - Status Bar Controller  (NSStatusItem — dots-only pill)

final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover:    NSPopover!
    private var hostingView: NSHostingView<HubPopoverView>?
    private let vm = HubViewModel()
    private var keyMonitor: Any?

    override init() {
        super.init()
        setupStatusItem()
        setupPopover()
        setupKeyboardMonitor()
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: Status Item — dots-only pill

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let btn = statusItem.button else { return }
        btn.target = self
        btn.action = #selector(togglePopover(_:))
        updatePill()

        // Re-draw pill every 2s to reflect live status
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updatePill() }
        }
    }

    /// Agents considered "live": seen by the gate within this window.
    /// Beyond it an agent row is stale and must not be reported as healthy.
    private static let livenessWindow: TimeInterval = 120

    /// One coloured dot → instant system health read.
    ///
    /// Data sources: `agents.status` (liveness) and `agents.last_seen_ns`
    /// (recency). Both matter — a row stuck at status "active" whose last_seen
    /// is an hour old is a dead agent, not a working one, and used to render
    /// the same orange as a genuinely busy fleet.
    ///
    ///   red   → any agent blocked or errored
    ///   orange→ any agent active/waiting *and* seen within livenessWindow
    ///   green → agents known and recent, none busy
    ///   dim   → no rows at all, or every row is stale
    private func healthColor() -> NSColor {
        let rows = AgentIdentity.all.compactMap { vm.db.agents[$0.id] }
        if rows.isEmpty { return NSColor.secondaryLabelColor }
        let cutoff = Date().addingTimeInterval(-Self.livenessWindow)
        let fresh = rows.filter { $0.lastSeen > cutoff }
        if fresh.isEmpty { return NSColor.secondaryLabelColor }
        if fresh.contains(where: { $0.status == .blocked || $0.status == .error }) {
            return NSColor.systemRed
        }
        if fresh.contains(where: { $0.status == .active || $0.status == .waiting }) {
            return NSColor.systemOrange
        }
        return NSColor.systemGreen
    }

    /// Menu-bar pill: single coloured dot for instant health + wave glyph during activity.
    private func updatePill() {
        guard let btn = statusItem.button else { return }
        let hColor = healthColor()
        let attr = NSMutableAttributedString(
            string: "●",
            attributes: [
                .foregroundColor: hColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium)
            ]
        )
        // ∿ wave means *streaming right now*, not merely "status == active".
        // Source: a row in agent_messages within AuditDBReader.streamingWindow
        // (3 s). status == active persists long after an agent stops emitting,
        // so keying the wave off it left the menu bar animating over a fleet
        // that had gone quiet.
        let isStreaming = !vm.db.streamingAgents.isEmpty
        if isStreaming {
            attr.append(NSAttributedString(
                string: " ∿",
                attributes: [
                    .foregroundColor: hColor.withAlphaComponent(0.7),
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                ]
            ))
        }
        btn.attributedTitle = attr
        btn.toolTip = menuBarTooltip()
    }

    /// Spells out what the dot and wave currently mean, from the same rows that
    /// drew them.
    private func menuBarTooltip() -> String {
        let rows = AgentIdentity.all.compactMap { id -> (String, AgentRow)? in
            vm.db.agents[id.id].map { (id.shortName, $0) }
        }
        guard !rows.isEmpty else { return "Shannon — no agents registered yet" }
        let cutoff = Date().addingTimeInterval(-Self.livenessWindow)
        let fresh = rows.filter { $0.1.lastSeen > cutoff }
        if fresh.isEmpty {
            return "Shannon — \(rows.count) agent(s) known, none seen in the last 2 min"
        }
        let streaming = vm.db.streamingAgents
        var lines = ["Shannon — \(fresh.count) agent(s) active in the last 2 min"]
        for (name, row) in fresh.sorted(by: { $0.1.lastSeen > $1.1.lastSeen }).prefix(6) {
            let secs = max(0, Int(-row.lastSeen.timeIntervalSinceNow))
            let mark = streaming.contains(row.agentId) ? " ∿" : ""
            lines.append("  \(name): \(row.status.label) · H \(String(format: "%.1f", row.entropy)) · \(secs)s ago\(mark)")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) }
        else              { showPopover() }
    }

    private func showPopover() {
        guard let btn = statusItem.button else { return }
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Popover setup

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior        = .transient
        popover.animates        = true
        popover.delegate        = self
        let content             = HubPopoverView(vm: vm)
        let hosting             = NSHostingController(rootView: content)
        popover.contentViewController = hosting
        popover.contentSize     = CGSize(width: 420, height: 580)
    }

    // MARK: Keyboard monitor  (directive H — Y/N/1-9/Tab/Space/Esc/⌘A/⌘Return)

    private func setupKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            return self.handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags
        let ch    = event.charactersIgnoringModifiers ?? ""

        // ⌘A — broadcast delegation
        if flags.contains(.command) && ch == "a" {
            vm.selectedAgent = nil
            vm.showDelegateBar = true
            return nil
        }
        // ⌘Return — submit delegation
        if flags.contains(.command) && event.keyCode == 36 {
            vm.submitDelegation()
            return nil
        }
        // ⌘Y — approve first interaction
        if flags.contains(.command) && ch == "y", let ia = vm.interactions.first {
            vm.resolveInteraction(ia.id, approved: true)
            SoundController.shared.play(event: "task_complete")
            return nil
        }
        // ⌘N — deny first interaction
        if flags.contains(.command) && ch == "n", let ia = vm.interactions.first {
            vm.resolveInteraction(ia.id, approved: false)
            return nil
        }
        // 1-9 — choice selection
        if let digit = Int(ch), (1...9).contains(digit), let ia = vm.interactions.first,
           case .choice(let opts) = ia.kind, digit <= opts.count {
            vm.resolveInteraction(ia.id, approved: true)
            return nil
        }
        // Space — toggle delegation bar
        if ch == " " && !flags.contains(.command) && !vm.showDelegateBar {
            vm.showDelegateBar = true
            return nil
        }
        // Escape — close delegate bar or popover
        if event.keyCode == 53 {
            if vm.showDelegateBar { vm.showDelegateBar = false; return nil }
            popover.performClose(nil)
            return nil
        }
        // Tab — cycle selected agent
        if ch == "\t" {
            cycleAgent()
            return nil
        }
        // Y / N without modifier — approve / deny
        if ch.lowercased() == "y" && !flags.contains(.command), let ia = vm.interactions.first {
            vm.resolveInteraction(ia.id, approved: true); return nil
        }
        if ch.lowercased() == "n" && !flags.contains(.command), let ia = vm.interactions.first {
            vm.resolveInteraction(ia.id, approved: false); return nil
        }

        return event
    }

    private func cycleAgent() {
        let ids = AgentIdentity.all.map(\.id)
        if let cur = vm.selectedAgent, let idx = ids.firstIndex(of: cur) {
            vm.selectedAgent = ids[(idx + 1) % ids.count]
        } else {
            vm.selectedAgent = ids.first
        }
    }

    // NSPopoverDelegate
    func popoverDidClose(_ notification: Notification) {
        vm.showDelegateBar = false
    }
}

// MARK: - App Entry Point

@main
struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No windows — pure menu bar app
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
        // Ensure ~/.shannon/ and pet directories exist
        PetManager.shared.ensureBaseDir()
        // Boot status bar
        statusBarController = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Mark any active agents as "resumable" in their pet state
        let db = AuditDBReader()
        for (id, row) in db.agents where row.status == .active {
            var state       = PetManager.shared.loadState(for: id)
            state.resumable = true
            state.status    = "mid_task"
            state.updatedAt = Date()
            PetManager.shared.saveState(state, for: id)
        }
    }
}
