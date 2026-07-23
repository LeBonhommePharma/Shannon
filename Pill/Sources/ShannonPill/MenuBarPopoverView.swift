import SwiftUI
import PillCore
import ShannonTheme

/// The menu-bar popover: everything LP needs at a glance without opening the
/// notch pill — busy agents, the newest pending gate (answerable inline),
/// a short activity log, hub connectivity, and quick links.
///
/// Data sources are the same live models the pill observes; nothing here is
/// duplicated state. Approvals go through `AgentActivityMonitor.resolve`, the
/// async path that never blocks the main thread and surfaces gate errors.
struct MenuBarPopoverView: View {
    @ObservedObject var activity: AgentActivityMonitor
    @ObservedObject var bridge: ShannonBridge
    @ObservedObject var idle: IdleTelemetryPublisher
    @ObservedObject var battery: BatteryMonitor

    var onShowAllGates: () -> Void
    var onOpenHubLog: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    private var entropy: ShannonStatus { bridge.status ?? idle.status }
    private var summary: AgentActivitySummary { activity.summary }
    private var busy: [AgentActivitySnapshot] { summary.busy }
    /// Newest pending approval — the one worth answering inline.
    private var ask: GateDBReader.PendingAsk? { activity.pendingAsks.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let ask {
                GateInlineCard(
                    ask: ask,
                    isResolving: activity.resolving.contains(ask.interactionId),
                    error: activity.lastResolveError,
                    extraPending: max(0, activity.pendingAsks.count - 1),
                    onAnswer: { approved in
                        Task { await activity.resolve(ask, approved: approved) }
                    },
                    onShowAll: onShowAllGates
                )
            }
            agentSection
            recentSection
            Divider().opacity(0.4)
            footer
        }
        .padding(12)
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: entropy.collapsed ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(entropy.collapsed ? Color.shannonError : Color.shannonAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Shannon")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.shannonPrimary)
                Text(headerSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(1)
            }
            Spacer()
            hubStatusBadge
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shannon. \(headerSubtitle). \(hubStatusText)")
    }

    private var headerSubtitle: String {
        if entropy.collapsed {
            return String(format: "Entropy collapse — H %.1f, ΔH %+.1f", entropy.entropy, entropy.deltaH)
        }
        if busy.isEmpty { return "No agents busy" }
        if busy.count == 1, let p = busy.first { return "\(p.displayName) · \(p.status.label)" }
        return "\(busy.count) agents active"
    }

    /// Hub = gate socket + bridge. The socket is what approvals travel over,
    /// so its presence is the honest "can I actually answer gates" signal.
    private var hubConnected: Bool { activity.gateAvailable || bridge.connected }

    private var hubStatusText: String {
        hubConnected ? "Hub connected" : "Hub offline"
    }

