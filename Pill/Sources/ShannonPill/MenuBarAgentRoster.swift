import SwiftUI
import PillCore
import ShannonTheme

// MARK: - Menu-bar popover agent roster (extracted)

/// Busy / live agent list for the menu-bar popover.
///
/// Uses `AgentLiveChrome` for badge labels so notch + popover cannot drift.
struct MenuBarAgentRoster: View {
    @ObservedObject var activity: AgentActivityMonitor
    @ObservedObject var bridge: ShannonBridge
    var agentReadings: [String: EntropyReading]
    var entropyTint: (EntropyReading) -> Color

    private var summary: AgentActivitySummary { activity.summary }
    private var busy: [AgentActivitySnapshot] { summary.busy }

    /// Roster rows: busy first, then connected/live, cap at 3.
    private var agentRows: [AgentActivitySnapshot] {
        if !busy.isEmpty { return Array(busy.prefix(3)) }
        let live = summary.agents.filter { agent in
            let line = agent.statusLine.lowercased()
            if line.contains("offline") { return false }
            return true
        }
        return Array((live.isEmpty ? summary.agents : live).prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text((busy.isEmpty ? "Agents" : "Active now").uppercased())
                .font(.shannonMenuSection)
                .foregroundStyle(Color.shannonSecondary)
                .tracking(0.8)
                .accessibilityAddTraits(.isHeader)
            if busy.isEmpty && summary.agents.isEmpty {
                Text("No agents. ⌘D attaches the front app · DatasetRunner fills FlexAIDdS progress.")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(2)
                    .frame(minHeight: 28, alignment: .topLeading)
            } else {
                ForEach(agentRows) { agent in
                    agentRow(agent)
                }
                let hidden = max(0, (busy.isEmpty ? summary.agents.count : busy.count) - agentRows.count)
                if hidden > 0 {
                    Text("+\(hidden) more")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
        }
    }

    private func agentRow(_ a: AgentActivitySnapshot) -> some View {
        let style = AgentStyleCatalog.style(for: a.id)
        let agentReading: EntropyReading = {
            if activity.entropyMemory.latest(for: a.id) != nil {
                return activity.entropyMemory.reading(
                    for: a.id,
                    gateDBAvailable: activity.gateDBAvailable
                )
            }
            return agentReadings[a.id]
                ?? EntropyProvenance.resolveForAgent(
                    agentId: a.id,
                    bridgeConnected: bridge.connected,
                    bridgeStatus: bridge.status,
                    gate: activity.agentEntropy,
                    gateDBAvailable: activity.gateDBAvailable
                )
        }()
        let surface = AgentLiveChrome.surface(
            agent: a,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity
        )
        let badge = AgentLiveChrome.badgeLabel(
            surface: surface,
            fallbackStatusLine: a.statusLine
        )
        let replay = surface.activityLine
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Text(style.emoji).font(.shannonMenuBody)
                Text(style.displayName)
                    .font(.shannonMenuBody)
                    .foregroundStyle(style.palette.ink)
                    .lineLimit(1)
                Text(badge)
                    .font(.shannonMenuSection)
                    .foregroundStyle(
                        AgentLiveChrome.attentionColor(
                            surface: surface,
                            styleInk: style.palette.ink
                        )
                    )
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(style.palette.wash))
                Spacer(minLength: 4)
                if let usage = surface.usage?.shortLabel {
                    Text(usage)
                        .font(.shannonMenuMono)
                        .foregroundStyle(Color.shannonTertiary)
                }
                agentEntropyLabel(agentReading)
                Text(a.relativeAge)
                    .font(.shannonMenuMono)
                    .foregroundStyle(Color.shannonTertiary)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            if !replay.isEmpty, surface.attention != .unknown {
                Text(replay)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 18, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(style.displayName), \(badge), \(replay), \(agentReading.explain(at: Date())), \(a.relativeAge)"
        )
    }

    @ViewBuilder
    private func agentEntropyLabel(_ reading: EntropyReading) -> some View {
        if let display = reading.display(at: Date()) {
            Text(display.shortLabel)
                .font(.shannonMenuMono)
                .foregroundStyle(entropyTint(reading))
                .help(reading.explain(at: Date()))
        } else {
            Text("—")
                .font(.shannonMenuMono)
                .foregroundStyle(Color.shannonNeutral)
                .help(reading.explain(at: Date()))
        }
    }
}
