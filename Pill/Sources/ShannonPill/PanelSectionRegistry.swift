import SwiftUI
import PillCore
import ShannonTheme
import AgentReaders
import DevServers
import Routes

// MARK: - Panel section registry (W0)

/// One additive menubar/pill section that can live in its own file.
///
/// New features register once here — they should not grow the historical
/// god-view bodies for every toggle.
enum PanelSectionID: String, CaseIterable, Identifiable {
    case pulledSessions
    case devServers
    case quickRoutes
    case fastActions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pulledSessions: return "Pulled sessions"
        case .devServers: return "Dev servers"
        case .quickRoutes: return "Quick routes"
        case .fastActions: return "Fast actions"
        }
    }
}

/// Snapshot of additive panel data, refreshed with the activity poll.
@MainActor
final class ParityPanelModel: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var servers: [DevServer] = []
    @Published var routes: [QuickRoute] = []
    @Published var actions: [FastAction] = []
    @Published var lastActionStatus: FastActionRunStatus = .idle
    @Published var lastActionError: String?

    private let registry = SessionRegistry()
    private var lastRefresh: Date = .distantPast

    init() {
        // Default Fast Actions seed — user-editable later via prefs.
        if let data = UserDefaults.standard.data(forKey: FastActionStore.defaultsKey) {
            actions = FastActionStore.decode(data)
        }
        if actions.isEmpty {
            actions = [
                FastAction(name: "git status", command: "git -C \"$HOME\" status -sb 2>/dev/null | head -5"),
            ]
        }
    }

    /// Register gate agents + artifact readers, then refresh independent surfaces.
    ///
    /// Disk / process discovery (Claude/Codex artifacts, dev servers, home
    /// routes) runs off the MainActor so opening the popover never hitch the
    /// menu bar — same discipline as `AgentActivityMonitor` hub scans.
    func refresh(gateAgents: [AgentActivitySnapshot], force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastRefresh) < 2.0 { return }
        lastRefresh = now
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Task.detached(priority: .utility) { [weak self] in
            let payload = ParityPanelModel.collectParityPayload(
                gateAgents: gateAgents,
                now: now,
                home: home
            )
            await MainActor.run {
                guard let self else { return }
                self.sessions = payload.sessions
                self.servers = payload.servers
                self.routes = payload.routes
            }
        }
    }

    /// One snapshot of parity panel data (sessions / servers / routes).
    struct ParityPayload: Sendable {
        var sessions: [AgentSession]
        var servers: [DevServer]
        var routes: [QuickRoute]
    }

    /// Heavy I/O for the parity panel — safe to call off MainActor.
    ///
    /// Uses a fresh local `SessionRegistry` so callers never share mutable
    /// MainActor state with a detached task. `includeArtifactReaders` is true
    /// in production; tests may set false to avoid scanning `~/.claude`.
    nonisolated static func collectParityPayload(
        gateAgents: [AgentActivitySnapshot],
        now: Date = Date(),
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        includeArtifactReaders: Bool = true,
        discoverServers: () -> [DevServer] = { Array(DevServerDiscovery.discoverLive().prefix(8)) }
    ) -> ParityPayload {
        let reg = SessionRegistry()
        reg.register(GateSessionProvider(agents: gateAgents))
        if includeArtifactReaders {
            reg.register(ClaudeCodeSessionReader(maxSessions: 12))
            reg.register(CodexSessionReader(maxSessions: 12))
        }
        let sess = Array(
            reg.allSessions(now: now)
                .filter { $0.sourceKind == .artifact }
                .prefix(8)
        )
        let servers = discoverServers()
        // Keep missing catalog paths so QuickRoutesSection can dim/disable them.
        let routes = QuickRouteCatalog.panelRoutes(home: home, limit: 24)
        return ParityPayload(sessions: sess, servers: servers, routes: routes)
    }

    func runAction(_ action: FastAction) {
        lastActionStatus = .running
        lastActionError = nil
        let runner = FastActionRunner()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runner.run(action)
            DispatchQueue.main.async {
                self.lastActionStatus = result.status
                self.lastActionError = result.lastFailureLine
            }
        }
    }
}

// MARK: - Section views

struct PulledSessionsSection: View {
    let sessions: [AgentSession]
    /// Gate asks so a pulled session that also needs approval ranks + labels correctly.
    var pendingAsks: [GateDBReader.PendingAsk] = []
    var activity: [GateDBReader.ActivityEvent] = []

    /// Ranked cards: needs-you → working → finished → idle; optional fields fail-closed.
    private var cards: [SessionContentCard] {
        SessionContentPresenter.cards(
            sessions: sessions,
            pendingAsks: pendingAsks,
            activity: activity,
            limit: 5
        )
    }

