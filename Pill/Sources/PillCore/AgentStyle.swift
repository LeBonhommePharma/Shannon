import Foundation
import ShannonTheme
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Visual + naming identity for a known agent (pill + menu bar).
///
/// Palette aligned with `hub/AgentHubApp.swift` AgentIdentity so Science (amber
/// flask) never looks like SuperGrok (purple sparkles).
public struct AgentStyle: Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var shortName: String
    /// SF Symbol for the notch / menu (no emoji dependency in AppKit menu).
    public var systemImage: String
    /// Emoji badge for text contexts / registry.
    public var emoji: String
    public var red: Double
    public var green: Double
    public var blue: Double
    /// Companion animal — fixed identity cue, mirrors `pet` in
    /// hub/agent_identity.py. Never varies with runtime state.
    public var pet: String
    /// SF Symbol standing in for `pet` (nearest match; SF Symbols has no
    /// owl/raven/fox/wolf/beaver/dolphin glyph).
    public var petSymbol: String

    public init(
        id: String,
        displayName: String,
        shortName: String,
        systemImage: String,
        emoji: String,
        red: Double,
        green: Double,
        blue: Double,
        pet: String = "creature",
        petSymbol: String = "pawprint.fill"
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.systemImage = systemImage
        self.emoji = emoji
        self.red = red
        self.green = green
        self.blue = blue
        self.pet = pet
        self.petSymbol = petSymbol
    }

    #if canImport(SwiftUI)
    /// Raw brand colour. Correct for dots and arcs; too light for text in
    /// daylight — prefer `palette.ink` for anything with letterforms.
    public var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    /// Scheme-aware ink / tint / wash / edge roles for this agent.
    public var palette: AgentPalette {
        AgentColor.palette(red: red, green: green, blue: blue)
    }
    #endif
}

public enum AgentStyleCatalog {
    public static let all: [AgentStyle] = [
        .init(id: "science", displayName: "Claude Science", shortName: "Sci",
              systemImage: "flask.fill", emoji: "🔬",
              red: 1.00, green: 0.72, blue: 0.10,
              pet: "owl", petSymbol: "bird.fill"),
        .init(id: "grok_build", displayName: "Grok Build", shortName: "Grok",
              systemImage: "sparkles", emoji: "🟣",
              red: 0.68, green: 0.28, blue: 0.98,
              pet: "raven", petSymbol: "bird"),
        .init(id: "claude_code", displayName: "Claude Code", shortName: "CC",
              systemImage: "bubble.left.and.bubble.right.fill", emoji: "🟠",
              red: 1.00, green: 0.50, blue: 0.08,
              pet: "fox", petSymbol: "hare.fill"),
        .init(id: "chatgpt", displayName: "ChatGPT", shortName: "GPT",
              systemImage: "text.bubble.fill", emoji: "🟢",
              red: 0.10, green: 0.72, blue: 0.55,
              pet: "parrot", petSymbol: "bird.circle"),
        .init(id: "codex", displayName: "Codex", shortName: "Codex",
              systemImage: "chevron.left.forwardslash.chevron.right", emoji: "🔵",
              red: 0.30, green: 0.55, blue: 1.00,
              pet: "dolphin", petSymbol: "fish.fill"),
        .init(id: "cowork", displayName: "Cowork", shortName: "CWork",
              systemImage: "person.2.fill", emoji: "🟢",
              red: 0.20, green: 0.85, blue: 0.45,
              pet: "beaver", petSymbol: "pawprint.fill"),
        .init(id: "dispatch", displayName: "Dispatch", shortName: "Disp",
              systemImage: "paperplane.fill", emoji: "🟤",
              red: 0.72, green: 0.50, blue: 0.28,
              pet: "wolf", petSymbol: "dog.fill"),
        .init(id: "terminal", displayName: "Terminal", shortName: "Term",
              systemImage: "terminal.fill", emoji: "⬛",
              red: 0.55, green: 0.60, blue: 0.65,
              pet: "tortoise", petSymbol: "tortoise.fill"),
        .init(id: "browser", displayName: "Browser", shortName: "Web",
              systemImage: "globe", emoji: "🌐",
              red: 0.35, green: 0.55, blue: 0.95,
              pet: "gecko", petSymbol: "lizard.fill"),
        .init(id: "cursor", displayName: "Cursor", shortName: "Cur",
              systemImage: "cursorarrow.rays", emoji: "⬛",
              red: 0.40, green: 0.40, blue: 0.45,
              pet: "cat", petSymbol: "cat.fill"),
        .init(id: "vscode", displayName: "VS Code", shortName: "Code",
              systemImage: "chevron.left.forwardslash.chevron.right", emoji: "💙",
              red: 0.20, green: 0.50, blue: 0.90,
              pet: "ladybug", petSymbol: "ladybug.fill"),
        .init(id: "dataset_runner", displayName: "DatasetRunner", shortName: "DR",
              systemImage: "tablecells", emoji: "📊",
              red: 0.15, green: 0.70, blue: 0.80,
              pet: "gear", petSymbol: "gearshape.fill"),
    ]

    public static func style(for id: String) -> AgentStyle {
        if let hit = all.first(where: { $0.id == id }) { return hit }
        return .init(
            id: id,
            displayName: id.replacingOccurrences(of: "_", with: " ").capitalized,
            shortName: String(id.prefix(4)).uppercased(),
            systemImage: "cpu",
            emoji: "⚙️",
            red: 0.55, green: 0.55, blue: 0.58
        )
    }
}

