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

/// One resolved gate question, kept after its card clears so the sidebar can
/// show what was recently approved or denied.
struct GateEvent: Identifiable, Equatable {
    let id: String
    let question: String
    let agentName: String?
    let approved: Bool
    let answeredAt: Date
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

    /// Recently answered gate questions, newest first. The card clears the
    /// moment it is answered, so without a durable trail an approve/deny leaves
    /// no evidence it happened — this backs the sidebar's "Gate Activity"
    /// section, the transparency half of the iPadOS redesign.
    @Published private(set) var recentGateEvents: [GateEvent] = []

    /// Nonisolated so pure helpers can default to these without MainActor hops.
    nonisolated static let historyLimit = 180
    nonisolated static let gateEventLimit = 12

    private var started = false

    init(backend: ShannonSyncBackend? = nil) {
        let resolved = backend ?? AgentHubViewModel.defaultBackend()
        self.store = ShannonStore(
            backend: resolved,
            interval: MultiDeviceCadence.companionRefreshInterval,
            deviceName: "iPad"
        )
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

    /// Pinned first, then Mac-parity attention rank (needs-you → working → …).
    /// Open confirmations elevate their agent even when activity is still running (UX-004).
    var visibleAgents: [AgentState] {
        let ranked = snapshot
            .agentsRankedForDisplay()
            .filter { !dismissedAgentIDs.contains($0.id) }
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

    /// UX-048: whether ⌘A / ⌘D, palette Approve/Deny, and related chrome may
    /// act on the oldest pending ask. False when pending is empty **or** the
    /// oldest ask is offline / expired (`companionAffordance.canInteract`).
    /// Shared by `ShannonPadApp` Confirmation menu and `PaletteCatalogue`.
    var canInteractWithOldestPending: Bool {
        guard let pending = pendingConfirmations.first else { return false }
        return GateAskActionCopy.companionAffordance(
            pending: pending,
            lastError: store.lastError
        ).canInteract
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
    /// palette's Approve / Deny, and the spoken commands all land here.
    func answerPendingConfirmation(approved: Bool, source: ConfirmationSource = .tap) {
        guard let pending = store.snapshot.oldestPendingConfirmation() else {
            // UX-054: empty-pending toast shares Core nothingWaitingForAnswer.
            post(GateAskActionCopy.nothingWaitingForAnswer)
            return
        }
        // UX-018: keyboard/palette paths share companionAffordance with GateCard.
        let affordance = GateAskActionCopy.companionAffordance(
            pending: pending,
            lastError: store.lastError
        )
        guard affordance.canInteract else {
            post(affordance.statusMessage ?? GateAskActionCopy.nothingWaitingForAnswer)
            return
        }
        guard let answered = store.answerPending(
            approved ? .confirmed : .denied, source: source
        ) else {
            post(GateAskActionCopy.nothingWaitingForAnswer)
            return
        }
        didAnswer(answered, approved: approved)
        // UX-053: status toast shares GateAskActionCopy.outcomeLabel with Gate Activity
        // (UX-034) and phone AirPods TTS (UX-044) — not dual Confirmed/Denied.
        post("\(GateAskActionCopy.outcomeLabel(approved: approved)) · \(answered.question)")
    }

    func answer(
        _ confirmation: PendingConfirmation,
        approved: Bool,
        source: ConfirmationSource = .tap
    ) {
        // UX-018: hub offline / unanswerable — same fail-closed as phone (no fake success).
        let affordance = GateAskActionCopy.companionAffordance(
            pending: confirmation,
            lastError: store.lastError
        )
        guard affordance.canInteract else {
            // UX-054: refuse toast prefers affordance status, else promptUnanswerable.
            post(affordance.statusMessage ?? GateAskActionCopy.promptUnanswerable)
            return
        }
        // Honor OS-agnostic refuse (expired / empty question) — no success haptic
        // or gate-activity trail when the store rejected the answer.
        let accepted = store.answer(
            confirmation,
            approved ? .confirmed : .denied,
            source: source
        )
        guard accepted else {
            post(GateAskActionCopy.promptUnanswerable)
            return
        }
        didAnswer(confirmation, approved: approved)
    }

    /// Shared tail for every answer path. `ShannonStore` is `@Observable` and
    /// mutates its snapshot in place when an answer is sent, but this view model
    /// is an `ObservableObject` bridged to SwiftUI only through
    /// `objectWillChange`. The store's optimistic removal therefore never
    /// reached the view: the card stayed on screen until the next 20 s poll,
    /// which read as the app being "stuck" right after Approve/Deny. Recording
    /// the gate event mutates a `@Published` property — which emits
    /// `objectWillChange` — so the pending list, read live from the store, is
    /// re-rendered immediately.
    private func didAnswer(_ confirmation: PendingConfirmation, approved: Bool) {
        let event = GateEvent(
            id: confirmation.id,
            question: confirmation.question,
            agentName: agentName(for: confirmation),
            approved: approved,
            answeredAt: Date()
        )
        recentGateEvents = Self.cappedGateEvents(prepending: event, to: recentGateEvents)
        objectWillChange.send()
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

    /// UX-047: docking Cancel has no Mac-side `RemoteCommand` yet — honest
    /// status rather than a silent no-op that looks live.
    func requestDockingCancel() {
        post("Cancel run needs a Mac-side command record — not wired yet.")
    }

    /// UX-047: docking Export CSV has no Mac-side export path yet — honest
    /// status rather than a silent no-op that looks live.
    func requestDockingExportCSV() {
        post("Export results CSV needs a Mac-side command record — not wired yet.")
    }

    func send(_ command: PlaybackCommand) {
        store.send(command, origin: "iPad")
        PadHaptics.tap()
    }

    func refresh() async { await store.refresh() }

    // MARK: History

    private func record(_ snapshot: ShannonSnapshot) {
        let now = snapshot.capturedAt
        var nextEntropy = entropyHistory
        var nextRMSD = rmsdHistory

        for agent in snapshot.agents {
            // Entropy is Mac-published only — never synthesised on the pad.
            guard let bits = agent.entropyBits else { continue }
            nextEntropy[agent.id] = Self.appending(
                MetricSample(date: now, value: bits),
                to: nextEntropy[agent.id] ?? []
            )
        }
        for progress in snapshot.docking {
            guard let rmsd = progress.bestRMSD else { continue }
            nextRMSD[progress.id] = Self.appending(
                MetricSample(date: now, value: rmsd),
                to: nextRMSD[progress.id] ?? []
            )
        }

        // Drop series for agents / benchmarks the Mac no longer publishes so a
        // long-lived hub session cannot retain unbounded map keys.
        let liveAgentIDs = Set(snapshot.agents.map(\.id))
        let liveDockingIDs = Set(snapshot.docking.map(\.id))
        entropyHistory = Self.pruningHistory(nextEntropy, keeping: liveAgentIDs)
        rmsdHistory = Self.pruningHistory(nextRMSD, keeping: liveDockingIDs)
    }

    // MARK: Pure history helpers

    /// Append a sample, skipping near-duplicate plateaus and enforcing
    /// `historyLimit`. Pure so unit tests can exercise the cap without the store.
    nonisolated static func appending(
        _ sample: MetricSample,
        to series: [MetricSample],
        limit: Int = historyLimit,
        plateauInterval: TimeInterval = 5
    ) -> [MetricSample] {
        // Snapshots arrive every 20s whether or not the value moved; an
        // unchanged reading would otherwise flatten the chart's time axis into
        // a run of identical points.
        if let last = series.last, last.value == sample.value,
           sample.date.timeIntervalSince(last.date) < plateauInterval {
            return series
        }
        var next = series
        next.append(sample)
        if next.count > limit {
            next.removeFirst(next.count - limit)
        }
        return next
    }

    /// Keep only series whose keys are still live in the current snapshot.
    nonisolated static func pruningHistory(
        _ history: [String: [MetricSample]],
        keeping liveIDs: Set<String>
    ) -> [String: [MetricSample]] {
        guard !history.isEmpty else { return history }
        return history.filter { liveIDs.contains($0.key) }
    }

    /// Newest-first gate trail, de-duplicated by id, capped at `gateEventLimit`.
    nonisolated static func cappedGateEvents(
        prepending event: GateEvent,
        to existing: [GateEvent],
        limit: Int = gateEventLimit
    ) -> [GateEvent] {
        var next = existing.filter { $0.id != event.id }
        next.insert(event, at: 0)
        if next.count > limit {
            next.removeLast(next.count - limit)
        }
        return next
    }
}
