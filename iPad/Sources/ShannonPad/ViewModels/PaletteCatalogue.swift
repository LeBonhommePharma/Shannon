import Foundation
import ShannonCore

/// Everything the ⌘K palette can do, assembled from current state.
///
/// This is the single list the palette, the voice commands and the keyboard
/// shortcuts all resolve against — adding an action here makes it available
/// through all three without touching any of them.
@MainActor
enum PaletteCatalogue {
    static func actions(for hub: AgentHubViewModel) -> [PaletteAction] {
        var actions: [PaletteAction] = []

        actions.append(
            PaletteAction(
                id: "overview",
                title: "Overview",
                subtitle: "Full dashboard grid",
                symbol: "square.grid.2x2",
                kind: .command
            ) { hub.select(.overview) }
        )

        for agent in hub.visibleAgents {
            actions.append(
                PaletteAction(
                    id: "agent-\(agent.id)",
                    title: agent.name,
                    subtitle: "\(agent.activity.label) · \(agent.turnCount) turns"
                        + (agent.entropyLabel.map { " · \($0)" } ?? ""),
                    symbol: agent.activity.symbolName,
                    kind: .agent
                ) { hub.select(.agent(agent.id)) }
            )
        }

        for progress in hub.snapshot.docking {
            actions.append(
                PaletteAction(
                    id: "bench-\(progress.id)",
                    title: progress.benchmarkName,
                    subtitle: "\(progress.countLabel) targets",
                    symbol: "atom",
                    kind: .target
                ) { hub.select(.docking(progress.id)) }
            )

            if !progress.currentTarget.isEmpty {
                let target = progress.currentTarget.uppercased()
                actions.append(
                    PaletteAction(
                        id: "target-\(progress.id)-\(target)",
                        title: "Show \(target)",
                        subtitle: "Current target in \(progress.benchmarkName)",
                        symbol: "cube.transparent",
                        kind: .target
                    ) { hub.select(.docking(progress.id)) }
                )
            }
        }

        if let question = hub.pendingConfirmations.first {
            let name = hub.agentName(for: question) ?? "the Mac"
            actions.append(
                PaletteAction(
                    id: "confirm",
                    title: "Confirm",
                    subtitle: "Approve: \(question.question)",
                    symbol: "checkmark.circle",
                    kind: .command
                ) { hub.answerPendingConfirmation(approved: true) }
            )
            actions.append(
                PaletteAction(
                    id: "deny",
                    title: "Deny",
                    subtitle: "Deny \(name): \(question.question)",
                    symbol: "xmark.circle",
                    kind: .command
                ) { hub.answerPendingConfirmation(approved: false) }
            )
        }

        actions.append(
            PaletteAction(
                id: "run-benchmark",
                title: "Run Benchmark",
                subtitle: "Ask the Mac to start the dataset runner",
                symbol: "play.rectangle",
                kind: .command
            ) { hub.requestBenchmarkRun() }
        )

        actions.append(
            PaletteAction(
                id: "refresh",
                title: "Refresh Now",
                subtitle: "Fetch the latest state from iCloud",
                symbol: "arrow.clockwise",
                kind: .command
            ) { Task { await hub.refresh() } }
        )

        return actions
    }

    /// Route a spoken command to the same handler the palette row uses.
    ///
    /// `VoiceCommand` is the cross-platform vocabulary from ShannonCore, so the
    /// iPad answers "confirm" exactly as the Watch does. `.freeform` is where
    /// the iPad adds something the smaller screens cannot use: a fuzzy jump to
    /// any agent or target by name.
    static func dispatch(_ command: VoiceCommand, to hub: AgentHubViewModel) {
        switch command {
        case .confirm:
            hub.answerPendingConfirmation(approved: true, source: .voice)
        case .deny:
            hub.answerPendingConfirmation(approved: false, source: .voice)
        case .status:
            hub.select(.overview)
        case .benchmark:
            if let benchmark = hub.snapshot.docking.first {
                hub.select(.docking(benchmark.id))
            } else {
                hub.post("No benchmark is running.")
            }
        case .nowPlaying:
            hub.select(.overview)
        case .freeform(let text):
            navigate(freeform: text, in: hub)
        }
    }

    /// Best fuzzy match across agents and benchmark targets, or an honest miss.
    private static func navigate(freeform text: String, in hub: AgentHubViewModel) {
        guard !text.isEmpty else { return }
        let query = text
            .replacingOccurrences(of: "show ", with: "")
            .replacingOccurrences(of: "open ", with: "")
            .replacingOccurrences(of: "focus ", with: "")
            .trimmingCharacters(in: .whitespaces)

        var best: (selection: HubSelection, score: Int)?
        func consider(_ selection: HubSelection, _ candidate: String) {
            guard let score = FuzzyMatch.score(candidate, query: query) else { return }
            if best == nil || score > best!.score { best = (selection, score) }
        }

        for agent in hub.visibleAgents {
            consider(.agent(agent.id), agent.name)
        }
        for progress in hub.snapshot.docking {
            consider(.docking(progress.id), progress.benchmarkName)
            if !progress.currentTarget.isEmpty {
                consider(.docking(progress.id), progress.currentTarget)
            }
        }

        if let best {
            hub.select(best.selection)
        } else {
            hub.post("Heard \"\(query)\" — nothing matches.")
        }
    }
}