    private var hubStatusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(hubConnected ? Color.shannonSuccess : Color.shannonTertiary)
                .frame(width: 6, height: 6)
            Text(hubConnected ? "hub" : "offline")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(hubConnected ? Color.shannonSecondary : Color.shannonTertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.shannonSurfaceElevated))
        .help(hubConnected
              ? "Gate socket reachable — approvals will be delivered"
              : "Gate socket missing — start the hub to answer approvals")
        .accessibilityLabel(hubStatusText)
    }

    // MARK: Agents

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(busy.isEmpty ? "Agents" : "Active now")
            if busy.isEmpty {
                Text("Nothing running. Press ⌘D in Terminal, Claude, or a browser to attach that session as an agent.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.shannonTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(busy.prefix(4)) { agent in
                    agentRow(agent)
                }
            }
        }
    }

    private func agentRow(_ a: AgentActivitySnapshot) -> some View {
        let style = AgentStyleCatalog.style(for: a.id)
        return HStack(spacing: 7) {
            Text(style.emoji).font(.system(size: 12))
            Text(style.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.palette.ink)
            Text(a.status.label)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(style.palette.ink)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(style.palette.wash))
            Spacer(minLength: 4)
            Text(a.relativeAge)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.shannonTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.displayName), \(a.status.label), \(a.relativeAge)")
    }

    // MARK: Recent activity

    /// Last five events, newest first. Source: agent snapshots ordered by their
    /// own updatedAt — the same timestamps the gate/pets write.
    private var recentEvents: [AgentActivitySnapshot] {
        Array(summary.agents.sorted { $0.updatedAt > $1.updatedAt }.prefix(5))
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recentEvents.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("Recent activity")
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recentEvents) { e in
                            eventRow(e)
                        }
                    }
                }
                .frame(maxHeight: 84)
                .accessibilityLabel("Recent activity, last \(recentEvents.count) events")
            }
        }
    }

    private func eventRow(_ e: AgentActivitySnapshot) -> some View {
        let style = AgentStyleCatalog.style(for: e.id)
        let detail = e.lastTask.isEmpty ? e.status.label : e.lastTask
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(e.relativeAge)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Color.shannonTertiary)
                .frame(width: 34, alignment: .trailing)
            Text("\(style.displayName): \(AgentActivitySnapshot.shorten(detail, max: 46))")
                .font(.system(size: 10))
                .foregroundStyle(Color.shannonSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(e.relativeAge) ago, \(style.displayName), \(detail)")
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(Color.shannonTertiary)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(String(format: "H %.2f", entropy.entropy))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(entropy.collapsed ? Color.shannonWarning : Color.shannonTertiary)
                .help(String(format: "Shannon entropy H %.2f bits · ΔH %+.2f · %@",
                             entropy.entropy, entropy.deltaH, entropy.backend))
            if let snap = battery.snapshot {
                Text("\(snap.percentage)%")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.shannonTertiary)
            }
            Spacer()
            footerButton("doc.text", label: "Open hub log", action: onOpenHubLog)
            footerButton("gearshape", label: "Settings", action: onOpenSettings)
            footerButton("power", label: "Quit Shannon", action: onQuit)
        }
    }

    private func footerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.shannonSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - GateInlineCard

/// The newest pending gate approval, answerable without leaving the popover.
/// While the write is in flight the buttons give way to a spinner (no double
/// resolution); a failed write leaves the ask in place with the error inline.
struct GateInlineCard: View {
    let ask: GateDBReader.PendingAsk
    let isResolving: Bool
    let error: String?
    let extraPending: Int
    let onAnswer: (Bool) -> Void
    let onShowAll: () -> Void

    private var style: AgentStyle { AgentStyleCatalog.style(for: ask.agentId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(style.emoji).font(.system(size: 13))
                Text(style.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(style.palette.ink)
                Text("needs approval")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.shannonWarning)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.shannonWarning.opacity(0.18)))
                Spacer(minLength: 0)
            }

            Text(ask.prompt)
                .font(.system(size: 11))
                .foregroundStyle(Color.shannonPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.shannonError)
                    .lineLimit(2)
                    .accessibilityLabel("Approval error: \(error)")
            }

            HStack(spacing: 8) {
                if isResolving {
                    ProgressView().controlSize(.small)
                    Text("Sending to gate…")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.shannonSecondary)
                } else {
                    answerButton("Approve", systemImage: "checkmark", tint: .shannonSuccess) {
                        onAnswer(true)
                    }
                    answerButton("Deny", systemImage: "xmark", tint: .shannonError) {
                        onAnswer(false)
                    }
                }
                Spacer(minLength: 0)
                if extraPending > 0 {
                    Button(action: onShowAll) {
                        Text("+\(extraPending) more")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.shannonAccent)
                    }
                    .buttonStyle(.plain)
                    .help("Show all pending gates")
                    .accessibilityLabel("\(extraPending) more pending gates. Show all.")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.shannonWarning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.shannonWarning.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(style.displayName) needs approval: \(ask.prompt)")
    }

    private func answerButton(
        _ title: String, systemImage: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("\(title) this request")
        .accessibilityLabel("\(title) \(style.displayName)'s request")
    }
}
