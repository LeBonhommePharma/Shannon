import Foundation
import SwiftUI
import ShannonCore

/// One sampled scalar. The Mac publishes current state, not history, so the
/// series behind every chart in the hub is accumulated here from successive
/// snapshots rather than fetched.
struct MetricSample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let value: Double
}

/// A user-drawn edge between two agents: the output of `sourceID` feeds
/// `targetID`. Created by dragging one card onto another.
struct AgentLink: Identifiable, Hashable {
    var sourceID: String
    var targetID: String

    var id: String { "\(sourceID)->\(targetID)" }
}

/// What the centre column is showing.
enum HubSelection: Hashable {
    case overview
    case agent(String)
    case docking(String)
}

/// Everything the hub knows that CloudKit does not: selection, pins, drawn
/// links, dismissed notifications, and the sampled history behind the charts.
///
/// The Mac remains the source of truth for agent state; this layer never
/// mutates a synced record except by sending an explicit remote command.
@MainActor
final class AgentHubViewModel: ObservableObject {
    let store: ShannonStore

    @Published var selection: HubSelection = .overview
    @Published var isPaletteVisible = false
    @Published var isVoiceVisible = false

    /// Agent ids the user pinned; these sort ahead of the ranking the other
    /// devices use, but only on this iPad.
    @Published private(set) var pinnedAgentIDs: Set<String> = []
    @Published private(set) var dismissedAgentIDs: Set<String> = []
    @Published private(set) var links: [AgentLink] = []

    @Published private(set) var importantNotificationIDs: Set<String> = []
    @Published private(set) var dismissedNotificationIDs: Set<String> = []

    /// Entropy in bits, keyed by agent id. Capped so a session left running
    /// overnight does not grow without bound.
    @Published private(set) var entropyHistory: [String: [MetricSample]] = [:]
    /// Best RMSD so far, keyed by benchmark id.
    @Published private(set) var rmsdHistory: [String: [MetricSample]] = [:]

    static let historyLimit = 180

    private var started = false

    init(backend: ShannonSyncBackend? = nil) {
        let resolved = backend ?? AgentHubViewModel.defaultBackend()
        self.store = ShannonStore(backend: resolved, interval: 20, deviceName: "iPad")
    }

    /// Mirrors the phone: CloudKit when the process is entitled and running on
    /// device, an empty in-memory backend otherwise so the app still launches
    /// in the Simulator and shows its empty state.
    private static func defaultBackend() -> ShannonSyncBackend {
        #if canImport(CloudKit) && !targetEnvironment(simulator)
        return CloudKitSyncBackend()
        #else
        return InMemorySyncBackend()
        #endif
    }

    func start() {
        guard !started else { return }
        started = true

        store.onAlert = { alert in PadHaptics.play(for: alert) }
        // `ShannonStore` is `@Observable`, not `ObservableObject`, so there is
        // no publisher to subscribe to — the store calls back instead.
        store.onSnapshot = { [weak self] snapshot in
            self?.record(snapshot)
            self?.objectWillChange.send()
        }
        store.start()
    }

    var snapshot: ShannonSnapshot { store.snapshot }

    // MARK: Derived collections

    /// Pinned first, then the ranking every Shannon device agrees on.
    var visibleAgents: [AgentState] {
        let ranked = snapshot.agents
            .filter { !dismissedAgentIDs.contains($0.id) }
            .rankedForDisplay()
        let pinned = ranked.filter { pinnedAgentIDs.contains($0.id) }
        let rest = ranked.filter { !pinnedAgentIDs.contains($0.id) }
        return pinned + rest
    }

    var selectedAgent: AgentState? {
        guard case .agent(let id) = selection else { return nil }
        return snapshot.agents.first { $0.id == id }
    }

    var selectedDocking: DockingProgress? {
        guard case .docking(let id) = selection else { return nil }
        return snapshot.docking.first { $0.id == id }
    }

    /// Important first, then newest, with dismissals removed.
    var visibleNotifications: [NotificationMirror] {
        let kept = snapshot.notifications.filter { !dismissedNotificationIDs.contains($0.id) }
        return kept.sorted { a, b in
            let ai = importantNotificationIDs.contains(a.id)
            let bi = importantNotificationIDs.contains(b.id)
            return ai == bi ? a.postedAt > b.postedAt : ai && !bi
        }
    }

