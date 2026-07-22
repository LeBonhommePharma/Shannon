import SwiftUI
import ShannonCore
import ShannonTheme

/// The right rail: what needs an answer, then what happened.
///
/// Pending confirmations sit above the feed and never scroll out of reach —
/// a blocked agent is the one thing in the hub that is waiting on the human,
/// so it gets the top of the column and full-size buttons.
struct NotificationPanelView: View {
    var pending: [PendingConfirmation]
    var agentName: (PendingConfirmation) -> String?
    var notifications: [NotificationMirror]
    var isImportant: (String) -> Bool

    var onConfirm: (PendingConfirmation) -> Void
    var onDeny: (PendingConfirmation) -> Void
    var onDismissNotification: (String) -> Void
    var onMarkImportant: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ShannonSpacing.md) {
                if !pending.isEmpty {
                    sectionHeader("Needs You", count: pending.count, tint: .shannonWarning)
                    ForEach(pending) { question in
                        ConfirmationRow(
                            confirmation: question,
                            agentName: agentName(question),
                            onConfirm: { onConfirm(question) },
                            onDeny: { onDeny(question) }
                        )
                    }
                }

                sectionHeader("Activity", count: notifications.count, tint: .shannonSecondary)

                if notifications.isEmpty {
                    Text("Nothing from the Mac yet.")
                        .shannonText(.shannonCaption, color: .shannonTertiary)
                        .padding(.vertical, ShannonSpacing.md)
                }

                ForEach(notifications) { note in
                    NotificationRow(
                        note: note,
                        isImportant: isImportant(note.id),
                        onDismiss: { onDismissNotification(note.id) },
                        onMarkImportant: { onMarkImportant(note.id) }
                    )
                }
            }
            .padding(ShannonSpacing.md)
        }
        .background(Color.shannonBackground)
    }

    private func sectionHeader(_ title: String, count: Int, tint: Color) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.shannonCaption)
                .tracking(0.8)
                .foregroundStyle(tint)
            Spacer()
            Text("\(count)")
                .shannonNumeric(color: .shannonTertiary)
        }
        .padding(.top, ShannonSpacing.xs)
    }
}

/// A blocked agent's question, with the two answers as targets big enough to
/// hit without looking.
private struct ConfirmationRow: View {
    var confirmation: PendingConfirmation
    var agentName: String?
    var onConfirm: () -> Void
    var onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            HStack(spacing: ShannonSpacing.sm) {
                ShannonStatusDot(state: .warning, diameter: 8)
                Text(agentName ?? "Shannon")
                    .shannonText(.shannonHeadline)
                    .lineLimit(1)
                Spacer()
                // Answers are ignored by the Mac once the prompt expires, so
                // the deadline is on screen rather than implied.
                Text(confirmation.expiresAt, style: .timer)
                    .shannonNumeric(color: .shannonTertiary)
            }

            Text(confirmation.question)
                .shannonText(.shannonBody)
                .lineLimit(3)

            if !confirmation.detail.isEmpty {
                Text(confirmation.detail)
                    .shannonText(.shannonCaption, color: .shannonSecondary)
                    .lineLimit(4)
            }

            HStack(spacing: ShannonSpacing.sm) {
                Button(action: onConfirm) {
                    Label("Confirm", systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.shannonSuccess)

                Button(action: onDeny) {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.shannonError)
            }
            .font(.shannonCallout)
        }
        .shannonCard(isHighlighted: true)
    }
}

/// Swipe right to dismiss, swipe left to pin as important.
///
/// `swipeActions` needs a `List`, and the feed is a `LazyVStack` so the pending
/// section can sit above it without becoming a list section — so the gesture is
/// implemented directly, with the row snapping back on release.
private struct NotificationRow: View {
    var note: NotificationMirror
    var isImportant: Bool
    var onDismiss: () -> Void
    var onMarkImportant: () -> Void

    @State private var offset: CGFloat = 0

    private let actionThreshold: CGFloat = 88

    var body: some View {
        ZStack {
            swipeBackdrop

            VStack(alignment: .leading, spacing: ShannonSpacing.xs) {
                HStack(spacing: ShannonSpacing.sm) {
                    if isImportant {
                        Circle()
                            .fill(Color.shannonWarning)
                            .frame(width: 6, height: 6)
                    }
                    Text(note.sender)
                        .shannonText(.shannonCaption, color: .shannonAccent)
                    Spacer()
                    Text(note.postedAt, style: .relative)
                        .shannonNumeric(color: .shannonTertiary)
                }

                Text(note.title)
                    .shannonText(.shannonCallout)
                    .lineLimit(2)

                if !note.body.isEmpty {
                    Text(note.body)
                        .shannonText(.shannonCaption, color: .shannonSecondary)
                        .lineLimit(3)
                }
            }
            .shannonCard()
            .offset(x: offset)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        offset = value.translation.width
                    }
                    .onEnded { value in
                        let travel = value.translation.width
                        withAnimation(.shannonSnap) { offset = 0 }
                        if travel > actionThreshold {
                            onDismiss()
                        } else if travel < -actionThreshold {
                            onMarkImportant()
                        }
                    }
            )
        }
        .contextMenu {
            Button(action: onMarkImportant) {
                Label(isImportant ? "Keep Important" : "Mark Important", systemImage: "star")
            }
            Button(role: .destructive, action: onDismiss) {
                Label("Dismiss", systemImage: "xmark")
            }
        }
    }

    /// Reveals which action the current travel would commit to.
    private var swipeBackdrop: some View {
        HStack {
            Label("Dismiss", systemImage: "xmark.circle.fill")
                .foregroundStyle(Color.shannonSecondary)
                .opacity(offset > 24 ? 1 : 0)
            Spacer()
            Label("Important", systemImage: "star.fill")
                .foregroundStyle(Color.shannonWarning)
                .opacity(offset < -24 ? 1 : 0)
        }
        .font(.shannonCaption)
        .labelStyle(.iconOnly)
        .padding(.horizontal, ShannonSpacing.md)
    }
}
