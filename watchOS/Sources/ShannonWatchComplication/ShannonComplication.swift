import WidgetKit
import SwiftUI
import ShannonCore

/// Watch face complication: one glanceable line, e.g. "34/85 ✓ 1.42Å H=0.61"
/// or "▶ Track — Artist". The selection logic lives in ShannonCore so the
/// complication and the phone never disagree about what matters right now.
struct ShannonComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShannonComplication", provider: ComplicationProvider()) { entry in
            ComplicationView(snapshot: entry.snapshot)
                .widgetContainerBackground()
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
struct ShannonComplicationBundle: WidgetBundle {
    var body: some Widget {
        ShannonComplication()
    }
}

/// `containerBackground` is iOS 17 / watchOS 10; on the iOS 16 and watchOS 9
/// deployment targets the widget simply keeps the system default background.
extension View {
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        if #available(iOS 17.0, watchOS 10.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self
        }
    }
}

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: ShannonSnapshot
}

struct ComplicationProvider: TimelineProvider {
    private var placeholder: ShannonSnapshot {
        ShannonSnapshot(
            agents: [AgentState(id: "a", name: "FlexAID∆S", activity: .running,
                                entropyBits: 0.61)],
            docking: [DockingProgress(id: "astex", benchmarkName: "Astex Diverse",
                                      targetsComplete: 34, targetsTotal: 85, bestRMSD: 1.42)]
        )
    }

    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date(), snapshot: placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(ComplicationEntry(date: Date(),
                                     snapshot: WatchSnapshotCache.load() ?? placeholder))
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let entry = ComplicationEntry(date: Date(),
                                      snapshot: WatchSnapshotCache.load() ?? ShannonSnapshot())
        // The relay reloads timelines whenever the phone pushes, so this is
        // only the fallback cadence.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: ShannonSnapshot

    private var docking: DockingProgress? {
        snapshot.docking.first(where: { $0.isRunning }) ?? snapshot.docking.first
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            if let docking {
                Gauge(value: docking.fraction) {
                    Text("\(docking.targetsComplete)").font(.caption2.monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                Gauge(value: 0) {
                    Text("\(snapshot.agents.runningCount)").font(.caption2.monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)
            }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Shannon").font(.caption2.weight(.semibold))
                ForEach(Array(snapshot.watchCards(limit: 2).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospacedDigit()).lineLimit(1)
                }
            }

        default:
            Text(snapshot.complicationLine())
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
        }
    }
}