    /// Questions the Mac is blocked on. These get the large Confirm / Deny
    /// buttons in the right rail regardless of how the agents sort.
    var pendingConfirmations: [PendingConfirmation] {
        snapshot.confirmations
            .filter { !$0.isExpired() }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The question blocking one particular agent, if any.
    func confirmation(forAgent agentID: String) -> PendingConfirmation? {
        pendingConfirmations.first { $0.agentID == agentID }
    }

    func agentName(for confirmation: PendingConfirmation) -> String? {
        guard let agentID = confirmation.agentID else { return nil }
        return snapshot.agents.first { $0.id == agentID }?.name
    }

    func isPinned(_ agentID: String) -> Bool { pinnedAgentIDs.contains(agentID) }

    func isImportant(_ notificationID: String) -> Bool {
        importantNotificationIDs.contains(notificationID)
    }

    func entropySeries(for agentID: String) -> [MetricSample] {
        entropyHistory[agentID] ?? []
    }

    func rmsdSeries(for benchmarkID: String) -> [MetricSample] {
        rmsdHistory[benchmarkID] ?? []
    }

    /// Inbound edges, so a card can say what is feeding it.
    func upstream(of agentID: String) -> [String] {
        links.filter { $0.targetID == agentID }.map(\.sourceID)
    }

    // MARK: Mutations

    func select(_ selection: HubSelection) {
        withAnimation(.shannonEase) { self.selection = selection }
    }

    /// Focus the nth agent in display order — the ⌘1…⌘9 shortcuts.
    func focusAgent(at index: Int) {
        let agents = visibleAgents
        guard agents.indices.contains(index) else { return }
        select(.agent(agents[index].id))
    }

    func togglePin(_ agentID: String) {
        withAnimation(.shannonEase) {
            if pinnedAgentIDs.contains(agentID) {
                pinnedAgentIDs.remove(agentID)
            } else {
                pinnedAgentIDs.insert(agentID)
            }
        }
    }

    func dismissAgent(_ agentID: String) {
        withAnimation(.shannonEase) {
            dismissedAgentIDs.insert(agentID)
            if case .agent(agentID) = selection { selection = .overview }
        }
    }

    /// Link the output of one agent into another. Self-links and duplicates are
    /// dropped so the connection overlay cannot draw a degenerate edge.
    @discardableResult
    func link(from sourceID: String, to targetID: String) -> Bool {
        guard sourceID != targetID else { return false }
        guard !links.contains(where: { $0.sourceID == sourceID && $0.targetID == targetID })
        else { return false }
        withAnimation(.shannonFloat) {
            links.append(AgentLink(sourceID: sourceID, targetID: targetID))
        }
        PadHaptics.tap()
        return true
    }

    func removeLinks(touching agentID: String) {
        withAnimation(.shannonEase) {
            links.removeAll { $0.sourceID == agentID || $0.targetID == agentID }
        }
    }

    func markImportant(_ notificationID: String) {
        withAnimation(.shannonEase) { _ = importantNotificationIDs.insert(notificationID) }
    }

    func dismissNotification(_ notificationID: String) {
        withAnimation(.shannonEase) {
            dismissedNotificationIDs.insert(notificationID)
            importantNotificationIDs.remove(notificationID)
        }
    }

    /// Answer the oldest pending confirmation — the ⌘↵ / ⌘. shortcuts, the
    /// palette's Confirm / Deny, and the spoken commands all land here.
    func answerPendingConfirmation(approved: Bool, source: ConfirmationSource = .tap) {
        guard let answered = store.answerPending(
            approved ? .confirmed : .denied, source: source
        ) else {
            post("Nothing is waiting on an answer.")
            return
        }
        PadHaptics.notify(approved ? .success : .warning)
        post("\(approved ? "Confirmed" : "Denied") · \(answered.question)")
    }

    func answer(
        _ confirmation: PendingConfirmation,
        approved: Bool,
        source: ConfirmationSource = .tap
    ) {
        store.answer(confirmation, approved ? .confirmed : .denied, source: source)
        PadHaptics.notify(approved ? .success : .warning)
    }

    /// Transient one-line banner — used where an action cannot complete yet
    /// rather than letting a button look like it did something.
    @Published var statusMessage: String?

    func post(_ message: String) {
        withAnimation(.shannonEase) { statusMessage = message }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.shannonEase) {
                if self.statusMessage == message { self.statusMessage = nil }
            }
        }
    }

    /// `RemoteCommand` only carries playback today, so there is no record the
    /// Mac would pick up to start a run. The palette entry navigates to the
    /// benchmark and says so rather than silently doing nothing.
    func requestBenchmarkRun() {
        if let benchmark = snapshot.docking.first {
            select(.docking(benchmark.id))
        }
        post("Starting a run needs a Mac-side command record — not wired yet.")
    }

    func send(_ command: PlaybackCommand) {
        store.send(command, origin: "iPad")
        PadHaptics.tap()
    }

    func refresh() async { await store.refresh() }

    // MARK: History

    private func record(_ snapshot: ShannonSnapshot) {
        let now = snapshot.capturedAt
        for agent in snapshot.agents {
            guard let bits = agent.entropyBits else { continue }
            append(MetricSample(date: now, value: bits), to: &entropyHistory[agent.id, default: []])
        }
        for progress in snapshot.docking {
            guard let rmsd = progress.bestRMSD else { continue }
            append(MetricSample(date: now, value: rmsd), to: &rmsdHistory[progress.id, default: []])
        }
    }

    private func append(_ sample: MetricSample, to series: inout [MetricSample]) {
        // Snapshots arrive every 20s whether or not the value moved; an
        // unchanged reading would otherwise flatten the chart's time axis into
        // a run of identical points.
        if let last = series.last, last.value == sample.value,
           sample.date.timeIntervalSince(last.date) < 5 {
            return
        }
        series.append(sample)
        if series.count > Self.historyLimit {
            series.removeFirst(series.count - Self.historyLimit)
        }
    }
}