    var body: some View {
        if sessions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Pulled sessions", systemImage: "doc.text.magnifyingglass")
                ForEach(cards) { card in
                    sessionCardRow(card)
                }
            }
        }
    }

    private func sessionCardRow(_ card: SessionContentCard) -> some View {
        let style = AgentStyleCatalog.style(for: card.agentId)
        let surface = AgentLiveSurface(
            agentId: card.agentId,
            displayName: card.displayName,
            attention: card.attention,
            activityLine: card.activityLine,
            usage: card.usage,
            needsYou: card.needsYou,
            isFinished: card.isFinished
        )
        return HStack(spacing: 6) {
            Text(style.emoji)
                .font(.shannonMenuFootnote)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(card.displayName)
                        .font(.shannonMenuBody)
                        .foregroundStyle(Color.shannonPrimary)
                        .lineLimit(1)
                    Text(card.badgeLabel)
                        .font(.shannonMenuSection)
                        .foregroundStyle(
                            AgentLiveChrome.attentionColor(
                                surface: surface,
                                styleInk: style.palette.ink
                            )
                        )
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(style.palette.wash))
                    Spacer(minLength: 0)
                    if let usage = card.usageLabel {
                        Text(usage)
                            .font(.shannonMenuMono)
                            .foregroundStyle(Color.shannonTertiary)
                    }
                    if let age = card.relativeAge {
                        Text(age)
                            .font(.shannonMenuMono)
                            .foregroundStyle(Color.shannonTertiary)
                    }
                }
                if !card.activityLine.isEmpty {
                    Text(card.activityLine)
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonSecondary)
                        .lineLimit(1)
                }
                if let meta = card.metaLine {
                    Text(meta)
                        .font(.shannonMenuMono)
                        .foregroundStyle(Color.shannonTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(card.sourceKind == .artifact ? "disk" : card.sourceKind.rawValue)
                .font(.shannonMenuSection)
                .foregroundStyle(Color.shannonTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(card.displayName), \(card.badgeLabel), \(card.activityLine), \(card.metaLine ?? "")"
        )
    }
}

struct DevServersSection: View {
    let servers: [DevServer]
    var onOpen: (DevServer) -> Void
    var onCopy: (DevServer) -> Void
    var onStop: (DevServer) -> Void

    var body: some View {
        if servers.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Dev servers", systemImage: "server.rack")
                ForEach(servers) { s in
                    HStack(spacing: 6) {
                        Text(s.detailLine)
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Open") { onOpen(s) }
                            .buttonStyle(.plain)
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonAccent)
                        Button("Copy") { onCopy(s) }
                            .buttonStyle(.plain)
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonSecondary)
                        Button("Stop") { onStop(s) }
                            .buttonStyle(.plain)
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonError)
                    }
                }
            }
        }
    }
}

struct QuickRoutesSection: View {
    let routes: [QuickRoute]
    var onOpen: (QuickRoute) -> Void

    var body: some View {
        if routes.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Quick routes", systemImage: "folder")
                ForEach(routes.prefix(8)) { r in
                    Button {
                        if r.isOpenable { onOpen(r) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(AgentStyleCatalog.style(for: r.agentId).shortName)
                                .font(.shannonMenuSection)
                                .foregroundStyle(Color.shannonTertiary)
                                .frame(width: 36, alignment: .leading)
                            Text(r.label)
                                .font(.shannonMenuFootnote)
                                .foregroundStyle(r.exists ? Color.shannonPrimary : Color.shannonTertiary)
                            Spacer(minLength: 0)
                            Image(systemName: r.exists ? "arrow.up.right.square" : "eye.slash")
                                .font(.shannonMenuFootnote)
                                .foregroundStyle(r.exists ? Color.shannonAccent : Color.shannonTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!r.isOpenable)
                    .opacity(r.exists ? 1 : 0.45)
                }
            }
        }
    }
}

struct FastActionsSection: View {
    let actions: [FastAction]
    let status: FastActionRunStatus
    let error: String?
    var onRun: (FastAction) -> Void

    var body: some View {
        if actions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Fast actions", systemImage: "bolt.fill")
                ForEach(actions.prefix(5)) { a in
                    HStack {
                        Text(a.name)
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if status == .running {
                            ProgressView().controlSize(.mini)
                        }
                        Button("Run") { onRun(a) }
                            .buttonStyle(.plain)
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonAccent)
                            .disabled({
                                if case .running = status { return true }
                                return false
                            }())
                    }
                }
                if case .failed(let line) = status {
                    Text(line)
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonError)
                        .lineLimit(2)
                } else if status == .succeeded {
                    Text("Succeeded")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonSuccess)
                }
            }
        }
    }
}

@ViewBuilder
private func sectionHeader(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 4) {
        Image(systemName: systemImage)
            .font(.shannonMenuSection)
            .foregroundStyle(Color.shannonSecondary)
        Text(title.uppercased())
            .font(.shannonMenuSection)
            .foregroundStyle(Color.shannonSecondary)
        Spacer(minLength: 0)
    }
}
