import SwiftUI
import PillCore
import AppKit

// MARK: - GateAskCard

/// The approval the gate is blocked on, answerable straight from the notch.
///
/// Data source: one `agent_interactions` row with status = 'pending'. Approving
/// or denying writes back over the gate socket via `GateApprovalClient`, using
/// the row's own `interaction_id` — the gate matches on that id and will not
/// clear the row for anything else.
struct GateAskCard: View {
    let ask: GateDBReader.PendingAsk
    /// True while this ask's approval is being written to the gate — buttons are
    /// swapped for a spinner so a second tap can't fire a duplicate resolution.
    var isResolving: Bool = false
    /// Last resolve failure, shown inline so a dead gate is never mistaken for a
    /// successful answer.
    var errorText: String? = nil
    /// Whether the gate socket is present. When false, the buttons would fail, so
    /// we say so up front instead of letting the tap error out.
    var gateAvailable: Bool = true
    let onAnswer: (Bool) -> Void

    private var style: AgentStyle { AgentStyleCatalog.style(for: ask.agentId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(style.emoji).font(.shannonMenuBody)
                Text(style.displayName)
                    .font(.shannonMenuBody)
                    .foregroundStyle(style.palette.ink)
                Text("needs approval")
                    .font(.shannonMenuSection)
                    .foregroundStyle(Color.shannonWarning)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.shannonWarning.opacity(0.18)))
                Spacer(minLength: 0)
            }

            Text(ask.prompt)
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let errorText {
                Text(errorText)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonError)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !gateAvailable {
                Text("Hub offline — start the gate to approve from here")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonWarning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending…")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonSecondary)
                    Spacer(minLength: 0)
                } else {
                    answerButton("Approve", systemImage: "checkmark", tint: .shannonSuccess) {
                        onAnswer(true)
                    }
                    answerButton("Deny", systemImage: "xmark", tint: .shannonError) {
                        onAnswer(false)
                    }
                    Spacer(minLength: 0)
                    Text("right-click for more")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerButton(
        _ title: String, systemImage: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.shannonMenuBody)
                Text(title).font(.shannonPillLabel)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(gateAvailable ? tint : tint.opacity(0.4)))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!gateAvailable)
        .help("\(title) this request — sends interaction_id \(ask.interactionId) to the gate")
        .onHover { h in
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
