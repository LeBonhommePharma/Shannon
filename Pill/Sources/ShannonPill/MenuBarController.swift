import AppKit
import PillCore

@MainActor
final class MenuBarController {
    private var item: NSStatusItem?
    private let bridge: ShannonBridge
    private let idle: IdleTelemetryPublisher
    private let battery: BatteryMonitor
    private let ingest: AgentIngestService
    private let activity: AgentActivityMonitor
    private var timer: Timer?

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
            button.image = Self.symbolImage("waveform.path.ecg")
            button.imagePosition = .imageLeading
            button.toolTip = "Shannon agents — ⌘D capture frontmost app"
        }
        status.menu = buildMenu()
        item = status
        refresh()

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    func flashSuccess(_ text: String) {
        guard let button = item?.button else { return }
        button.title = " " + text
        button.contentTintColor = NSColor.systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let button = item?.button else { return }
        let summary = activity.summary
        let entropy = bridge.status ?? idle.status

        if ingest.isHighlighting, let last = ingest.lastResult {
            button.title = " +\(last.agent.id)"
            button.contentTintColor = NSColor.systemGreen
        } else if !summary.busy.isEmpty {
            let head = summary.busy[0]
            let extra = summary.busy.count > 1 ? " +\(summary.busy.count - 1)" : ""
            button.title = " \(head.displayName)\(extra)"
            button.contentTintColor = NSColor.systemGreen
        } else if entropy.collapsed {
            button.title = String(format: " H %.1f!", entropy.entropy)
            button.contentTintColor = NSColor.systemOrange
        } else if bridge.connected {
            button.title = String(format: " ● H %.1f", entropy.entropy)
            button.contentTintColor = NSColor.systemGreen
        } else {
            button.title = " ○ ready"
            button.contentTintColor = nil
        }
        item?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let summary = activity.summary
        let entropy = bridge.status ?? idle.status

        let header = NSMenuItem(
            title: summary.busy.isEmpty
                ? (bridge.connected ? "Bridge live · no busy agents" : "Ready · no busy agents")
                : "\(summary.busyCount) agent(s) active",
            action: nil, keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        for agent in summary.busy.prefix(6) {
            let task = AgentActivitySnapshot.shorten(agent.lastTask, max: 40)
            let title = task.isEmpty
                ? "  \(agent.displayName) · \(agent.status.label)"
                : "  \(agent.displayName) · \(task)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if bridge.connected || entropy.collapsed {
            let h = NSMenuItem(
                title: String(format: "H %.2f  ΔH %+.2f · %@", entropy.entropy, entropy.deltaH, entropy.backend),
                action: nil, keyEquivalent: ""
            )
            h.isEnabled = false
            menu.addItem(h)
        }

        menu.addItem(.separator())

        let add = NSMenuItem(
            title: "Add Agent from Front App",
            action: #selector(addAgent),
            keyEquivalent: "d"
        )
        add.keyEquivalentModifierMask = [.command]
        add.target = self
        add.toolTip = "Capture Terminal / Claude / ChatGPT / Codex / browser as an agent (⌘D)"
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

    @objc private func showPill() { onShowPill?() }
    @objc private func addAgent() { onAddAgent?() }
    @objc private func reposition() { onReposition?() }
    @objc private func quit() { NSApp.terminate(nil) }

    private static func symbolImage(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: "Shannon")?
            .withSymbolConfiguration(cfg)
    }
}
