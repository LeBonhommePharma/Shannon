import AppKit
import SwiftUI
import PillCore
import ShannonCore
import ShannonTheme

/// Menu-bar presence for Shannon.
///
/// **Ship path:** this is the only menu-bar HUD launched by `./scripts/shannon`
/// / Homebrew (`ShannonPill`). Do **not** also run `hub/AgentHubApp.swift` —
/// that is a legacy dual status-item. Live gate code is only under `hub/`.
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
    private let keepAwake: KeepAwakeMonitor
    private let focusMode: FocusModeMonitor
    /// Honest multi-device backend label from CloudPublisher (full operator line).
    /// Re-read on every popover open and pushed into ``multiDeviceStatusModel``.
    private let multiDeviceStatusProvider: () -> String
    /// Live model observed by the popover footer (never a one-shot String).
    private let multiDeviceStatusModel: MultiDeviceStatusModel
    /// AgentPeek-parity surfaces (pulled sessions, dev servers, routes).
    private let parity = ParityPanelModel()
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
    /// Re-sync ask pulse when the user toggles Reduce Motion mid-session.
    private var accessibilityObserver: NSObjectProtocol?

    var onShowPill: (() -> Void)?
    /// Toggle hide/show of the floating desktop pet + chat bubble (persisted).
    var onToggleDesktopCompanion: (() -> Void)?
    /// Current desktop companion preference (for menu checkmark). Defaults to pure store.
    var isDesktopCompanionVisible: (() -> Bool)?
    var onReposition: (() -> Void)?
    var onAddAgent: (() -> Void)?
    /// Opens the real Settings window (not only Finder on ~/.shannon).
    var onOpenSettings: (() -> Void)?

    init(
        bridge: ShannonBridge,
        battery: BatteryMonitor,
        ingest: AgentIngestService,
        activity: AgentActivityMonitor,
        resources: SystemResourceMonitor,
        keepAwake: KeepAwakeMonitor,
        focusMode: FocusModeMonitor,
        multiDeviceStatus: String = "Multi-device: in-memory",
        multiDeviceStatusProvider: (() -> String)? = nil,
        multiDeviceStatusModel: MultiDeviceStatusModel? = nil
    ) {
        self.bridge = bridge
        self.battery = battery
        self.ingest = ingest
        self.activity = activity
        self.resources = resources
        self.keepAwake = keepAwake
        self.focusMode = focusMode
        // Prefer live provider so iCloud sign-out updates the footer without relaunch.
        let provider = multiDeviceStatusProvider ?? { multiDeviceStatus }
        self.multiDeviceStatusProvider = provider
        let model = multiDeviceStatusModel ?? MultiDeviceStatusModel(line: provider())
        model.update(provider())
        self.multiDeviceStatusModel = model
    }

    /// Push the latest operator line into the observed model (popover open + tests).
    func refreshMultiDeviceStatus() {
        multiDeviceStatusModel.update(multiDeviceStatusProvider())
    }

    func start() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.isVisible = true
        if let button = status.button {
            // Status item is in the *system* menu bar — not our darkAqua app chrome.
            // Aqua appearance + absolute title ink keeps text readable on light glass.
            button.appearance = NSAppearance(named: .aqua)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Shannon agents — click for status, right-click for menu, ⌘D captures the front app"
            button.setAccessibilityLabel("Shannon agent hub")
        }
        item = status
        // First-run discoverability: brief title flash (LSUIElement has no Dock).
        if FirstRunCoach.shouldShow(), let button = status.button {
            Self.applyStatusTitle(button, text: " Shannon · click me", role: .calm)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.lastRendered = nil
                self?.refresh()
            }
        }
        refresh()

        // Backup timer for agent/ask state; resource glyph also paints on sample publish.
        let t = Timer(timeInterval: UICadence.menuBarBackupInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = min(0.12, UICadence.menuBarBackupInterval * 0.35)
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Accessibility: Reduce Motion must stop the forever ask pulse without a relaunch.
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Force a re-render so solid vs pulsed ask attention re-evaluates.
                self?.lastRendered = nil
                self?.refresh()
            }
        }
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
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
        popover?.performClose(nil); popover = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    func flashSuccess(_ text: String) {
        // Success flash: dark green absolute ink (not systemGreen via darkAqua).
        flash(text, symbol: "checkmark.circle.fill", role: .calm, forceGreen: true)
    }

    /// Something was deliberately *not* done (⌘D on a system service). A green
    /// checkmark here would claim a capture that never happened.
    func flashNotice(_ text: String) {
        flash(text, symbol: "nosign", role: .calm, forceGreen: false)
    }

    private func flash(
        _ text: String,
        symbol: String,
        role: MenuBarTitleInk.Role,
        forceGreen: Bool
    ) {
        guard let button = item?.button else { return }
        button.appearance = NSAppearance(named: .aqua)
        button.image = Self.symbolImage(symbol, template: false)
        if forceGreen {
            let green = NSColor(srgbRed: 0.12, green: 0.55, blue: 0.28, alpha: 1)
            let font = AgentNotchChrome.statusItemTitleFont
            button.attributedTitle = NSAttributedString(
                string: " " + text,
                attributes: [.font: font, .foregroundColor: green]
            )
            button.contentTintColor = green
        } else {
            Self.applyStatusTitle(button, text: " " + text, role: role)
            button.contentTintColor = Self.nsColor(role: role)
        }
        flashUntil = Date().addingTimeInterval(1.8)
        lastRendered = nil   // force a real redraw once the flash expires
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Icon state machine

    private func refresh() {
        // Native keep-awake must track agent busy even when the popover is
        // closed (popover is only created on click — onChange there never fires).
        keepAwake.syncWithAgents(busyCount: activity.summary.busyCount)

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

        // Cheap signature of everything the icon depends on; thrash-guard via
        // UICadence so continuous resource/agent ticks never re-paint fixed chrome.
        let signature = UICadence.menuBarGlyphSignature(
            pendingCount: pendingCount,
            collapseBits: collapse?.bits,
            busyCount: summary.busyCount,
            primaryBusyName: summary.busy.first?.displayName ?? "",
            liveCount: summary.connected.count,
            bridgeConnected: bridge.connected,
            constrainedKey: constrainedKey,
            coresKey: coresKey
        )
        guard UICadence.shouldPaintMenuBarGlyph(
            previousSignature: lastRendered,
            nextSignature: signature
        ) else { return }
        lastRendered = signature

        if pendingCount > 0 {
            // Gate pending trumps everything — this is the state that needs LP.
            button.image = Self.symbolImage("questionmark.bubble.fill", template: false)
            Self.applyStatusTitle(
                button,
                text: pendingCount > 1 ? " \(pendingCount)" : "",
                role: .ask
            )
            // Solid amber attention always; pulse only when motion is allowed.
            button.contentTintColor = Self.nsColor(role: .ask)
            button.setAccessibilityLabel(
                "Shannon: \(pendingCount) gate approval\(pendingCount > 1 ? "s" : "") pending")
            syncAskAttentionPulse()
            return
        }
        stopPulse()

        if let collapse {
            button.image = Self.symbolImage("exclamationmark.triangle.fill", template: false)
            Self.applyStatusTitle(
                button,
                text: String(format: " H %.1f", collapse.bits),
                role: .collapse
            )
            button.contentTintColor = Self.nsColor(role: .collapse)
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
            let titleText: String
            if summary.busy.count > 1 {
                titleText = " \(summary.busy.count)"
            } else if let c = constrained, c.percent >= 80 {
                titleText = " \(c.shortLabel)"
            } else if let cpu = snap.cpuPercent {
                titleText = String(format: " %.0f%%", cpu)
            } else {
                titleText = ""
            }
            let loadPct = constrained?.percent ?? snap.cpuPercent
            Self.applyStatusTitle(button, text: titleText, loadPercent: loadPct)
            // Do not tint the multicolor glyph with title ink.
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
            Self.applyStatusTitle(button, text: title, loadPercent: constrained?.percent)
            button.contentTintColor = nil
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

    /// High-contrast monospaced-digit title for the status item.
    ///
    /// Uses **absolute sRGB** from `MenuBarTitleInk` — never `NSColor.labelColor`.
    /// Host load uses continuous scarcity intensity via `loadPercent`.
    private static func applyStatusTitle(
        _ button: NSStatusBarButton,
        text: String,
        role: MenuBarTitleInk.Role
    ) {
        applyStatusTitle(button, text: text, color: nsColor(role: role))
    }

    private static func applyStatusTitle(
        _ button: NSStatusBarButton,
        text: String,
        loadPercent: Double?
    ) {
        applyStatusTitle(button, text: text, color: nsColor(loadPercent: loadPercent))
    }

    private static func applyStatusTitle(
        _ button: NSStatusBarButton,
        text: String,
        color: NSColor
    ) {
        button.appearance = NSAppearance(named: .aqua)
        if text.isEmpty {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        // AgentNotchChrome single-source point size (not a one-off 11pt).
        let font = AgentNotchChrome.statusItemTitleFont
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
            ]
        )
    }

    private static func nsColor(role: MenuBarTitleInk.Role) -> NSColor {
        let c = MenuBarTitleInk.sRGB(for: role)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    private static func nsColor(loadPercent: Double?) -> NSColor {
        let c = MenuBarTitleInk.sRGB(loadPercent: loadPercent)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
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

    /// Ask attention on the status item: solid amber under Reduce Motion
    /// (matches notch HUD / `PillChromePolicy.allowsForeverPulse`); otherwise a
    /// subtle full↔dim breath so pending gates stay visible without thrashing.
    private func syncAskAttentionPulse() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if PillChromePolicy.shouldRunMenuBarAskPulse(reduceMotion: reduceMotion) {
            startPulse()
        } else {
            stopPulse()
            item?.button?.contentTintColor = Self.nsColor(role: .ask)
        }
    }

    /// Subtle attention pulse while a gate waits. Only started when policy allows.
    private func startPulse() {
        guard pulseTimer == nil else { return }
        let full = Self.nsColor(role: .ask)
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.item?.button else { return }
                // Mid-session Reduce Motion toggle: drop to solid amber immediately.
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if !PillChromePolicy.shouldRunMenuBarAskPulse(reduceMotion: reduceMotion) {
                    self.stopPulse()
                    button.contentTintColor = full
                    return
                }
                self.pulsePhase.toggle()
                let alpha = PillChromePolicy.menuBarAskPulseAlpha(
                    reduceMotion: false,
                    phaseOn: self.pulsePhase
                )
                button.contentTintColor = full.withAlphaComponent(alpha)
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
        // Reuse one popover + hosting controller for the whole process lifetime.
        // Recreating on every open (or, worse, on sample ticks) looked like the
        // menu was popping in and out while the HUD refreshed.
        let pop: NSPopover
        if let existing = popover {
            pop = existing
        } else {
            let p = NSPopover()
            p.behavior = .semitransient
            // No open/close size animation — live metric ticks must never morph.
            p.animates = false
            p.appearance = NSAppearance(named: .darkAqua)
            // Seed live model before first rootView so footer is never stale at create.
            multiDeviceStatusModel.update(multiDeviceStatusProvider())
            let root = MenuBarPopoverView(
                activity: activity,
                bridge: bridge,
                battery: battery,
                resources: resources,
                keepAwake: keepAwake,
                focusMode: focusMode,
                multiDeviceStatus: multiDeviceStatusModel,
                parity: parity,
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
                    self?.openSettings()
                },
                onQuit: { NSApp.terminate(nil) }
            )
            let host = NSHostingController(rootView: root)
            // Fixed preferred size — never let intrinsic content thrash the
            // popover frame (that shoved Quit out from under the cursor).
            host.sizingOptions = []
            let chrome = MenuBarPopoverView.fixedContentSize
            host.preferredContentSize = chrome
            p.contentSize = chrome
            p.contentViewController = host
            popover = p
            pop = p
        }
        // Re-assert fixed chrome size every open (hosting view can reset).
        // Clamp any thrash-driven proposal so Quit stays pinned under the cursor.
        if let host = pop.contentViewController as? NSHostingController<MenuBarPopoverView> {
            let chrome = MenuBarPopoverView.clampedContentSize(
                proposed: host.preferredContentSize
            )
            host.preferredContentSize = chrome
            pop.contentSize = chrome
        }
        // Refresh multi-device / iCloud footer on every open via ObservedObject.
        // Do not re-assign rootView — that tears down SwiftUI state and flashes.
        refreshMultiDeviceStatus()
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

        let petVisible = isDesktopCompanionVisible?()
            ?? ShannonPreferences.showDesktopCompanion()
        let pet = NSMenuItem(
            title: "Show Desktop Pet",
            action: #selector(toggleDesktopCompanion),
            keyEquivalent: "e"
        )
        pet.target = self
        pet.state = petVisible ? .on : .off
        pet.toolTip = petVisible
            ? "Hide the floating pet and status bubble"
            : "Show the floating pet and status bubble above other windows"
        menu.addItem(pet)

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
    @objc private func toggleDesktopCompanion() { onToggleDesktopCompanion?() }

    /// Builds the right-click utility menu (tests inspect checkmark state).
    func makeContextMenuForTesting() -> NSMenu { buildContextMenu() }
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

    /// Opens the Settings window. Falls back to ~/.shannon only if no callback.
    private func openSettings() {
        if let onOpenSettings {
            onOpenSettings()
            return
        }
        // Fail-closed fallback for tests / incomplete wiring.
        NSWorkspace.shared.open(PetBootstrap.shannonHome)
    }

    private static func symbolImage(_ name: String, template: Bool) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        // UX-027: status-item symbol a11y shares Core quietShort (brand chrome).
        let img = NSImage(
            systemSymbolName: name,
            accessibilityDescription: CompanionFocusCopy.quietShort
        )?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = template
        return img
    }
}
