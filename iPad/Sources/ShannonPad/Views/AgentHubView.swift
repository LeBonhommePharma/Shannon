import SwiftUI
import ShannonCore
import ShannonTheme

/// Mission control.
///
/// One `NavigationSplitView`, reconfigured rather than replaced as the window
/// resizes: three columns when there is room for the notification rail, two in
/// portrait, and a plain stack in Slide Over. Rebuilding the whole hierarchy on
/// every resize would drop the selection and restart the charts, so the branch
/// is on column count only and the state lives above it in `AgentHubViewModel`.
struct AgentHubView: View {
    @ObservedObject var hub: AgentHubViewModel
    @ObservedObject var voice: VoiceDictationController

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 1024
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var annotation: AnnotationTarget?

    private var layout: HubLayout {
        HubLayout.resolve(width: width, sizeClass: sizeClass)
    }

    var body: some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: HubWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(HubWidthKey.self) { width = $0 }
            .overlay(alignment: .bottom) { voiceChip }
            .overlay(alignment: .top) { statusBanner }
            .overlay { paletteOverlay }
            .sheet(item: $annotation) { target in
                AnnotationOverlayView(
                    scopeID: target.scopeID,
                    name: target.name,
                    title: target.title,
                    showsPocketWireframe: target.isROI,
                    onClose: { annotation = nil }
                )
            }
            .tint(.shannonAccent)
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .compact:
            NavigationStack {
                dashboard(showsSidePanelCards: true)
                    .navigationTitle("Shannon")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbarItems }
            }

        case .twoColumn:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                AgentSidebar(hub: hub, isRail: false)
                    .navigationSplitViewColumnWidth(layout.sidebarWidth)
            } detail: {
                NavigationStack {
                    centreColumn
                        .toolbar { toolbarItems }
                }
            }
            .navigationSplitViewStyle(.balanced)

        case .threeColumn:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                AgentSidebar(hub: hub, isRail: true)
                    .navigationSplitViewColumnWidth(layout.sidebarWidth)
            } content: {
                NavigationStack {
                    centreColumn
                        .toolbar { toolbarItems }
                }
                .navigationSplitViewColumnWidth(min: 420, ideal: 640)
            } detail: {
                notificationPanel
                    .navigationSplitViewColumnWidth(HubLayout.rightPanelWidth)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    /// The centre column. Overview is the dashboard grid; a selection replaces
    /// it with that agent or benchmark.
    @ViewBuilder
    private var centreColumn: some View {
        Group {
            switch hub.selection {
            case .overview:
                dashboard(showsSidePanelCards: layout != .threeColumn)
                    .navigationTitle("Overview")

            case .agent(let id):
                if let agent = hub.snapshot.agents.first(where: { $0.id == id }) {
                    AgentDetailView(hub: hub, agent: agent, onAnnotate: { annotation = $0 })
                        .navigationTitle(agent.name)
                } else {
                    EmptyHubState(error: nil)
                }

            case .docking(let id):
                if let progress = hub.snapshot.docking.first(where: { $0.id == id }) {
                    DockingDetailView(
                        hub: hub, progress: progress, onAnnotate: { annotation = $0 }
                    )
                    .navigationTitle(progress.benchmarkName)
                } else {
                    EmptyHubState(error: nil)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dashboard(showsSidePanelCards: Bool) -> some View {
        DashboardGridView(
            hub: hub,
            width: width,
            showsSidePanelCards: showsSidePanelCards,
            onAnnotate: { annotation = $0 }
        )
        .refreshable { await hub.refresh() }
    }

    private var notificationPanel: some View {
        NotificationPanelView(
            pending: hub.pendingConfirmations,
            agentName: hub.agentName(for:),
            notifications: hub.visibleNotifications,
            isImportant: hub.isImportant,
            onConfirm: { hub.answer($0, approved: true) },
            onDeny: { hub.answer($0, approved: false) },
            onDismissNotification: hub.dismissNotification,
            onMarkImportant: hub.markImportant
        )
        .navigationTitle("Feed")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if layout != .threeColumn {
                NavigationLink {
                    notificationPanel
                } label: {
                    Image(systemName: "bell")
                        .overlay(alignment: .topTrailing) {
                            if !hub.pendingConfirmations.isEmpty {
                                Circle()
                                    .fill(Color.shannonWarning)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 4, y: -3)
                            }
                        }
                }
            }

            Button { hub.isPaletteVisible = true } label: {
                Image(systemName: "command")
            }
            .accessibilityLabel("Command palette")

            Button { voice.toggle() } label: {
                Image(systemName: voice.isListening ? "mic.fill" : "mic")
                    .foregroundStyle(voice.isListening ? Color.shannonError : Color.shannonAccent)
            }
            .accessibilityLabel(voice.isListening ? "Stop dictation" : "Start dictation")

            SyncIndicator(
                syncedAt: hub.store.lastSyncedAt,
                isRefreshing: hub.store.isRefreshing
            )
        }
    }

    /// Floating transcript. Sits above the bottom edge — and above the software
    /// keyboard when one is up, since the safe area already accounts for it.
    @ViewBuilder
    private var voiceChip: some View {
        if voice.isListening || voice.errorMessage != nil {
            HStack(spacing: ShannonSpacing.sm) {
                Image(systemName: voice.errorMessage == nil ? "waveform" : "mic.slash")
                    .foregroundStyle(
                        voice.errorMessage == nil ? Color.shannonAccent : Color.shannonError
                    )
                Text(voice.errorMessage ?? (voice.transcript.isEmpty ? "Listening…" : voice.transcript))
                    .shannonText(.shannonCallout)
                    .lineLimit(1)
                if voice.isListening {
                    Button("Stop") { voice.stop() }
                        .font(.shannonCaption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.shannonSecondary)
                }
            }
            .padding(.horizontal, ShannonSpacing.md)
            .padding(.vertical, ShannonSpacing.sm)
            .background(Color.shannonSurface, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.bottom, ShannonSpacing.lg)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.shannonFloat, value: voice.isListening)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = hub.statusMessage {
            Text(message)
                .shannonText(.shannonCallout)
                .padding(.horizontal, ShannonSpacing.md)
                .padding(.vertical, ShannonSpacing.sm)
                .background(Color.shannonSurfaceElevated, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                .padding(.top, ShannonSpacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var paletteOverlay: some View {
        if hub.isPaletteVisible {
            PaletteBackdrop(onDismiss: { hub.isPaletteVisible = false }) {
                CommandPaletteView(
                    actions: PaletteCatalogue.actions(for: hub),
                    onDismiss: { hub.isPaletteVisible = false }
                )
            }
            .zIndex(10)
        }
    }
}

/// The left column. Same content as a rail or a sidebar; the rail drops the
/// secondary line so 240pt still reads cleanly.
struct AgentSidebar: View {
    @ObservedObject var hub: AgentHubViewModel
    var isRail: Bool

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                row(
                    title: "Overview",
                    symbol: "square.grid.2x2",
                    tint: .shannonAccent,
                    tag: HubSelection.overview
                )
            }

            if !hub.snapshot.docking.isEmpty {
                Section("Benchmarks") {
                    ForEach(hub.snapshot.docking) { progress in
                        row(
                            title: progress.benchmarkName,
                            subtitle: progress.countLabel,
                            symbol: "atom",
                            tint: progress.isRunning ? .shannonAccent : .shannonNeutral,
                            tag: HubSelection.docking(progress.id)
                        )
                    }
                }
            }

            Section("Agents · \(hub.snapshot.agents.runningCount) running") {
                ForEach(Array(hub.visibleAgents.enumerated()), id: \.element.id) { index, agent in
                    HStack(spacing: ShannonSpacing.sm) {
                        ShannonStatusDot(state: agent.activity.dotState, diameter: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.name)
                                .shannonText(.shannonCallout)
                                .lineLimit(1)
                            if !isRail {
                                Text(agent.entropyLabel ?? agent.activity.label)
                                    .shannonNumeric(color: .shannonTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        // ⌘1…⌘9 focus by position, so the position is shown.
                        if index < 9 {
                            Text("⌘\(index + 1)")
                                .shannonNumeric(color: .shannonTertiary)
                        }
                    }
                    .tag(HubSelection.agent(agent.id))
                    .contextMenu {
                        Button { hub.togglePin(agent.id) } label: {
                            Label(
                                hub.isPinned(agent.id) ? "Unpin" : "Pin to Top",
                                systemImage: "pin"
                            )
                        }
                        Button(role: .destructive) { hub.dismissAgent(agent.id) } label: {
                            Label("Dismiss", systemImage: "xmark.circle")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Shannon")
    }

    /// `List` selection is optional; the hub always has one, and a tap on empty
    /// space should not clear it back to nothing.
    private var selectionBinding: Binding<HubSelection?> {
        Binding(
            get: { hub.selection },
            set: { if let new = $0 { hub.select(new) } }
        )
    }

    private func row(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        tint: Color,
        tag: HubSelection
    ) -> some View {
        HStack(spacing: ShannonSpacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(title)
                .shannonText(.shannonCallout)
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .shannonNumeric(color: .shannonTertiary)
            }
        }
        .tag(tag)
    }
}

/// Last sync time, and a spinner while a fetch is in flight. Mirrors the
/// phone's indicator so both companions age the same way.
struct SyncIndicator: View {
    var syncedAt: Date?
    var isRefreshing: Bool

    var body: some View {
        Group {
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else if let syncedAt {
                Text(syncedAt, style: .relative)
                    .shannonNumeric(color: .shannonTertiary)
            } else {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(Color.shannonTertiary)
            }
        }
        .accessibilityLabel("Sync status")
    }
}
