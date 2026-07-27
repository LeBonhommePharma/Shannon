import SwiftUI
import ShannonCore
import ShannonTheme

// PET E6: `PetRailView` / `PetStore` / pencil hosting exist under Sources but
// are intentionally **not mounted** here. The three-column hub does not inject
// PetStore or place the rail — pad pet chrome is deferred scaffold, not live.
// Do not add a dead toolbar entry that implies the rail is active.

@main
struct ShannonPadApp: App {
    @StateObject private var hub = AgentHubViewModel()
    @StateObject private var voice = VoiceDictationController()

    var body: some Scene {
        WindowGroup {
            AgentHubView(hub: hub, voice: voice)
                .task {
                    hub.start()
                    // Spoken phrases resolve through the same catalogue the
                    // palette uses, so voice and ⌘K can never drift apart.
                    voice.onCommand = { command in
                        PaletteCatalogue.dispatch(command, to: hub)
                    }
                }
        }
        .commands { hubCommands }
    }

    /// Full keyboard vocabulary for the Magic Keyboard. Everything reachable by
    /// touch is reachable here, and the menu titles are what the shortcut sheet
    /// shows when ⌘ is held down.
    @CommandsBuilder
    private var hubCommands: some Commands {
        CommandMenu("Agents") {
            Button("Command Palette") { hub.isPaletteVisible = true }
                .keyboardShortcut("k", modifiers: .command)

            Button("Overview") { hub.select(.overview) }
                .keyboardShortcut("0", modifiers: .command)

            Divider()

            // ⌘1…⌘9 focus by position in the sidebar, which is why the sidebar
            // prints the number next to each row.
            ForEach(1...9, id: \.self) { position in
                Button("Focus Agent \(position)") { hub.focusAgent(at: position - 1) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(position)")),
                        modifiers: .command
                    )
            }
        }

        CommandMenu("Confirmation") {
            // ⌘A / ⌘D act on the oldest pending gate question — the one the
            // floating gate card shows. Kept here as the single owner of these
            // keys so no two visible buttons register the same shortcut.
            // UX-048: disable when empty **or** oldest ask cannot interact
            // (hub offline / expired) — same policy as GateCard / detail.
            Button("Approve Pending") { hub.answerPendingConfirmation(approved: true) }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!hub.canInteractWithOldestPending)

            Button("Deny Pending") { hub.answerPendingConfirmation(approved: false) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!hub.canInteractWithOldestPending)

            Divider()

            Button("Start Dictation") { voice.toggle() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .newItem) {
            Button("Refresh Now") { Task { await hub.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
        }

        CommandMenu("Playback") {
            Button("Play / Pause") { hub.send(.togglePlayPause) }
                .keyboardShortcut(.space, modifiers: .command)
            Button("Next Track") { hub.send(.nextTrack) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Track") { hub.send(.previousTrack) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
    }
}
