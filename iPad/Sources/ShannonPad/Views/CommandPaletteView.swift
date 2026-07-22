import SwiftUI
import ShannonCore
import ShannonTheme

/// One row in the palette.
struct PaletteAction: Identifiable {
    enum Kind {
        case agent, target, command
    }

    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    var kind: Kind
    var perform: () -> Void
}

/// Subsequence match with a score, the same rule Linear and Notion use: the
/// query characters must appear in order, and matches that land on word
/// starts or run consecutively rank higher.
enum FuzzyMatch {
    static func score(_ candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let haystack = Array(candidate.lowercased())
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }

        var score = 0
        var haystackIndex = 0
        var lastMatch = -2

        for character in needle {
            var found = false
            while haystackIndex < haystack.count {
                defer { haystackIndex += 1 }
                guard haystack[haystackIndex] == character else { continue }
                score += 1
                if haystackIndex == lastMatch + 1 { score += 3 }
                if haystackIndex == 0 || haystack[haystackIndex - 1] == " " { score += 2 }
                lastMatch = haystackIndex
                found = true
                break
            }
            guard found else { return nil }
        }
        // Shorter candidates win ties: "1G9V" should beat "Show 1G9V details".
        return score * 10 - candidate.count
    }
}

/// ⌘K. A floating sheet over whatever the hub is showing.
///
/// The palette is the keyboard's equivalent of the voice commands and the
/// context menus — the same actions, reachable without lifting a hand off the
/// Magic Keyboard.
struct CommandPaletteView: View {
    var actions: [PaletteAction]
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    private var results: [PaletteAction] {
        guard !query.isEmpty else { return actions }
        return actions
            .compactMap { action -> (PaletteAction, Int)? in
                let haystack = "\(action.title) \(action.subtitle)"
                guard let score = FuzzyMatch.score(haystack, query: query) else { return nil }
                return (action, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            list
        }
        .frame(maxWidth: 640)
        .background(Color.shannonSurface)
        .clipShape(RoundedRectangle(cornerRadius: ShannonRadius.xl, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .padding(ShannonSpacing.xl)
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { _ in highlighted = 0 }
    }

    private var field: some View {
        HStack(spacing: ShannonSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.shannonTertiary)

            TextField("Search agents and actions", text: $query)
                .textFieldStyle(.plain)
                .font(.shannonTitle)
                .focused($isFieldFocused)
                .submitLabel(.go)
                .onSubmit(runHighlighted)

            Button("Esc", action: onDismiss)
                .font(.shannonCaption)
                .foregroundStyle(Color.shannonTertiary)
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(ShannonSpacing.md)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if results.isEmpty {
                        Text("No matches")
                            .shannonText(.shannonBody, color: .shannonTertiary)
                            .padding(ShannonSpacing.lg)
                    }

                    ForEach(Array(results.enumerated()), id: \.element.id) { index, action in
                        row(action, isHighlighted: index == highlighted)
                            .id(action.id)
                            .onTapGesture {
                                action.perform()
                                onDismiss()
                            }
                    }
                }
            }
            .frame(maxHeight: 360)
            .onChange(of: highlighted) { new in
                guard results.indices.contains(new) else { return }
                withAnimation(.shannonSnap) { proxy.scrollTo(results[new].id) }
            }
            .background(arrowKeyShortcuts)
        }
    }

    private func row(_ action: PaletteAction, isHighlighted: Bool) -> some View {
        HStack(spacing: ShannonSpacing.md) {
            Image(systemName: action.symbol)
                .frame(width: 22)
                .foregroundStyle(tint(for: action.kind))

            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .shannonText(.shannonCallout)
                Text(action.subtitle)
                    .shannonText(.shannonCaption, color: .shannonSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if isHighlighted {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(Color.shannonTertiary)
            }
        }
        .padding(.horizontal, ShannonSpacing.md)
        .padding(.vertical, ShannonSpacing.sm)
        .background(isHighlighted ? Color.shannonAccentSubtle : Color.clear)
        .contentShape(Rectangle())
    }

    /// Invisible buttons carrying the arrow shortcuts. A `TextField` keeps
    /// first responder while the palette is open, so up/down have to be bound
    /// as commands rather than read as key presses.
    private var arrowKeyShortcuts: some View {
        VStack {
            Button("") { move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), results.count - 1)
    }

    private func runHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        results[highlighted].perform()
        onDismiss()
    }

    private func tint(for kind: PaletteAction.Kind) -> Color {
        switch kind {
        case .agent:   return .shannonAccent
        case .target:  return .shannonSuccess
        case .command: return .shannonSecondary
        }
    }
}

/// A dimmed backdrop that dismisses on tap. `presentationBackground` is
/// iOS 16.4, so the palette is presented as a full-screen transparent overlay
/// rather than a sheet — that also keeps the ⌘ shortcuts alive underneath.
struct PaletteBackdrop<Content: View>: View {
    var onDismiss: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            content
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}
