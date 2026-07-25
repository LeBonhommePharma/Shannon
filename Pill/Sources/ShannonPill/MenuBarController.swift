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
    private let battery: BatteryMonitor
    private let ingest: AgentIngestService
    private let activity: AgentActivityMonitor
    private let resources: SystemResourceMonitor
    private let amphetamine: AmphetamineMonitor
    private let focusMode: FocusModeMonitor
    /// Honest multi-device backend label from CloudPublisher.
    private let multiDeviceStatus: String
    private var timer: Timer?
    private var pulseTimer: Timer?
    private var pulsePhase = false
    private var popover: NSPopover?
    /// Sticky success flash from ⌘D capture; suppresses normal refresh briefly.
    private var flashUntil: Date?
    /// Last rendered icon state. The timer fires every second; redrawing an
    /// NSStatusItem that has not changed is pure waste (and makes the tint
    /// flicker under the pulse animation).
    private var lastRendered: String?

    var onShowPill: (() -> Void)?
    var onReposition: (() -> Void)?
    var onAddAgent: (() -> Void)?

    init(
        bridge: ShannonBridge,
        battery: BatteryMonitor,
        ingest: AgentIngestService,
        activity: AgentActivityMonitor,
        resources: SystemResourceMonitor,
        amphetamine: AmphetamineMonitor,
        focusMode: FocusModeMonitor,
        multiDeviceStatus: String = "in-memory"
    ) {
        self.bridge = bridge
        self.battery = battery
        self.ingest = ingest
        self.activity = activity
        self.resources = resources
        self.amphetamine = amphetamine
        self.focusMode = focusMode
        self.multiDeviceStatus = multiDeviceStatus
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
        // First-run discoverability: brief title flash (LSUIElement has no Dock).
        if FirstRunCoach.shouldShow(), let button = status.button {
            button.title = " Shannon · click me"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.lastRendered = nil
                self?.refresh()
            }
        }
        refresh()

        // Backup timer for agent/ask state; resource glyph also paints on sample publish.
        let t = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Called from `SystemResourceMonitor.onSnapshotPublished` for sample-aligned glyph.
    func refreshFromResources() {
        refresh()
    }

    /// Open the status popover once for first-run coaching (auto-surface).
    func presentFirstRunPopover() {
        guard FirstRunCoach.shouldShow() else { return }
        guard let button = item?.button else { return }
        if popover?.isShown == true { return }
        togglePopover()
        // Re-assert after open so coach is visible.
        _ = button
    }

    func stop() {
        timer?.invalidate(); timer = nil
        stopPulse()
        popover?.performClose(nil); popover = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    func flashSuccess(_ text: String) {
        flash(text, symbol: "checkmark.circle.fill", tint: .systemGreen)
    }

    /// Something was deliberately *not* done (⌘D on a system service). A green
    /// checkmark here would claim a capture that never happened.
    func flashNotice(_ text: String) {
        flash(text, symbol: "nosign", tint: .secondaryLabelColor)
    }

    private func flash(_ text: String, symbol: String, tint: NSColor) {
        guard let button = item?.button else { return }
        button.image = Self.symbolImage(symbol, template: false)
        button.title = " " + text
        button.contentTintColor = tint
        flashUntil = Date().addingTimeInterval(1.8)
        lastRendered = nil   // force a real redraw once the flash expires
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Icon state machine

    private func refresh() {
        // Amphetamine keep-awake must track agent busy even when the popover is
        // closed (popover is only created on click — onChange there never fires).
        amphetamine.syncWithAgents(busyCount: activity.summary.busyCount)

        guard let button = item?.button else { return }
        if let until = flashUntil, until > Date() { return }
        flashUntil = nil

        let summary = activity.summary
        // Provenance-bearing reading, not `bridge.status ?? idle.status`. The
        // idle publisher has no number to fall back to any more, and a collapse
        // is only ever raised from something that measured one.
        let reading = EntropyProvenance.resolve(
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status,
            gate: activity.agentEntropy,
            gateDBAvailable: activity.gateDBAvailable
        )
        let collapse: EntropyMeasurement? = reading.collapsed == true ? reading.measurement : nil
        // Only asks somebody is actually waiting on. `activity.staleAsks` holds
        // rows whose agent disconnected after asking — pulsing amber forever for
        // an approval nobody will ever read is the definition of a false alarm.
        let pendingCount = activity.pendingAsks.count

        // Host gauges — used for glyph + title when not in alarm.
        let snap = resources.snapshot
        let constrained = snap.mostConstrained
        // Finer signature (1%/5%/10% by core count) + peak index — sample-aligned.
        let coresKey = SystemResourceLogic.coresSignatureKey(
            cores: snap.cpuCores,
            aggregate: snap.cpuPercent
        )
        let constrainedKey = constrained.map { "\($0.kind.rawValue):\($0.percent.rounded())" } ?? "-"

        // Cheap signature of everything the icon depends on; bail when unchanged.
        let signature = [
            "p\(pendingCount)",
            collapse.map { String(format: "c%.1f", $0.bits) } ?? "-",
            "b\(summary.busyCount)",
            summary.busy.first?.displayName ?? "",
            "l\(summary.connected.count)",
            bridge.connected ? "1" : "0",
            constrainedKey,
            coresKey,
        ].joined(separator: "|")
        guard signature != lastRendered else { return }
        lastRendered = signature

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

        if let collapse {
            button.image = Self.symbolImage("exclamationmark.triangle.fill", template: false)
            button.title = String(format: " H %.1f", collapse.bits)
            button.contentTintColor = .systemRed
            button.setAccessibilityLabel(
                String(format: "Shannon: entropy collapse, H %.1f bits (source: %@)",
                       collapse.bits, collapse.source.label))
        } else if !summary.busy.isEmpty {
            // Agents busy: still show live per-core glyph so load is visible.
            button.image = SystemResourceGlyph.image(
                cores: snap.cpuCores,
                aggregate: snap.cpuPercent,
                template: false
            )
            if summary.busy.count > 1 {
                button.title = " \(summary.busy.count)"
            } else if let c = constrained, c.percent >= 80 {
                button.title = " \(c.shortLabel)"
            } else if let cpu = snap.cpuPercent {
                button.title = String(format: " %.0f%%", cpu)
            } else {
                button.title = ""
            }
            button.contentTintColor = nil
            let names = summary.busy.prefix(3).map(\.displayName).joined(separator: ", ")
            button.setAccessibilityLabel("Shannon: \(summary.busy.count) agents active — \(names)")
        } else {
            // Quiet: iStat-style per-core bars; glyph-first when calm.
            button.image = SystemResourceGlyph.image(
                cores: snap.cpuCores,
                aggregate: snap.cpuPercent,
                template: false
            )
            let title = SystemResourceLogic.calmStatusTitle(
                constrained: constrained,
                hottest: snap.hottestCore,
                imbalance: snap.coreImbalance
            )
            button.title = title
            // Load stress uses yellow/red — not ask-orange (amber reserved for gates).
            if let c = constrained, c.percent >= 92 {
                button.contentTintColor = .systemRed
            } else if let c = constrained, c.percent >= 80 {
                button.contentTintColor = .systemYellow
            } else {
                button.contentTintColor = nil
            }
            let connected = summary.connected.count
            var label: String
            if connected > 0 {
                label = "Shannon: \(connected) agent\(connected > 1 ? "s" : "") connected, idle"
            } else if bridge.connected {
                label = "Shannon: hub connected, no agents"
            } else {
                label = "Shannon: no agents connected"
            }
            if let c = constrained {
                label += String(format: ". %@ %.0f percent", c.kind.shortLabel, c.percent)
            }
            if let hot = snap.hottestCore, snap.cpuCoreCount > 1 {
                label += String(format: ". peak core %d at %.0f percent", hot.index, hot.percent)
            }
            button.setAccessibilityLabel(label)
            button.toolTip = Self.resourceTooltip(snap: snap, agents: summary)
        }
    }

    private static func resourceTooltip(snap: SystemResourceSnapshot, agents: AgentActivitySummary) -> String {
        var lines: [String] = ["Shannon resources"]
        if let cpu = snap.cpuPercent {
            lines.append(String(format: "CPU %.0f%% (%d cores)", cpu, snap.cpuCoreCount))
        }
        if let hot = snap.hottestCore {
            lines.append(String(format: "Hottest: C%d %.0f%% (%+.0f vs avg)",
                                hot.index, hot.percent, hot.deltaVsAverage))
        }
        if let g = snap.gpuPercent {
            lines.append(String(format: "GPU %.0f%%", g))
        }
        if let r = snap.ramPercent {
            lines.append(String(format: "RAM %.0f%%", r))
        }
        if agents.busyCount > 0 {
            lines.append("\(agents.busyCount) agent(s) active")
        }
        return lines.joined(separator: "\n")
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
        // Liquid Glass: keep system open animation; appearance locked dark so
        // the popover material composites like Control Center, not a light sheet.
        pop.animates = true
        pop.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(
            rootView: MenuBarPopoverView(
                activity: activity,
                bridge: bridge,
                battery: battery,
                resources: resources,
                amphetamine: amphetamine,
                focusMode: focusMode,
                multiDeviceStatus: multiDeviceStatus,
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
        // Intrinsic size so the popover hugs content (no tall empty chrome).
        host.sizingOptions = [.intrinsicContentSize]
        pop.contentViewController = host
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
