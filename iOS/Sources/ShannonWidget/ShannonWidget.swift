import WidgetKit
import SwiftUI
import ShannonCore
import ShannonTheme

/// Lock Screen / Home Screen widget: agent count plus the FlexAID∆S ring.
///
/// The widget process cannot share the app's memory, so it reads the snapshot
/// the app wrote to the App Group container. That file carries a Data
/// Protection class of `completeUnlessOpen` — encrypted at rest, still
/// readable while the phone is locked, which is exactly when a Lock Screen
/// widget is rendered.
struct ShannonWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShannonWidget", provider: SnapshotProvider()) { entry in
            ShannonWidgetView(snapshot: entry.snapshot)
                .containerBackground(Color.shannonBackground, for: .widget)
        }
        .configurationDisplayName("Shannon")
        .description("Agents running on your Mac and docking progress.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

@main
struct ShannonWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShannonWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: ShannonSnapshot
}

struct SnapshotProvider: TimelineProvider {
    static let placeholder = ShannonSnapshot(
        agents: [AgentState(id: "a", name: "FlexAID∆S", activity: .running,
                            turnCount: 12, entropyBits: 0.61)],
        docking: [DockingProgress(id: "astex", benchmarkName: "Astex Diverse",
                                  targetsComplete: 34, targetsTotal: 85, bestRMSD: 1.42)]
    )

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: Self.placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(),
                                 snapshot: SnapshotCache.phone.load() ?? Self.placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(),
                                  snapshot: SnapshotCache.phone.load() ?? ShannonSnapshot())
        // The app reloads timelines on every CloudKit push, which is what
        // meets the 15 s target; this interval is only the fallback for when
        // the app has not run in a while.
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
            if let docking {
                Gauge(value: docking.fraction) {
                    Text("\(docking.targetsComplete)")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                Gauge(value: 0) { Text("\(snapshot.agents.runningCount)") }
                    .gaugeStyle(.accessoryCircularCapacity)
            }

        case .accessoryInline:
            Text(snapshot.complicationLine())

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Shannon").font(.caption2.weight(.semibold))
                ForEach(Array(snapshot.watchCards(limit: 2).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospacedDigit()).lineLimit(1)
                }
            }

        default:
            VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
                HStack(spacing: ShannonSpacing.xs) {
                    Image(systemName: "cpu")
                    Text("\(snapshot.agents.runningCount)")
                    Spacer()
                }
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonSecondary)

                if let docking {
                    HStack(spacing: ShannonSpacing.sm) {
                        WidgetRing(fraction: docking.fraction, label: docking.countLabel)
                            .frame(width: 54, height: 54)
                        Spacer(minLength: 0)
                    }
                    Text(docking.benchmarkName)
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonTertiary)
                        .lineLimit(1)
                } else {
                    Spacer()
                    Text("Idle")
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
        }
    }
}

struct WidgetRing: View {
    var fraction: Double
    var label: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.shannonAccentSubtle, lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(fraction, 0.001))
                .stroke(Color.shannonAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(.shannonMono)
                .foregroundStyle(Color.shannonPrimary)
        }
    }
}
