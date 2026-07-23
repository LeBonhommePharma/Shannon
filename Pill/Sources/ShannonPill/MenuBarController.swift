import AppKit
import SwiftUI
import PillCore

/// Menu-bar presence for Shannon.
///
/// Left-click opens a SwiftUI popover (agent summary, inline gate approval,
/// recent activity, hub status). Right-click or ⌥-click opens the utility
/// menu. The icon itself is a state machine:
///
///   idle          → template `waveform.path.ecg` (auto light/dark)
///   agents active → template waveform + busy count
///   gate pending  → amber `questionmark.bubble.fill`, pulsing
///   collapse      → red `exclamationmark.triangle.fill`
@MainActor
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private let bridge: ShannonBridge
    private let idle: IdleTelemetryPublisher
    private let battery: BatteryMonitor
    private let ingest: AgentIngestService
    private let activity: AgentActivityMonitor
    private var timer: Timer?
    private var pulseTimer: Timer?
    private var pulsePhase = false
    private var popover: NSPopover?
    /// Sticky success flash from ⌘D capture; suppresses normal refresh briefly.
    private var flashUntil: Date?

    var onShowPill: (() -> Void)?
    var onReposition: (() -> Void)?
    var onAddAgent: (() -> Void)?

    init(
        bridge: ShannonBridge,
        idle: IdleTelemetryPublisher,
        battery: BatteryMonitor,
        ingest: AgentIngestService,
        activity: AgentActivityMonitor
    ) {
        self.bridge = bridge
        self.idle = idle
        self.battery = battery
        self.ingest = ingest
        self.activity = activity
    }

    func start() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.isVisible = true
        if let button = status.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Shannon agents — click for status, right-click for menu, ⌘D captures the front app"
            button.setAccessibilityLabel("Shannon agent hub")
        }
        item = status
        refresh()

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        stopPulse()
        popover?.performClose(nil); popover = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    func flashSuccess(_ text: String) {
        guard let button = item?.button else { return }
        button.image = Self.symbolImage("checkmark.circle.fill", template: false)
        button.title = " " + text
        button.contentTintColor = .systemGreen
        flashUntil = Date().addingTimeInterval(1.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Icon state machine

    private func refresh() {
        guard let button = item?.button else { return }
        if let until = flashUntil, until > Date() { return }
        flashUntil = nil

        let summary = activity.summary
        let entropy = bridge.status ?? idle.status
        let pendingCount = activity.pendingAsks.count

        if pendingCount > 0 {
            // Gate pending trumps everything — this is the state that needs LP.
            button.image = Self.symbolImage("questionmark.bubble.fill", template: false)
            button.title = pendingCount > 1 ? " \(pendingCount)" : ""
            button.contentTintColor = .systemOrange
            button.setAccessibilityLabel(
                "Shannon: \(pendingCount) gate approval\(pendingCount > 1 ? "s" : "") pending")
            startPulse()
            return
        }
        stopPulse()

        if entropy.collapsed {
            button.image = Self.symbolImage("exclamationmark.triangle.fill", template: false)
            button.title = String(format: " H %.1f", entropy.entropy)
            button.contentTintColor = .systemRed
            button.setAccessibilityLabel(
                String(format: "Shannon: entropy collapse, H %.1f bits", entropy.entropy))
        } else if !summary.busy.isEmpty {
            // Template image: the system inverts it for dark mode / selection.
            button.image = Self.symbolImage("waveform.path.ecg", template: true)
            button.title = summary.busy.count > 1 ? " \(summary.busy.count)" : ""
            button.contentTintColor = nil
            let names = summary.busy.prefix(3).map(\.displayName).joined(separator: ", ")
            button.setAccessibilityLabel("Shannon: \(summary.busy.count) agents active — \(names)")
        } else {
            button.image = Self.symbolImage("waveform.path.ecg", template: true)
            button.title = ""
            button.contentTintColor = nil
            button.setAccessibilityLabel(
                bridge.connected ? "Shannon: hub connected, idle" : "Shannon: idle")
        }
    }

    /// Subtle attention pulse while a gate waits: the tint breathes between
    /// full and dimmed amber. Runs only in the pending state — no idle CPU.
    private func startPulse() {
        guard pulseTimer == nil else { return }
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.item?.button else { return }
                self.pulsePhase.toggle()
                button.contentTintColor = self.pulsePhase
                    ? NSColor.systemOrange.withAlphaComponent(0.45)
                    : .systemOrange
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pulseTimer = t
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulsePhase = false
    }

    // MARK: - Click routing

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.option) == true
        if wantsMenu {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: - Popover

    private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item?.button else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                activity: activity,
                bridge: bridge,
                idle: idle,
                battery: battery,
                onShowAllGates: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.onShowPill?()
                },
                onOpenHubLog: { [weak self] in
                    self?.popover?.performClose(nil)
                    Self.openHubLog()
                },
                onOpenSettings: { [weak self] in
                    self?.popover?.performClose(nil)
                    Self.openSettings()
                },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        popover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Keyboard access: focus the popover so Tab walks its controls.
        pop.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Context menu (right-click / ⌥-click)

    private func showContextMenu() {
        guard let item else { return }
        let menu = buildContextMenu()
        // Attach transiently: assigning `menu` and clicking shows it at the
        // status item; detach right after so left-click keeps the popover.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let gates = NSMenuItem(title: "Show All Gates", action: #selector(showAllGates), keyEquivalent: "g")
        gates.target = self
        menu.addItem(gates)

        let pause = NSMenuItem(
            title: activity.isPaused ? "Resume Agents" : "Pause Agents",
            action: #selector(togglePause), keyEquivalent: "p"
        )
        pause.target = self
        pause.toolTip = "Pause Shannon's monitoring of agent state (agents themselves keep running)"
        menu.addItem(pause)

        let log = NSMenuItem(title: "Open Hub Log", action: #selector(openLog), keyEquivalent: "l")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        let add = NSMenuItem(title: "Add Agent from Front App", action: #selector(addAgent), keyEquivalent: "d")
        add.keyEquivalentModifierMask = [.command]
        add.target = self
        menu.addItem(add)

        let show = NSMenuItem(title: "Show Notch Pill", action: #selector(showPill), keyEquivalent: "s")
        show.target = self
        menu.addItem(show)

        let repo = NSMenuItem(title: "Reposition on Screen", action: #selector(reposition), keyEquivalent: "r")
        repo.target = self
        menu.addItem(repo)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Shannon", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func showAllGates() { onShowPill?() }
    @objc private func togglePause() { activity.isPaused.toggle() }
    @objc private func openLog() { Self.openHubLog() }
    @objc private func showPill() { onShowPill?() }
    @objc private func addAgent() { onAddAgent?() }
    @objc private func reposition() { onReposition?() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Destinations

    private static func openHubLog() {
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Shannon/pill.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            NSWorkspace.shared.open(log.deletingLastPathComponent())
        }
    }

    /// Shannon's configuration lives on disk under ~/.shannon (pets, registry,
    /// hub DB) — "Settings" opens that folder until a preferences window exists.
    private static func openSettings() {
        NSWorkspace.shared.open(PetBootstrap.shannonHome)
    }

    private static func symbolImage(_ name: String, template: Bool) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Shannon")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = template
        return img
    }
}
