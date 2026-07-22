import Charts
import SwiftUI
import ShannonCore
import ShannonTheme
#if canImport(UIKit)
import UIKit
#endif

/// Battery rings for the devices in the loop.
///
/// The Mac ring comes from the synced snapshot; the iPad ring is read locally.
/// AirPods have no record type yet — the Mac publishes head-gesture motion but
/// not headphone battery — so that ring renders as unknown rather than
/// inventing a number.
struct BatteryCardView: View {
    var device: MacDeviceState?
    var airPodsPercent: Int?

    @State private var padPercent: Int?
    @State private var padCharging = false

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.md) {
            Label("Power", systemImage: "bolt.fill")
                .shannonText(.shannonHeadline, color: .shannonAccent)

            HStack(spacing: ShannonSpacing.lg) {
                BatteryRing(
                    title: device?.deviceName ?? "Mac",
                    percent: device?.batteryPercent,
                    isCharging: device?.isCharging ?? false,
                    symbol: "laptopcomputer"
                )
                BatteryRing(
                    title: "iPad",
                    percent: padPercent,
                    isCharging: padCharging,
                    symbol: "ipad"
                )
                BatteryRing(
                    title: "AirPods",
                    percent: airPodsPercent,
                    isCharging: false,
                    symbol: "airpodspro"
                )
            }

            if let device, device.isStale() {
                Label("Mac state is stale", systemImage: "exclamationmark.triangle")
                    .shannonText(.shannonCaption, color: .shannonWarning)
            }
        }
        .shannonCard()
        .onAppear(perform: readLocalBattery)
    }

    private func readLocalBattery() {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        // -1 means the level is unknown, which is not the same as empty.
        padPercent = level < 0 ? nil : Int((level * 100).rounded())
        padCharging = UIDevice.current.batteryState == .charging
            || UIDevice.current.batteryState == .full
        #endif
    }
}

struct BatteryRing: View {
    var title: String
    var percent: Int?
    var isCharging: Bool
    var symbol: String

    private var fraction: Double { Double(percent ?? 0) / 100 }

    private var tint: Color {
        guard let percent else { return .shannonNeutral }
        if isCharging { return .shannonSuccess }
        if percent <= 10 { return .shannonError }
        if percent <= 25 { return .shannonWarning }
        return .shannonAccent
    }

    var body: some View {
        VStack(spacing: ShannonSpacing.xs) {
            ZStack {
                Circle()
                    .stroke(Color.shannonSurfaceElevated, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: percent == nil ? 0 : max(fraction, 0.001))
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.shannonEase, value: fraction)
                Image(systemName: isCharging ? "bolt.fill" : symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
            }
            .frame(width: 56, height: 56)

            Text(percent.map { "\($0)%" } ?? "—")
                .shannonNumeric(color: .shannonPrimary)
            Text(title)
                .shannonText(.shannonCaption, color: .shannonTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) battery \(percent.map(String.init) ?? "unknown") percent")
    }
}

/// Entropy H across every agent that reports it.
///
/// One line per agent, drawn against the collapse threshold. This is the card
/// the whole library exists for: when a line dives through −3.2 bits of z-score
/// the agent has narrowed, and the shape of that dive is the evidence.
struct EntropyChartCardView: View {
    var agents: [AgentState]
    var series: [String: [MetricSample]]
    var onSelectAgent: (String) -> Void

    /// Only agents with at least two samples can be drawn; a single point is a
    /// dot, not a trend, and reads as noise.
    private var plotted: [AgentState] {
        agents.filter { (series[$0.id]?.count ?? 0) > 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.md) {
            HStack {
                Label("Shannon Entropy", systemImage: "waveform.path.ecg")
                    .shannonText(.shannonHeadline, color: .shannonAccent)
                Spacer()
                Text("bits")
                    .shannonText(.shannonCaption, color: .shannonTertiary)
            }

            if plotted.isEmpty {
                Text("Collecting samples…")
                    .shannonText(.shannonCaption, color: .shannonSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(plotted) { agent in
                        ForEach(series[agent.id] ?? []) { sample in
                            LineMark(
                                x: .value("Time", sample.date),
                                y: .value("H", sample.value)
                            )
                            .foregroundStyle(by: .value("Agent", agent.name))
                            .interpolationMethod(.monotone)
                        }
                    }
                    // The band an evaluation-aware model collapses into.
                    RectangleMark(yStart: .value("Low", 0), yEnd: .value("High", 4))
                        .foregroundStyle(Color.shannonError.opacity(0.10))
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartLegend(position: .bottom, spacing: ShannonSpacing.sm)
                .frame(minHeight: 160)
            }

            ForEach(agents.filter(\.isCollapsed)) { agent in
                Button { onSelectAgent(agent.id) } label: {
                    Label(
                        "\(agent.name) collapsed \(agent.entropyLabel ?? "")",
                        systemImage: "arrow.down.right.circle.fill"
                    )
                    .shannonText(.shannonCaption, color: .shannonError)
                }
                .buttonStyle(.plain)
            }
        }
        .shannonCard()
    }
}
