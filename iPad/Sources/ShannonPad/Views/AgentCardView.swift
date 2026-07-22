import Charts
import SwiftUI
import UniformTypeIdentifiers
import ShannonCore
import ShannonTheme

/// Payload type for card-to-card drags. A private UTI keeps the drag from being
/// accepted by unrelated apps in Split View — dropping an agent into Notes
/// should do nothing rather than paste a raw id.
extension UTType {
    static let shannonAgent = UTType(exportedAs: "com.lebonhommepharma.shannon.agent")
}

/// One agent, as a dashboard tile.
///
/// The same view is used in the grid and in the centre column; `isCompact`
/// only trims the chart and the secondary lines, so an agent looks like itself
/// at every width.
struct AgentCardView: View {
    var agent: AgentState
    var entropySeries: [MetricSample]
    var isSelected: Bool
    var isPinned: Bool
    var isDropTarget: Bool
    var upstreamNames: [String]
    var isCompact: Bool = false

    var onSelect: () -> Void
    var onAnnotate: () -> Void
    var onPin: () -> Void
    var onDismiss: () -> Void
    var onViewLog: () -> Void
    var onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            header

            Text(agent.taskTitle.isEmpty ? "No task" : agent.taskTitle)
                .shannonText(.shannonBody)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isCompact {
                Text(agent.lastAction.isEmpty ? "—" : agent.lastAction)
                    .shannonText(.shannonCaption, color: .shannonSecondary)
                    .lineLimit(1)
            }

            footer

            if !isCompact, entropySeries.count > 1 {
                EntropySparkline(samples: entropySeries, tint: agent.activity.tint)
                    .frame(height: 34)
            }

            if !upstreamNames.isEmpty {
                Label(
                    "fed by \(upstreamNames.joined(separator: ", "))",
                    systemImage: "arrow.triangle.branch"
                )
                .shannonText(.shannonCaption, color: .shannonAccent)
                .lineLimit(1)
            }
        }
        .shannonCard(isHighlighted: isSelected)
        .overlay {
            RoundedRectangle(cornerRadius: ShannonLayout.IOSCard.radius, style: .continuous)
                .strokeBorder(
                    Color.shannonAccent,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
                .opacity(isDropTarget ? 1 : 0)
        }
        .animation(.shannonSnap, value: isDropTarget)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(action: onPin) {
                Label(isPinned ? "Unpin" : "Pin to Top", systemImage: "pin")
            }
            Button(action: onViewLog) {
                Label("View Full Log", systemImage: "doc.text.magnifyingglass")
            }
            Button(action: onAnnotate) {
                Label("Annotate with Pencil", systemImage: "pencil.tip.crop.circle")
            }
            Button(action: onCopy) {
                Label("Send to Mac Clipboard", systemImage: "doc.on.clipboard")
            }
            Divider()
            Button(role: .destructive, action: onDismiss) {
                Label("Dismiss", systemImage: "xmark.circle")
            }
        }
    }

    private var header: some View {
        HStack(spacing: ShannonSpacing.sm) {
            ShannonStatusDot(state: agent.activity.dotState, diameter: 8)
                .modifier(PulseIfRunning(isRunning: agent.activity == .running))

            Text(agent.name)
                .shannonText(.shannonHeadline)
                .lineLimit(1)

            if isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(Color.shannonAccent)
                    .font(.caption2)
            }

            Spacer(minLength: ShannonSpacing.xs)

            // The Pencil affordance is a real button so it is reachable by
            // touch and by VoiceOver, not only by hovering a Pencil.
            Button(action: onAnnotate) {
                Image(systemName: AnnotationStore.hasAnnotation(agentID: agent.id)
                      ? "pencil.tip.crop.circle.fill"
                      : "pencil.tip.crop.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.shannonSecondary)
            .accessibilityLabel("Annotate \(agent.name)")
        }
    }

    private var footer: some View {
        HStack(spacing: ShannonSpacing.md) {
            Label("\(agent.turnCount)", systemImage: "arrow.triangle.2.circlepath")
                .shannonNumeric()

            if let entropy = agent.entropyLabel {
                Text(entropy)
                    .shannonNumeric(color: agent.isCollapsed ? .shannonError : .shannonSecondary)
            }

            Spacer()

            Text(agent.activity.label)
                .shannonText(.shannonCaption, color: agent.activity.tint)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// The running dot breathes on the same 1.6s period as the Mac pill's border.
private struct PulseIfRunning: ViewModifier {
    var isRunning: Bool
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isRunning && pulsing ? 0.45 : 1)
            .animation(isRunning ? ShannonMotion.pillPulse : .shannonSnap, value: pulsing)
            .onAppear { pulsing = isRunning }
            .onChange(of: isRunning) { pulsing = $0 }
    }
}

/// Entropy in bits over the samples this iPad has seen. Flat is healthy; the
/// interesting shape is the cliff, so the y-domain is never clamped to hide it.
struct EntropySparkline: View {
    var samples: [MetricSample]
    var tint: Color

    var body: some View {
        Chart(samples) { sample in
            AreaMark(x: .value("Time", sample.date), y: .value("H", sample.value))
                .foregroundStyle(
                    .linearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            LineMark(x: .value("Time", sample.date), y: .value("H", sample.value))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}
