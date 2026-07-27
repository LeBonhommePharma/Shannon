import SwiftUI
import PillCore
import ShannonCore

// MARK: - GateInlineCard

/// The newest pending gate approval, answerable without leaving the popover.
/// While the write is in flight the buttons give way to a spinner (no double
/// resolution); a failed write leaves the ask in place with the error inline.
///
/// **UX-013:** Approve/Deny + “needs approval” via `GateAskActionCopy` so the
/// menu-bar popover cannot drift from Mac `GateAskCard` / phone / pad.
///
/// **UX-036:** When the hub gate socket is down, buttons disable and the shared
/// `macGateAffordance` status line is shown — same honesty bar as `GateAskCard`.
struct GateInlineCard: View {
    let ask: GateDBReader.PendingAsk
    let isResolving: Bool
    let error: String?
    /// Whether the gate socket is present. When false, Approve/Deny would fail.
    var gateAvailable: Bool = true
    let extraPending: Int
    let onAnswer: (Bool) -> Void
    let onShowAll: () -> Void

    private var style: AgentStyle { AgentStyleCatalog.style(for: ask.agentId) }

    private var affordance: GateAskActionCopy.Affordance {
        GateAskActionCopy.macGateAffordance(
            gateAvailable: gateAvailable,
            errorText: error
        )
    }

    var body: some View {
        let a = affordance
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(style.emoji).font(.shannonMenuBody)
                Text(style.displayName)
                    .font(.shannonMenuBody)
                    .foregroundStyle(style.palette.ink)
                Text(GateAskActionCopy.needsApproval)
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

            // ENH-031: real change paths/summary from payload only — never invent.
            if let changeBlock = ask.changePathsPresentation.joinedDisplay {
                Text(changeBlock)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        ask.changePathsPresentation.accessibilityLabel
                            ?? "Change paths"
                    )
            }

            if let status = a.statusMessage {
                Text(status)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(
                        error != nil ? Color.shannonError : Color.shannonWarning
                    )
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        error != nil ? "Approval error: \(status)" : status
                    )
            }

            HStack(spacing: 8) {
                if isResolving {
                    ProgressView().controlSize(.small)
                    Text(GateAskActionCopy.sending)
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonSecondary)
                } else {
                    answerButton(
                        a.approveLabel,
                        systemImage: "checkmark",
                        tint: .shannonSuccess,
                        enabled: a.canInteract
                    ) {
                        onAnswer(true)
                    }
                    answerButton(
                        a.denyLabel,
                        systemImage: "xmark",
                        tint: .shannonError,
                        enabled: a.canInteract
                    ) {
                        onAnswer(false)
                    }
                }
                Spacer(minLength: 0)
                if extraPending > 0 {
                    Button(action: onShowAll) {
                        Text("+\(extraPending) more")
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonAccent)
                    }
                    .buttonStyle(.plain)
                    .help("Show all pending gates")
                    .accessibilityLabel("\(extraPending) more pending gates. Show all.")
                }
            }
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.shannonWarning.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.shannonWarning.opacity(0.38), lineWidth: 1)
                }
                .shadow(color: Color.shannonWarning.opacity(0.12), radius: 8, y: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel({
            var label =
                "\(style.displayName) \(GateAskActionCopy.needsApproval): \(ask.prompt)"
            if let changeA11y = ask.changePathsPresentation.accessibilityLabel {
                label += ". \(changeA11y)"
            }
            return label
        }())
    }

    private func answerButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.shannonMenuBody)
                    .symbolRenderingMode(.hierarchical)
                Text(title).font(.shannonMenuBody)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(enabled ? tint : tint.opacity(0.4)))
            .foregroundStyle(.white)
        }
        .buttonStyle(ShannonQuietButtonStyle())
        .disabled(!enabled)
        .help("\(title) this request")
        .accessibilityLabel("\(title) \(style.displayName)'s request")
    }
}
