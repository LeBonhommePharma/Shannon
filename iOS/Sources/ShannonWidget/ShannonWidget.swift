import WidgetKit
import SwiftUI
import ShannonCore

/// Lock Screen / Home Screen widget: agent count plus the FlexAID∆S ring.
///
/// The widget process cannot share the app's in-memory store, so the app
/// writes each refreshed snapshot to the shared App Group container and the
/// timeline provider reads it back.
struct ShannonWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShannonWidget", provider: SnapshotProvider()) { entry in
            ShannonWidgetView(snapshot: entry.snapshot)
                .widgetContainerBackground()
        }
        .configurationDisplayName("Shannon")
        .description("Agents running on your Mac and docking progress.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}

@main
struct ShannonWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShannonWidget()
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

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: ShannonSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.load()
                                 ?? WidgetSnapshotStore.placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.load()
                                  ?? ShannonSnapshot())
        // WidgetKit budgets refreshes; the app also reloads timelines on every
        // CloudKit push, so this interval is only the fallback.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct ShannonWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: ShannonSnapshot

    private var docking: DockingProgress? {
        snapshot.docking.first(where: { $0.isRunning }) ?? snapshot.docking.first
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                if let docking {
                    Gauge(value: docking.fraction) {
                        Text("\(docking.targetsComplete)")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                } else {
                    Gauge(value: 0) { Text("\(snapshot.agents.runningCount)") }
                        .gaugeStyle(.accessoryCircularCapacity)
                }
            }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Shannon").font(.caption2.weight(.semibold))
                Text(snapshot.complicationLine()).font(.caption.monospacedDigit())
            }

        default:
            VStack(spacing: 8) {
                HStack {
                    Label("\(snapshot.agents.runningCount)", systemImage: "cpu")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                if let docking {
                    ProgressRingCompact(fraction: docking.fraction,
                                        label: docking.countLabel)
                        .frame(width: 66, height: 66)
                    Text(docking.benchmarkName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No benchmark running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ProgressRingCompact: View {
    var fraction: Double
    var label: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.purple.opacity(0.2), lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(fraction, 0.001))
                .stroke(Color.purple, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label).font(.caption2.weight(.semibold).monospacedDigit())
        }
    }
}
