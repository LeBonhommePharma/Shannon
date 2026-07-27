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
            ShannonWidgetView(
                snapshot: entry.snapshot,
                lastError: entry.lastError,
                now: entry.date
            )
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
        PetWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: ShannonSnapshot
    /// Hub/sync error mirrored from phone `SnapshotCache` (UX-038).
    let lastError: String?

    init(date: Date, snapshot: ShannonSnapshot, lastError: String? = nil) {
        self.date = date
        self.snapshot = snapshot
        self.lastError = lastError
    }
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
        completion(loadEntry(fallback: Self.placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = loadEntry(fallback: ShannonSnapshot())
        // PhoneModel reloads timelines after each successful App Group cache
        // write (UX-035), including offline fail-closed rewrites (UX-038).
        // This 15-minute policy is only the fallback when the host app has
        // not run recently.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }

    private func loadEntry(fallback: ShannonSnapshot) -> SnapshotEntry {
        if let record = SnapshotCache.phone.loadRecord() {
            return SnapshotEntry(
                date: Date(),
                snapshot: record.snapshot,
                lastError: record.lastError
            )
        }
        return SnapshotEntry(date: Date(), snapshot: fallback)
    }
}

struct ShannonWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: ShannonSnapshot
    /// Non-nil when phone last wrote a sync failure (UX-038 fail-closed).
    var lastError: String? = nil
    /// Entry date from the timeline — glance age uses Mac 15 s buckets (UX-008).
    var now: Date = Date()

    private var offline: CompanionEmptyStateCopy.Content {
        CompanionEmptyStateCopy.content(lastError: lastError)
    }

    /// Bucketed relative age for the freshest agent/docking/capture timestamp.
    private var glanceAge: String {
        SharedRelativeAge.glanceBucketed(in: snapshot, now: now)
    }

    private var docking: DockingProgress? {
        snapshot.docking.first(where: { $0.isRunning }) ?? snapshot.docking.first
    }

    var body: some View {
        // UX-038: offline flag fails closed — never paint healthy agent counts
        // from a stale cache while hub/sync is down.
        if offline.isOffline {
            offlineBody
        } else {
            onlineBody
        }
    }

    @ViewBuilder
    private var offlineBody: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: offline.systemImage)
                .font(.title2)
                .foregroundStyle(Color.shannonWarning)

        case .accessoryInline:
            Text(CompanionEmptyStateCopy.offlineChip)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(CompanionEmptyStateCopy.offlineTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.shannonWarning)
                Text(CompanionEmptyStateCopy.offlineChip)
                    .font(.caption2)
                    .foregroundStyle(Color.shannonTertiary)
            }

        default:
            VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
                HStack(spacing: ShannonSpacing.xs) {
                    Image(systemName: offline.systemImage)
                    Text(offline.title)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonWarning)

                Text(offline.detail)
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            .accessibilityLabel(
                "\(CompanionEmptyStateCopy.offlineTitle). \(CompanionEmptyStateCopy.offlineAccessibility)"
            )
        }
    }

    @ViewBuilder
    private var onlineBody: some View {
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
                HStack(spacing: 4) {
                    // UX-025: brand title shares Core quietShort.
                    Text(CompanionFocusCopy.quietShort).font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                    Text(glanceAge)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.shannonTertiary)
                }
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
                    Text(glanceAge)
                        .font(.shannonCaption.monospacedDigit())
                        .foregroundStyle(Color.shannonTertiary)
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
                    // UX-032: empty docking chrome shares DockingProgress.emptyGlance.
                    Text(DockingProgress.emptyGlance)
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