// MARK: - Browser page → agent

/// Context harvested from the front browser tab (title + URL). Pure mapping is
/// unit-tested without AppleScript.
public struct BrowserPageContext: Sendable, Equatable {
    public var title: String
    public var url: String

    public init(title: String = "", url: String = "") {
        self.title = title
        self.url = url
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum BrowserAgentDetector {
    /// Resolve which web agent owns the active tab.
    ///
    /// Priority (first match wins):
    /// 1. Claude Science — science subdomain / title / FlexAID docking cues
    /// 2. SuperGrok / Grok — grok.x.ai, x.com/i/grok, SuperGrok title
    /// 3. ChatGPT / Codex — chatgpt.com, chat.openai.com
    /// 4. Claude (generic chat) — claude.ai
    /// 5. nil → keep generic browser
    public static func detect(page: BrowserPageContext) -> AgentKind? {
        let title = page.title.lowercased()
        let url = page.url.lowercased()
        let blob = title + " " + url

        // ── Claude Science (must beat generic Claude) ─────────────────────
        if matchesScience(title: title, url: url, blob: blob) {
            return AgentKind(
                id: "science",
                displayName: "Claude Science",
                source: "browser",
                bundleHint: page.url.isEmpty ? nil : page.url
            )
        }

        // ── SuperGrok / Grok ──────────────────────────────────────────────
        if matchesGrok(title: title, url: url, blob: blob) {
            return AgentKind(
                id: "grok_build",
                displayName: "Grok Build",
                source: "browser",
                bundleHint: page.url.isEmpty ? nil : page.url
            )
        }

        // ── Codex (OpenAI coding) ─────────────────────────────────────────
        if url.contains("chatgpt.com/codex") || url.contains("openai.com/codex")
            || title.contains("codex") && (url.contains("openai") || url.contains("chatgpt")) {
            return AgentKind(id: "codex", displayName: "Codex", source: "browser",
                             bundleHint: page.url.isEmpty ? nil : page.url)
        }

        // ── ChatGPT ───────────────────────────────────────────────────────
        if url.contains("chatgpt.com") || url.contains("chat.openai.com")
            || title.contains("chatgpt") {
            return AgentKind(id: "chatgpt", displayName: "ChatGPT", source: "browser",
                             bundleHint: page.url.isEmpty ? nil : page.url)
        }

        // ── Claude generic (desktop-like) ─────────────────────────────────
        if url.contains("claude.ai") || (title.contains("claude") && !title.contains("science")) {
            return AgentKind(id: "claude_code", displayName: "Claude", source: "browser",
                             bundleHint: page.url.isEmpty ? nil : page.url)
        }

        return nil
    }

    private static func matchesScience(title: String, url: String, blob: String) -> Bool {
        // Explicit product name (native app window + marketing pages)
        if title.contains("claude science") || title.contains("science · claude")
            || title.contains("science - claude") || title.contains("science | claude")
            || title == "claude science" || title.hasPrefix("claude science ") {
            return true
        }
        // Official product URLs (claude.com/science, claude.com/product/claude-science)
        if url.contains("claude.com/science") || url.contains("claude.com/product/claude-science")
            || url.contains("claude.ai/science") || url.contains("/claude-science") {
            return true
        }
        if (url.contains("claude.ai") || url.contains("claude.com") || url.contains("anthropic.com"))
            && (url.contains("/science") || url.contains("science=")) {
            return true
        }
        // Project / chat URLs with science + research cues
        if (url.contains("claude.ai") || url.contains("claude.com")) && (
            url.contains("science")
                || (url.contains("project") && blob.contains("flexaid"))
        ) {
            return true
        }
        // Title: Claude + science / docking / FlexAID / Astex (research agent)
        if title.contains("claude") && (
            title.contains("science") || title.contains("flexaid")
                || title.contains("docking") || title.contains("astex")
                || title.contains("δs") || title.contains("deltas")
                || title.contains("configurational")
        ) {
            return true
        }
        // Standalone science agent label without browser chrome
        if title.hasPrefix("science") && (title.contains("claude") || blob.contains("anthropic")) {
            return true
        }
        // Window title from native Claude Science.app
        if title.contains("operon") { return true }
        return false
    }

    private static func matchesGrok(title: String, url: String, blob: String) -> Bool {
        if title.contains("supergrok") || title.contains("super grok") {
            return true
        }
        // Official hosts (never map these to science)
        if url.contains("grok.x.ai") || url.contains("x.ai/grok")
            || url.contains("grok.com") || url.contains("grok.x.com")
            || url.contains("x.com/i/grok") || url.contains("twitter.com/i/grok") {
            return true
        }
        // Title on X / grok.x.ai
        if title.contains("grok") && (
            url.contains("x.com") || url.contains("x.ai") || url.contains("twitter")
                || url.contains("grok.com")
                || title.contains("x /") || title.contains("x ·")
        ) {
            return true
        }
        if title == "grok" || title.hasPrefix("grok ") || title.contains("grok by x")
            || title.contains("grok build") {
            return true
        }
        // Catch-all for SuperGrok branding in title even without URL
        if blob.contains("supergrok") { return true }
        // Never treat science URLs as Grok even if title mentions both
        if blob.contains("claude science") || url.contains("claude.com/science") {
            return false
        }
        return false
    }
}
