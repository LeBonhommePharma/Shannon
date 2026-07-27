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

    /// Never list these — mis-captures of macOS chrome (WindowManager, Dock, …).
    public static let refusedAgentIds: Set<String> = [
        "windowmanager", "finder", "dock", "systemuiserver", "loginwindow",
        "spotlight", "controlcenter", "notificationcenter", "siri",
        "window server", "windowserver",
    ]

    /// ⌘D placeholder task when no real work string was captured.
    /// Must not count as “work evidence” for generic container rows.
    public static func isAttachPlaceholderTask(_ task: String) -> Bool {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.hasPrefix("Working in ") { return true }
        if t.hasPrefix("Working in\u{00a0}") { return true } // nbsp
        return false
    }

    /// Meaningful work evidence beyond attach placeholder copy.
    public static func hasRealWorkSignal(_ agent: AgentActivitySnapshot) -> Bool {
        if agent.status.isBusy, agent.presence.canBeBusy { return true }
        if agent.historyCount > 0 { return true }
        if !isAttachPlaceholderTask(agent.lastTask) { return true }
        return false
    }

    /// Whether the agent may appear on pill roster / companion board.
    public static func shouldList(
        agent: AgentActivitySnapshot,
        surface: AgentLiveSurface? = nil,
        hasPendingAsk: Bool = false
    ) -> Bool {
        let id = agent.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.isEmpty { return false }
        // System chrome never lists — even with a pending ask (ask is mis-attributed).
        if refusedAgentIds.contains(id) { return false }

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
            // Still refuse system chrome even if somehow busy.
            if refusedAgentIds.contains(id) { return false }
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
            // Generic container (bare "terminal"/"browser"): only **gate busy**.
            // "Working in Ghostty" last_task is attach placeholder — never enough.
            if genericContainerAgentIds.contains(id) {
                return agent.status.isBusy && agent.presence.canBeBusy
            }
            // Non-agent host bundle without a live CLI pid must not list
            // (defence if presence was forced live from a bad capture).
            let bundle = agent.attachBundle
            let hasPid = (agent.attachPid ?? 0) > 0
            if let bundle, !bundle.isEmpty, !isAllowedAgentHostBundle(bundle), !hasPid {
                return false
            }
            // Named live agent: ProcessAttach already restricted host allow-list;
            // gate/fixtures set presence.live intentionally.
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

    // MARK: - Post-⌘D surface honesty

    /// Whether a just-captured agent will appear on menu-bar / pill / HUD boards.
    ///
    /// Pure preview of ``shouldList`` with process-attach presence inferred from
    /// capture evidence (live pid and/or allow-listed host bundle). Used so the
    /// status-item flash does not claim a green “+agent” when admission will
    /// hide a bare shell container.
    public static func willSurfaceCapture(
        agentID: String,
        displayName: String? = nil,
        lastTask: String = "",
        attachPid: Int32? = nil,
        attachBundle: String? = nil,
        source: String = "process"
    ) -> Bool {
        let id = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        let presence = ProcessAttach.presence(
            attachPid: attachPid,
            attachBundle: attachBundle,
            // Capture just happened: treat the host as running when we know it.
            runningBundleIDs: attachBundle.map { Set([$0.lowercased()]) }
        )
        let snap = AgentActivitySnapshot(
            id: id,
            displayName: (displayName?.isEmpty == false ? displayName! : id),
            status: .idle,
            lastTask: lastTask,
            source: source,
            updatedAt: Date(),
            resumable: true,
            historyCount: 0,
            presence: presence,
            attachPid: (attachPid ?? 0) > 0 ? attachPid : nil,
            attachBundle: attachBundle
        )
        return shouldList(agent: snap)
    }

    /// Status-item flash line after a capture attempt (honest vs board).
    public static func captureFlash(
        agentID: String?,
        displayName: String?,
        lastTask: String = "",
        attachPid: Int32? = nil,
        attachBundle: String? = nil,
        refusalLabel: String? = nil
    ) -> CaptureFlash {
        guard let agentID, !agentID.isEmpty else {
            return .notice(refusalLabel.map { "not an agent · \($0)" } ?? "not an agent")
        }
        let name = (displayName?.isEmpty == false ? displayName! : agentID)
        if willSurfaceCapture(
            agentID: agentID,
            displayName: name,
            lastTask: lastTask,
            attachPid: attachPid,
            attachBundle: attachBundle
        ) {
            return .success("+\(name)")
        }
        // Pet written but admission hides generic containers (empty shell).
        return .notice("shell only · open Claude/Cursor")
    }

    /// Menu-bar flash kind after ⌘D.
    public enum CaptureFlash: Sendable, Equatable {
        case success(String)
        case notice(String)
    }
}
