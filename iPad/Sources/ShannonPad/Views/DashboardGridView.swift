import SwiftUI
import UniformTypeIdentifiers
import ShannonCore
import ShannonTheme

/// Collects the centre of every agent card so the link overlay can draw
/// between them without either card knowing where the other one landed.
struct CardAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGPoint>] = [:]
    static func reduce(
        value: inout [String: Anchor<CGPoint>],
        nextValue: () -> [String: Anchor<CGPoint>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The overview: everything at once, in a grid that reflows from one column in
/// Slide Over to four on a 13" in landscape.
struct DashboardGridView: View {
    @ObservedObject var hub: AgentHubViewModel
    var width: CGFloat
    var showsSidePanelCards: Bool
    var onAnnotate: (AnnotationTarget) -> Void

    @State private var dropTargetID: String?

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: ShannonLayout.IOSCard.interCardSpacing),
            count: HubLayout.gridColumnCount(width: width)
        )
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: ShannonLayout.IOSCard.interCardSpacing) {
                ForEach(hub.snapshot.docking) { progress in
                    DockingProgressView(
                        progress: progress,
                        rmsdSeries: hub.rmsdSeries(for: progress.id),
                        isSelected: hub.selection == .docking(progress.id),
                        onSelect: { hub.select(.docking(progress.id)) },
                        onAnnotateROI: { onAnnotate(.dockingROI(progress.id)) },
                        onCancel: {},
                        onViewTargets: { hub.select(.docking(progress.id)) },
                        onExportCSV: {}
                    )
                }

                ForEach(hub.visibleAgents) { agent in
                    agentCard(agent)
                }

                if showsSidePanelCards {
                    if let media = hub.snapshot.nowPlaying, !media.isIdle {
                        NowPlayingCardView(
                            media: media,
                            onCommand: { hub.send($0) },
                            onOpenInMusic: openMusic
                        )
                    }

                    BatteryCardView(device: hub.snapshot.device, airPodsPercent: nil)
                }

                EntropyChartCardView(
                    agents: hub.visibleAgents,
                    series: hub.entropyHistory,
                    onSelectAgent: { hub.select(.agent($0)) }
                )

                if hub.snapshot.isEmpty {
                    EmptyHubState(error: hub.store.lastError)
                        .gridCellColumns(HubLayout.gridColumnCount(width: width))
                }
            }
            .padding(ShannonSpacing.md)
        }
        .background(Color.shannonBackground)
        // Links are drawn above the grid but below the cards' own controls, so
        // an edge never swallows a tap meant for the card underneath it.
        .overlayPreferenceValue(CardAnchorKey.self) { anchors in
            GeometryReader { proxy in
                LinkOverlay(links: hub.links, anchors: anchors, proxy: proxy)
            }
            .allowsHitTesting(false)
        }
    }

    private func agentCard(_ agent: AgentState) -> some View {
        AgentCardView(
            agent: agent,
            entropySeries: hub.entropySeries(for: agent.id),
            isSelected: hub.selection == .agent(agent.id),
            isPinned: hub.isPinned(agent.id),
            isDropTarget: dropTargetID == agent.id,
            upstreamNames: upstreamNames(of: agent.id),
            onSelect: { hub.select(.agent(agent.id)) },
            onAnnotate: { onAnnotate(.agent(agent.id, agent.name)) },
            onPin: { hub.togglePin(agent.id) },
            onDismiss: { hub.dismissAgent(agent.id) },
            onViewLog: { hub.select(.agent(agent.id)) },
            onCopy: { copyToClipboard(agent) }
        )
        .anchorPreference(key: CardAnchorKey.self, value: .center) { [agent.id: $0] }
        .onDrag {
            dropTargetID = nil
            return NSItemProvider(
                object: AgentDragPayload(agentID: agent.id)
            )
        }
        .onDrop(
            of: [UTType.shannonAgent.identifier, UTType.plainText.identifier],
            delegate: AgentDropDelegate(
                targetID: agent.id,
                dropTargetID: $dropTargetID,
                onLink: { source in _ = hub.link(from: source, to: agent.id) }
            )
        )
    }

    private func upstreamNames(of agentID: String) -> [String] {
        hub.upstream(of: agentID).compactMap { id in
            hub.snapshot.agents.first { $0.id == id }?.name
        }
    }

    private func copyToClipboard(_ agent: AgentState) {
        #if canImport(UIKit)
        // The Mac reads the shared pasteboard through Universal Clipboard, so
        // writing locally is the whole operation.
        UIPasteboard.general.string = """
        \(agent.name) — \(agent.activity.label)
        \(agent.taskTitle)
        \(agent.lastAction)
        turns: \(agent.turnCount)\(agent.entropyLabel.map { " · \($0)" } ?? "")
        """
        PadHaptics.tap()
        #endif
    }

    private func openMusic() {
        #if canImport(UIKit)
        guard let url = URL(string: "music://") else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

/// What a Pencil annotation is being opened for.
enum AnnotationTarget: Identifiable, Hashable {
    case agent(String, String)
    case dockingROI(String)

    var id: String {
        switch self {
        case .agent(let id, _):   return "agent-\(id)"
        case .dockingROI(let id): return "roi-\(id)"
        }
    }

    var scopeID: String {
        switch self {
        case .agent(let id, _):   return id
        case .dockingROI(let id): return id
        }
    }

    var name: String {
        switch self {
        case .agent:      return "canvas"
        case .dockingROI: return "pocket-roi"
        }
    }

    var title: String {
        switch self {
        case .agent(_, let name):  return "Notes · \(name)"
        case .dockingROI(let id):  return "Pocket ROI · \(id)"
        }
    }

    var isROI: Bool {
        if case .dockingROI = self { return true }
        return false
    }
}

/// Carries the dragged agent's id. A concrete `NSItemProvider` object type
/// rather than a bare string, so only Shannon accepts the drop.
final class AgentDragPayload: NSObject, NSItemProviderWriting, NSItemProviderReading {
    let agentID: String

    init(agentID: String) {
        self.agentID = agentID
    }

    static var writableTypeIdentifiersForItemProvider: [String] {
        [UTType.shannonAgent.identifier, UTType.plainText.identifier]
    }

    static var readableTypeIdentifiersForItemProvider: [String] {
        [UTType.shannonAgent.identifier, UTType.plainText.identifier]
    }

    func loadData(
        withTypeIdentifier typeIdentifier: String,
        forItemProviderCompletionHandler completionHandler:
            @escaping @Sendable (Data?, Error?) -> Void
    ) -> Progress? {
        completionHandler(Data(agentID.utf8), nil)
        return nil
    }

    static func object(withItemProviderData data: Data, typeIdentifier: String) throws -> Self {
        Self(agentID: String(decoding: data, as: UTF8.self))
    }
}

/// Highlights the card while a drag hovers, and links on release.
private struct AgentDropDelegate: DropDelegate {
    var targetID: String
    @Binding var dropTargetID: String?
    var onLink: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.shannonAgent.identifier])
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.shannonSnap) { dropTargetID = targetID }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.shannonSnap) {
            if dropTargetID == targetID { dropTargetID = nil }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.shannonSnap) { dropTargetID = nil }
        guard let provider = info.itemProviders(
            for: [UTType.shannonAgent.identifier]
        ).first else { return false }

        provider.loadObject(ofClass: AgentDragPayload.self) { payload, _ in
            guard let source = (payload as? AgentDragPayload)?.agentID else { return }
            Task { @MainActor in onLink(source) }
        }
        return true
    }
}

