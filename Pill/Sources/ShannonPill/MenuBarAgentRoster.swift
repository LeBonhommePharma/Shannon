import SwiftUI
import PillCore
import Routes
import ShannonCore

// MARK: - Menu-bar popover agent roster (extracted)

/// Busy / live agent list for the menu-bar popover.
///
/// Uses `AgentLiveChrome` + `SessionContentPresenter` so notch + popover
/// share attention ranking and badge wording (AgentNotch-class fleet).
struct MenuBarAgentRoster: View {
    @ObservedObject var activity: AgentActivityMonitor
    @ObservedObject var bridge: ShannonBridge
    var agentReadings: [String: EntropyReading]
    var entropyTint: (EntropyReading) -> Color
    /// Optional pulled/gate sessions keyed by agent id for project/branch/model.
    var sessionsByAgent: [String: AgentSession] = [:]

    private var summary: AgentActivitySummary { activity.summary }
    private var busy: [AgentActivitySnapshot] { summary.busy }

    /// Roster cards: needs-you → working → finished → idle, cap at 3.
    private var rosterCards: [SessionContentCard] {
        SessionContentPresenter.cardsFromAgents(
            agents: summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity,
            sessionsByAgent: sessionsByAgent,
            limit: 3,
            // UX-043: roster Approve hint requires hub socket (showsApproveHint).
            gateAvailable: activity.gateAvailable
        )
    }

    private var hasActionable: Bool {
        rosterCards.contains {
            $0.attention == .needsYou || $0.attention == .working || $0.attention == .finished
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text((hasActionable ? "Active now" : "Agents").uppercased())
                .font(.shannonMenuSection)
                .foregroundStyle(Color.shannonSecondary)
                .tracking(0.8)
                .accessibilityAddTraits(.isHeader)
            if summary.agents.isEmpty {
                // UX-015: idle title matches Core / companions; Mac-only attach hint stays local.
                Text(
                    "\(CompanionEmptyStateCopy.idleTitle). ⌘D attaches the front app · DatasetRunner fills FlexAIDdS progress."
                )
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(2)
                    .frame(minHeight: 28, alignment: .topLeading)
            } else {
                ForEach(rosterCards) { card in
                    agentCardRow(card)
                }
                let hidden = max(0, summary.agents.count - rosterCards.count)
                if hidden > 0 {
                    Text("+\(hidden) more")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
        }
    }

    private func agentCardRow(_ card: SessionContentCard) -> some View {
        let style = AgentStyleCatalog.style(for: card.agentId)
        // Prefer measured resolveAll (sole-live / alias bridge) over stale memory
        // that would show "—" under enforce while attach H is measured.
        let resolved = agentReadings[card.agentId]
            ?? EntropyProvenance.resolveForAgent(
                agentId: card.agentId,
                bridgeConnected: bridge.connected,
                bridgeStatus: bridge.status,
                gate: activity.agentEntropy,
                gateDBAvailable: activity.gateDBAvailable
            )
        let mem: EntropyReading? = activity.entropyMemory.latest(for: card.agentId) != nil
            ? activity.entropyMemory.reading(
                for: card.agentId,
                gateDBAvailable: activity.gateDBAvailable
            )
            : nil
        let agentReading = EntropyProvenance.preferredRowReading(
            live: resolved,
            memory: mem
        )
        // Synthetic surface for shared attention color (badge already on card).
        let surface = AgentLiveSurface(
            agentId: card.agentId,
            displayName: card.displayName,
            attention: card.attention,
            activityLine: card.activityLine,
            usage: card.usage,
            needsYou: card.needsYou,
            isFinished: card.isFinished
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Text(style.emoji).font(.shannonMenuBody)
                Text(card.displayName)
                    .font(.shannonMenuBody)
                    .foregroundStyle(style.palette.ink)
                    .lineLimit(1)
                Text(card.badgeLabel)
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
                if let usage = card.usageLabel {
                    Text(usage)
                        .font(.shannonMenuMono)
                        .foregroundStyle(Color.shannonTertiary)
                }
                agentEntropyLabel(agentReading)
                if let age = card.relativeAge {
                    Text(age)
                        .font(.shannonMenuMono)
                        .foregroundStyle(Color.shannonTertiary)
                        .frame(minWidth: 28, alignment: .trailing)
                }
            }
            if let detail = card.rosterDetailLine {
                Text(detail)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Text-only hint — GateInlineCard owns real Approve/Deny actions.
            // UX-027: share GateAskActionCopy.rosterApproveHint (not dual literal).
            if card.showsApproveHint {
                Text(GateAskActionCopy.rosterApproveHint)
                    .font(.shannonMenuSection)
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let meta = card.metaLine {
                Text(meta)
                    .font(.shannonMenuMono)
                    .foregroundStyle(Color.shannonTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 18, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rosterAccessibilityLabel(card: card, reading: agentReading))
        // ENH-028 / ENH-029: jump host or open terminal workspace when evidence exists.
        .contextMenu {
            let action = jumpAction(for: card.agentId)
            if action.isAvailable {
                Button(action.affordanceLabel) {
                    _ = HostTerminalJumpExecutor.perform(action)
                }
            }
            let term = openTerminalAction(for: card.agentId)
            if term.isAvailable {
                Button(term.affordanceLabel) {
                    _ = OpenTerminalHereExecutor.perform(term)
                }
            }
        }
    }

    /// Pure policy for roster row — fail-closed when host + cwd both unknown.
    private func jumpAction(for agentId: String) -> HostTerminalJumpAction {
        let agent = summary.agents.first(where: { $0.id == agentId })
        let session = sessionsByAgent[agentId]
        return HostTerminalJumpPolicy.decide(
            attachBundle: agent?.attachBundle,
            attachPid: agent?.attachPid,
            session: session,
            runningBundleIDs: AgentActivityMonitor.enumerateRunningBundleIDs()
        )
    }

    /// ENH-029 pure policy — fail-closed when session cwd unknown / missing on disk.
    private func openTerminalAction(for agentId: String) -> OpenTerminalHereAction {
        let agent = summary.agents.first(where: { $0.id == agentId })
        let session = sessionsByAgent[agentId]
        return OpenTerminalHerePolicy.decide(
            attachBundle: agent?.attachBundle,
            session: session
        )
    }

    /// Accessibility label: prefer pending ask prompt when present (ENH-006).
    private func rosterAccessibilityLabel(card: SessionContentCard, reading: EntropyReading) -> String {
        var parts: [String] = [card.displayName, card.badgeLabel]
        if let prompt = card.pendingPrompt, !prompt.isEmpty {
            parts.append(prompt)
        } else if let detail = card.rosterDetailLine {
            parts.append(detail)
        } else if !card.activityLine.isEmpty {
            parts.append(card.activityLine)
        }
        if card.showsApproveHint {
            parts.append(GateAskActionCopy.rosterApproveAccessibility)
        }
        parts.append(reading.explain(at: Date()))
        if let age = card.relativeAge {
            parts.append(age)
        }
        return parts.joined(separator: ", ")
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
