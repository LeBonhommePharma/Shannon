import SwiftUI
import ShannonCore
import ShannonTheme

/// The iPadOS gate surface: a floating, compact, actionable card rather than a
/// modal.
///
/// Design goals for this redesign:
///   • **Non-blocking / Stage Manager.** It is a top-anchored *overlay* on the
///     hub's own window, never a `sheet` or `alert`. It cannot dim or capture
///     other Stage Manager windows, and interaction with the rest of the hub
///     stays live underneath it.
///   • **Split-screen friendly.** One centred card with a capped width and a
///     single-line question. At 1/3, 1/2 and 2/3 widths it shrinks with the
///     window instead of clipping its buttons.
///   • **Pointer + keyboard.** The card lifts on hover, exposes a right-click
///     context menu, and the ⌘A / ⌘D shortcuts live in the app's command menu.
///   • **Transparency.** When more than one agent is blocked the card shows the
///     backlog count, and every answered question is kept in the sidebar's
///     Gate Activity list so an approve/deny is never invisible.
struct GateCardView: View {
    @ObservedObject var hub: AgentHubViewModel

    @State private var isHovering = false

    private var pending: [PendingConfirmation] { hub.pendingConfirmations }

    var body: some View {
        if let question = pending.first {
            card(for: question)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.shannonFloat, value: question.id)
        }
    }

    private func card(for question: PendingConfirmation) -> some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            HStack(spacing: ShannonSpacing.sm) {
                ShannonStatusDot(state: .warning, diameter: 8)
                Text(hub.agentName(for: question) ?? "Shannon")
                    .shannonText(.shannonHeadline)
                    .lineLimit(1)

                if pending.count > 1 {
                    Text("+\(pending.count - 1) more")
                        .shannonNumeric(color: .shannonTertiary)
                }

                Spacer(minLength: ShannonSpacing.sm)

                // Answers past the deadline are ignored by the Mac, so the
                // window is on screen rather than implied.
                Text(question.expiresAt, style: .timer)
                    .shannonNumeric(color: .shannonTertiary)
                    .monospacedDigit()
            }

            Text(question.question)
                .shannonText(.shannonBody)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: ShannonSpacing.sm) {
                Button {
                    hub.answer(question, approved: true)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(.shannonSuccess)
                .help("Approve — ⌘A")

                Button {
                    hub.answer(question, approved: false)
                } label: {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .tint(.shannonError)
                .help("Deny — ⌘D")
            }
            .font(.shannonCallout)
        }
        .padding(ShannonSpacing.md)
        .frame(maxWidth: 520)
        .background(Color.shannonSurfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.shannonWarning.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isHovering ? 0.28 : 0.18), radius: isHovering ? 20 : 14, y: 6)
        .scaleEffect(isHovering ? 1.01 : 1.0)
        .onHover { hovering in
            withAnimation(.shannonEase) { isHovering = hovering }
        }
        .contextMenu {
            if let agentID = question.agentID {
                Button {
                    hub.select(.agent(agentID))
                } label: {
                    Label("Focus Agent", systemImage: "scope")
                }
            }
            if !question.detail.isEmpty {
                Section("Detail") { Text(question.detail) }
            }
            Divider()
            Button {
                hub.answer(question, approved: true)
            } label: {
                Label("Approve", systemImage: "checkmark")
            }
            Button(role: .destructive) {
                hub.answer(question, approved: false)
            } label: {
                Label("Deny", systemImage: "xmark")
            }
        }
        .padding(.horizontal, ShannonSpacing.md)
        .padding(.top, ShannonSpacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gate request from \(hub.agentName(for: question) ?? "Shannon")")
    }
}

/// The sidebar's collapsible record of what was recently approved or denied.
/// Nothing here is actionable — it exists purely so the gate flow is auditable
/// at a glance without opening the Mac.
struct GateActivitySection: View {
    var events: [GateEvent]

    var body: some View {
        if !events.isEmpty {
            Section("Gate Activity") {
                ForEach(events) { event in
                    HStack(spacing: ShannonSpacing.sm) {
                        Image(systemName: event.approved ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(event.approved ? Color.shannonSuccess : Color.shannonError)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.question)
                                .shannonText(.shannonCaption)
                                .lineLimit(1)
                            Text("\(event.agentName ?? "Shannon") · \(event.approved ? "approved" : "denied")")
                                .shannonNumeric(color: .shannonTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(event.answeredAt, style: .relative)
                            .shannonNumeric(color: .shannonTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
