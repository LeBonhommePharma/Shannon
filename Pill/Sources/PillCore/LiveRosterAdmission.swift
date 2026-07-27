import Foundation

// MARK: - Live roster admission (pill / pets)

/// Pure policy: which activity snapshots may appear as live agent rows on the
/// Mac pill roster and companion board.
///
/// **Production rule:** a still-running OS app is **not** enough to list a row.
/// Rows come from Shannon attach/session/gate paths only:
/// - process-attach with a **live pid** (⌘D stored attach_pid still running), or
/// - live host **agent/terminal/IDE** bundle (allow-list), or
/// - gate-live / busy / needs-you / finished attention, or
/// - open pending approval for that agent.
///
/// Offline, bare “seen”, and non-agent host shells without attach pid are kept
/// out so WindowManager / Finder / empty Ghostty shells do not spam the board.
public enum LiveRosterAdmission: Sendable {

    /// Host bundle ids that may keep a row **live** when the host app is
    /// running even if the original CLI pid recycled (Electron restarts).
    /// Everything else requires a live attach_pid or gate/busy evidence.
    public static let agentHostBundleAllowList: Set<String> = [
        // Terminals (CLI agent hosts)
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.warp-stable",
        "dev.warp.warp",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "com.raycast.macos", // Raycast terminal extensions rarely
        // IDEs / agent desktops
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.todesktop",
        "com.microsoft.vscode",
        "com.microsoft.VSCode",
        "com.apple.dt.xcode",
        "com.jetbrains.",
        "com.anthropic.claudefordesktop",
        "com.anthropic.operon",
        "com.openai.chat",
        "ai.perplexity.mac",
        "com.xai.grok",
    ]

    /// True when this lowercased bundle id is an agent/terminal host we trust
    /// for bundle-only process-attach liveness.
    public static func isAllowedAgentHostBundle(_ bundle: String?) -> Bool {
        guard let raw = bundle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        let b = raw.lowercased()
        if agentHostBundleAllowList.contains(b) { return true }
        // Prefix matches (JetBrains family, Cursor todesktop variants).
        for allowed in agentHostBundleAllowList where allowed.hasSuffix(".") {
            if b.hasPrefix(allowed) { return true }
        }
        if b.hasPrefix("com.todesktop.") { return true }
        if b.hasPrefix("com.jetbrains.") { return true }
        if b.hasPrefix("com.anthropic.") { return true }
        return false
    }

    /// Generic container identities that must not list as “live agents” without
    /// a real CLI probe / gate / busy signal (empty shell in Ghostty, bare browser).
    public static let genericContainerAgentIds: Set<String> = [
        "terminal", "browser", "finder", "windowmanager", "dock", "systemuiserver",
    ]

    /// Whether the agent may appear on pill roster / companion board.
    public static func shouldList(
        agent: AgentActivitySnapshot,
        surface: AgentLiveSurface? = nil,
        hasPendingAsk: Bool = false
    ) -> Bool {
        let id = agent.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.isEmpty { return false }

        // Actionable attention always wins (approval / working / just finished).
        if hasPendingAsk { return true }
        if let surface {
            switch surface.attention {
            case .needsYou, .working, .finished:
                return true
            case .idle, .unknown:
                break
            }
        }
        if agent.status.isBusy, agent.presence.canBeBusy {
            return true
        }

        switch agent.presence {
        case .offline:
            return false
        case .observed:
            // Foreground observation without process/gate proof — do not list
            // as a live agent row (avoids registry spam).
            return false
        case .live:
            // Generic container ids (bare "terminal"/"browser") need real work signal.
            if genericContainerAgentIds.contains(id) {
                return agent.status.isBusy || !agent.lastTask.isEmpty || agent.historyCount > 0
            }
            // Non-agent host bundle without a live CLI pid must not list
            // (defence if presence was forced live from a bad capture).
            let bundle = agent.attachBundle
            let hasPid = (agent.attachPid ?? 0) > 0
            if let bundle, !bundle.isEmpty, !isAllowedAgentHostBundle(bundle), !hasPid {
                return false
            }
            // Named live agent (gate heartbeat / allow-host / attach pid / fixtures).
            return true
        }
    }

    /// Filter a roster for display (stable order preserved).
    public static func filterListed(
        agents: [AgentActivitySnapshot],
        surfaces: [String: AgentLiveSurface] = [:],
        pendingAgentIDs: Set<String> = []
    ) -> [AgentActivitySnapshot] {
        agents.filter { a in
            shouldList(
                agent: a,
                surface: surfaces[a.id],
                hasPendingAsk: pendingAgentIDs.contains(a.id)
            )
        }
    }
}