/// Draws the connections between linked cards as curves with an arrowhead at
/// the consuming end.
private struct LinkOverlay: View {
    var links: [AgentLink]
    var anchors: [String: Anchor<CGPoint>]
    var proxy: GeometryProxy

    var body: some View {
        Canvas { context, _ in
            for link in links {
                guard let sourceAnchor = anchors[link.sourceID],
                      let targetAnchor = anchors[link.targetID] else { continue }
                let from = proxy[sourceAnchor]
                let to = proxy[targetAnchor]

                var path = Path()
                path.move(to: from)
                // Bow the curve away from the straight line so two cards side
                // by side do not get an edge hidden under their own gap.
                let control = CGPoint(
                    x: (from.x + to.x) / 2 + (to.y - from.y) * 0.18,
                    y: (from.y + to.y) / 2 - (to.x - from.x) * 0.18
                )
                path.addQuadCurve(to: to, control: control)

                context.stroke(
                    path,
                    with: .color(.shannonAccent.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                context.fill(arrowhead(at: to, from: control), with: .color(.shannonAccent))
            }
        }
    }

    private func arrowhead(at point: CGPoint, from origin: CGPoint) -> Path {
        let angle = atan2(point.y - origin.y, point.x - origin.x)
        let size: CGFloat = 9
        var path = Path()
        path.move(to: point)
        path.addLine(to: CGPoint(
            x: point.x - cos(angle - .pi / 7) * size,
            y: point.y - sin(angle - .pi / 7) * size
        ))
        path.addLine(to: CGPoint(
            x: point.x - cos(angle + .pi / 7) * size,
            y: point.y - sin(angle + .pi / 7) * size
        ))
        path.closeSubpath()
        return path
    }
}

/// Shown when nothing has synced. The distinction that matters is "no work
/// running" versus "not talking to the Mac", so the error is named when there
/// is one.
struct EmptyHubState: View {
    var error: String?

    var body: some View {
        VStack(spacing: ShannonSpacing.md) {
            Image(systemName: error == nil ? "moon.zzz" : "icloud.slash")
                .font(.system(size: 42))
                .foregroundStyle(Color.shannonTertiary)
            Text(error == nil ? "No agents running" : "Not syncing with the Mac")
                .shannonText(.shannonTitle)
            if let error {
                Text(error)
                    .shannonText(.shannonCaption, color: .shannonSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ShannonSpacing.xxl)
    }
}
