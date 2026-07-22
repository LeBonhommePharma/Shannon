import Charts
import SwiftUI
import ShannonCore
import ShannonTheme

/// The FlexAID∆S benchmark card: a large progress ring, the target in flight,
/// and the RMSD trace.
///
/// RMSD is the number the whole benchmark exists to move, so it is the one
/// figure rendered at display size; everything else on the card is metadata
/// around it.
struct DockingProgressView: View {
    var progress: DockingProgress
    var rmsdSeries: [MetricSample]
    var isSelected: Bool
    var isCompact: Bool = false

    var onSelect: () -> Void
    var onAnnotateROI: () -> Void
    var onCancel: () -> Void
    var onViewTargets: () -> Void
    var onExportCSV: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.md) {
            HStack(spacing: ShannonSpacing.sm) {
                Image(systemName: "atom")
                    .foregroundStyle(Color.shannonAccent)
                Text(progress.benchmarkName)
                    .shannonText(.shannonHeadline)
                Spacer()
                if progress.isRunning {
                    Text("running")
                        .shannonText(.shannonCaption, color: .shannonAccent)
                }
            }

            HStack(alignment: .center, spacing: ShannonSpacing.lg) {
                ProgressRing(fraction: progress.fraction, label: progress.countLabel)
                    .frame(width: isCompact ? 74 : 96, height: isCompact ? 74 : 96)

                VStack(alignment: .leading, spacing: ShannonSpacing.xs) {
                    metric(
                        "target",
                        progress.currentTarget.isEmpty ? "—" : progress.currentTarget.uppercased()
                    )
                    metric("best RMSD", rmsdText, tint: rmsdTint)
                    metric("ETA", progress.etaLabel ?? "—")
                    if let rate = progress.successRate {
                        metric("success", String(format: "%.0f%%", rate * 100))
                    }
                }
            }

            if !isCompact, rmsdSeries.count > 1 {
                RMSDSparkline(samples: rmsdSeries)
                    .frame(height: 52)
            }
        }
        .shannonCard(isHighlighted: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // A long press is what a Pencil sends when held against the card, and
        // is also the touch gesture — one gesture, both input devices.
        .onLongPressGesture(minimumDuration: 0.55, perform: onAnnotateROI)
        .contextMenu {
            Button(action: onViewTargets) {
                Label("View Target List", systemImage: "list.bullet.rectangle")
            }
            Button(action: onAnnotateROI) {
                Label("Draw Pocket ROI", systemImage: "scribble.variable")
            }
            Button(action: onExportCSV) {
                Label("Export Results CSV", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive, action: onCancel) {
                Label("Cancel Run", systemImage: "stop.circle")
            }
        }
    }

    private var rmsdText: String {
        guard let best = progress.bestRMSD else { return "—" }
        return String(format: "%.2f Å", best)
    }

    /// Under the 2.0 Å cutoff is a hit; the colour says so without a legend.
    private var rmsdTint: Color {
        guard let best = progress.bestRMSD else { return .shannonSecondary }
        return best <= DockingProgress.rmsdSuccessCutoff ? .shannonSuccess : .shannonWarning
    }

    private func metric(_ name: String, _ value: String, tint: Color = .shannonPrimary) -> some View {
        HStack(spacing: ShannonSpacing.sm) {
            Text(name)
                .shannonText(.shannonCaption, color: .shannonTertiary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.shannonMono)
                .foregroundStyle(tint)
        }
    }
}

/// Progress ring with the count in the middle. Trim animates on the shared
/// `shannonEase` spring so it settles like every other transition in the hub.
struct ProgressRing: View {
    var fraction: Double
    var label: String
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.shannonSurfaceElevated, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(fraction, 0.001))
                .stroke(
                    Color.shannonAccent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.shannonEase, value: fraction)

            VStack(spacing: 0) {
                Text(label)
                    .font(.system(.headline, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Color.shannonPrimary)
                Text("\(Int(fraction * 100))%")
                    .shannonText(.shannonCaption, color: .shannonSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) targets complete")
    }
}

/// Best RMSD over time, with the 2.0 Å success cutoff drawn in. Lower is
/// better, so the y-axis is inverted — the trace climbing means progress.
struct RMSDSparkline: View {
    var samples: [MetricSample]

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("RMSD", sample.value))
                    .foregroundStyle(Color.shannonAccent)
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Cutoff", DockingProgress.rmsdSuccessCutoff))
                .foregroundStyle(Color.shannonSuccess.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("2.0 Å")
                        .shannonText(.shannonCaption, color: .shannonSuccess)
                }
        }
        .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
    }
}
