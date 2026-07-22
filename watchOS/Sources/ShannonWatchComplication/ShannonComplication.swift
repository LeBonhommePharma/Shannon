import WidgetKit
import SwiftUI
import ShannonCore
import ShannonTheme

/// Watch face complications, in every family watchOS offers third parties.
///
/// Between these and the in-app Shannon Face view, LP can assemble a face that
/// is effectively a Shannon face — Apple does not allow third-party watch
/// faces themselves, so complications are the supported route onto the face.
///
/// Data arrives from the phone relay, which reloads these timelines on every
/// change; that path, not the fallback interval below, is what keeps latency
/// from a Mac state change under ~15 s.
@available(watchOS 10.0, *)
struct ShannonComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShannonComplication", provider: ComplicationProvider()) { entry in
            ComplicationView(snapshot: entry.snapshot)
                .containerBackground(Color.shannonBackground, for: .widget)
        }
        .configurationDisplayName("Shannon")
        .description("Docking progress, agent status, or Now Playing.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular,
        ])
    }
}

@main
@available(watchOS 10.0, *)
struct ShannonComplicationBundle: WidgetBundle {
    var body: some Widget {
        ShannonComplication()
    }
}

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: ShannonSnapshot
}

@available(watchOS 10.0, *)
struct ComplicationProvider: TimelineProvider {
    static let placeholder = ShannonSnapshot(
        agents: [AgentState(id: "a", name: "FlexAID∆S", activity: .running, entropyBits: 0.61)],
        docking: [DockingProgress(id: "astex", benchmarkName: "Astex Diverse",
                                  targetsComplete: 78, targetsTotal: 85, bestRMSD: 0.34)]
    )

    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date(), snapshot: Self.placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(ComplicationEntry(date: Date(),
                                     snapshot: SnapshotCache.watch.load() ?? Self.placeholder))
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let entry = ComplicationEntry(date: Date(),
                                      snapshot: SnapshotCache.watch.load() ?? ShannonSnapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

@available(watchOS 10.0, *)
struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    let snapshot: ShannonSnapshot

    /// In the Smart Stack the widget is shown with its own background and has
    /// the full card width; on a watch face it is tinted, cramped and must
    /// stay terse. `showsWidgetContainerBackground` is how the two are told
    /// apart.
    private var isInSmartStack: Bool { showsBackground }

    private var docking: DockingProgress? {
        snapshot.docking.first(where: { $0.isRunning }) ?? snapshot.docking.first
    }

    private var agent: AgentState? { snapshot.agents.rankedForDisplay().first }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular

        case .accessoryCorner:
            corner

        case .accessoryInline:
            // Single line, system-styled: no custom fonts or colours allowed.
            Text(snapshot.complicationLine())

        default:
            rectangular
        }
    }

    // MARK: Families

    @ViewBuilder
    private var circular: some View {
        if let pending = snapshot.oldestPendingConfirmation() {
            // A blocked agent is the only thing worth overriding progress for.
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "questionmark")
                    .font(.title3)
            }
            .accessibilityLabel("Shannon question: \(pending.question)")
        } else if let docking {
            Gauge(value: docking.fraction) {
                Text("Å")
            } currentValueLabel: {
                Text("\(docking.targetsComplete)")
                    .font(.system(.body, design: .rounded).weight(.semibold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else if let entropy = agent?.entropyBits {
            // No benchmark running: fall back to the entropy readout, which is
            // the other number LP actually watches.
            Gauge(value: min(entropy / 12, 1)) {
                Text("H")
            } currentValueLabel: {
                Text(String(format: "%.2f", entropy))
                    .font(.system(.caption, design: .rounded))
            }
            .gaugeStyle(.accessoryCircular)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "cpu")
            }
        }
    }

    @ViewBuilder
    private var corner: some View {
        if let docking {
            Image(systemName: "atom")
                .font(.title2)
                .widgetLabel {
                    Gauge(value: docking.fraction) {
                        Text(docking.countLabel)
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                }
        } else {
            Image(systemName: "cpu")
                .font(.title2)
                .widgetLabel(snapshot.complicationLine())
        }
    }

    @ViewBuilder
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: isInSmartStack ? 3 : 1) {
            if let pending = snapshot.oldestPendingConfirmation() {
                Text("Shannon asks")
                    .font(.caption2.weight(.semibold))
                    .widgetAccentable()
                Text(pending.question)
                    .font(.caption2)
                    .lineLimit(2)
            } else {
                HStack(spacing: 4) {
                    if let agent {
                        Text(agent.activity.glyph)
                            .font(.caption2)
                            .widgetAccentable()
                        Text(agent.name)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    } else {
                        Text("Shannon").font(.caption2.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                    if let entropy = agent?.entropyBits {
                        Text(String(format: "H %.2f", entropy))
                            .font(.caption2.monospacedDigit())
                    }
                }

                if let docking {
                    // Smart Stack has room for the bar; a watch face does not.
                    if isInSmartStack {
                        Gauge(value: docking.fraction) {
                            EmptyView()
                        }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .widgetAccentable()
                    }
                    Text(docking.complicationLine())
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                } else if let media = snapshot.nowPlaying?.compactLine() {
                    Text(media).font(.caption2).lineLimit(1)
                }
            }
        }
    }
}
