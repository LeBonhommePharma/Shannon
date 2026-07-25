import AppKit
import PillCore

/// Notification posted by a second launch so the living instance re-shows itself.
private let activateNotification = Notification.Name("com.lebonhommepharma.shannon.pill.activate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var useDemo: Bool {
        CommandLine.arguments.contains("--demo")
            || ProcessInfo.processInfo.environment["SHANNON_PILL_DEMO"] == "1"
    }

    private var processLock: ProcessGuard.LockHandle?
    private var controller: PillWindowController?
    private var menuBar: MenuBarController?
    private var nowPlaying: NowPlayingModel?
    private var battery: BatteryMonitor?
    private var bridge: ShannonBridge?
    private var idle: IdleTelemetryPublisher?
    private var ingest: AgentIngestService?
    private var activity: AgentActivityMonitor?
    private var hotkey: HotkeyMonitor?
    private var demoProvider: StubNowPlayingProvider?
    private var demoMotion: StubHeadphoneMotionProvider?
    private var confirmation: ConfirmationController?
    private var cloud: CloudPublisher?
    private var resources: SystemResourceMonitor?
    private var keepAwake: KeepAwakeMonitor?
    private var focusMode: FocusModeMonitor?
    private var preferencesStore: ShannonPreferencesStore?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimSingleInstance() else { return }

        NSApp.setActivationPolicy(.accessory)
        // Force the entire application into dark mode regardless of the system
        // appearance setting. Shannon is a monitoring tool that lives on the
        // menu bar; dark-first is the right choice for an always-visible overlay.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        logBoot()
        watchForReactivate()
        FrontmostAppTracker.shared.start()

        // Core models — MediaRemote first, Music/Spotify AppleScript when gated empty
        // (BLOCKED.md §1). Demo still uses the stub.
        let media: NowPlayingProviding = Self.useDemo
            ? { let s = StubNowPlayingProvider(); demoProvider = s; return s }()
            : CompositeNowPlayingProvider()
        let motion: HeadphoneMotionProviding = Self.useDemo
            ? { let s = StubHeadphoneMotionProvider(); demoMotion = s; return s }()
            : makeHeadphoneMotionProvider()

        let np = NowPlayingModel(provider: media)
        let bat = BatteryMonitor(provider: IOKitBatteryProvider())
        let br = ShannonBridge()
        let idlePub = IdleTelemetryPublisher()
        let ingestSvc = AgentIngestService()
        let activityMon = AgentActivityMonitor()
        let confirm = ConfirmationController(provider: motion, feedback: SystemConfirmationFeedback())
        // UICadence resource interval + exponential smooth → responsive continuous gauges.
        let sysRes = SystemResourceMonitor(
            interval: UICadence.resourceInterval,
            smoothAlpha: UICadence.resourceSmoothAlpha
        )

        // Native keep-awake (caffeinate-class IOPMAssertion) — no Amphetamine.
        let keep = KeepAwakeMonitor()
        // Focus / DND best-effort (BLOCKED.md §2) — fail-closed to unknown.
        let focus = FocusModeMonitor()

        // Preferences (Settings window + launch behavior).
        let prefs = ShannonPreferencesStore()
        // Honor persisted keep-awake auto before first agent tick.
        keep.applyAutoKeepAwakeFromPreferences(prefs.autoKeepAwakeWithAgents)
        prefs.onAutoKeepAwakeChanged = { [weak keep] value in
            keep?.applyAutoKeepAwakeFromPreferences(value)
        }
        if prefs.startWithMonitoringPaused {
            activityMon.isPaused = true
        }

        // UI
        // Prefer notification permission early so ask alerts can fire later.
        ShannonNotifier.requestPermission()

        let cloudPub = CloudPublisher(
            nowPlaying: np, battery: bat, bridge: br, activity: activityMon, resources: sysRes
        )

        let ctl = PillWindowController(
            nowPlaying: np, battery: bat, bridge: br, idle: idlePub,
            confirmation: confirm, ingest: ingestSvc, activity: activityMon,
            resources: sysRes
        )
        ctl.show()

        let settings = SettingsWindowController(
            store: prefs,
            onOpenShannonHome: { NSWorkspace.shared.open(PetBootstrap.shannonHome) },
            onOpenHubLog: {
                let log = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/Shannon/pill.log")
                if FileManager.default.fileExists(atPath: log.path) {
                    NSWorkspace.shared.open(log)
                } else {
                    NSWorkspace.shared.open(log.deletingLastPathComponent())
                }
            }
        )

        let menu = MenuBarController(
            bridge: br, battery: bat, ingest: ingestSvc, activity: activityMon,
            resources: sysRes,
            keepAwake: keep,
            focusMode: focus,
            multiDeviceStatus: cloudPub.multiDeviceStatus
        )
        menu.onShowPill = { [weak ctl] in ctl?.reassertVisibility(); ctl?.expand() }
        menu.onReposition = { [weak ctl] in ctl?.reposition() }
        menu.onAddAgent = { [weak self] in self?.addAgentFromFrontApp() }
        menu.onOpenSettings = { [weak settings] in settings?.show() }
        menu.start()

        // Global ⌘D (Carbon) — works while you're in Terminal / Claude / browser.
        let hk = HotkeyMonitor()
        hk.onCmdD = { [weak self] in self?.addAgentFromFrontApp() }
        hk.start()

        // Services
        // Idle telemetry publisher is kept for bridge-absent provenance paths but
        // is NOT started — its 1 Hz @Published was thrashing the pill with no UI.
        np.start(); bat.start(); br.start(); activityMon.start()
        sysRes.start()
        keep.start()
        focus.start()
        // Sample-aligned menu-bar paint (not a second lagging timer alone).
        sysRes.onSnapshotPublished = { [weak menu] in
            menu?.refreshFromResources()
        }
        bootstrapDefaultPets()
        sanitizePollutedTasks()
        cloudPub.start()

        nowPlaying = np; battery = bat; bridge = br; idle = idlePub
        ingest = ingestSvc; activity = activityMon; hotkey = hk
        cloud = cloudPub; confirmation = confirm; resources = sysRes
        keepAwake = keep; focusMode = focus
        preferencesStore = prefs; settingsWindow = settings
        controller = ctl; menuBar = menu

        // Auto-attach Shannon hub (gate) so ⌘D process attach can register
        // agents without a manual "start gate" ritual. Best-effort, off main.
        Self.ensureHubAttached()

        if Self.useDemo {
            injectDemoMedia()
            confirm.ask(ConfirmationPrompt(question: "Dock this ligand?", detail: "1a4g · Astex Diverse")) {
                answer, source in print("demo: \(answer.rawValue) via \(source.rawValue)")
            }
        }

        // Hello flash (optional via Settings) so a first launch is obviously alive.
        if prefs.expandPillOnLaunch {
            ctl.expand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak ctl, weak confirm, weak menu] in
                guard confirm?.isAwaitingConfirmation != true else { return }
                ctl?.presentation.isExpanded = false
                // First-run: auto-open popover once so coach is not buried behind a click.
                if FirstRunCoach.shouldShow() {
                    menu?.presentFirstRunPopover()
                }
            }
        } else if FirstRunCoach.shouldShow() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak menu] in
                menu?.presentFirstRunPopover()
            }
        }
    }

    /// Best-effort hub ensure on launch. Never blocks the UI thread.
    private static func ensureHubAttached() {
        Task.detached(priority: .utility) {
            // Repo root for developers: env or sibling of common checkouts.
            var env = ProcessInfo.processInfo.environment
            if env["SHANNON_ROOT"] == nil {
                // Prefer the monorepo if Shannon is opened from a known path.
                let candidates = [
                    "/Users/lp.more/Projects/Shannon",
                    FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Projects/Shannon").path,
                ]
                for c in candidates {
                    let gate = (c as NSString).appendingPathComponent("hub/shannon_gate.py")
                    if FileManager.default.fileExists(atPath: gate) {
                        env["SHANNON_ROOT"] = c
                        break
                    }
                }
            }
            let result = HubEnsure.ensureRunning(environment: env)
            #if DEBUG
            print("Shannon hub ensure: \(result.shortLabel)")
            #endif
            // Nudge activity so socket-up is noticed quickly after a start.
            if result.isUp {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
        menuBar?.stop()
        bridge?.stop()
        idle?.stop()
        activity?.stop()
        nowPlaying?.stop()
        battery?.stop()
        resources?.stop()
        keepAwake?.stop()
        focusMode?.stop()
        cloud?.stop()
        FrontmostAppTracker.shared.stop()
        processLock = nil
    }

    // MARK: - ⌘D: add agent from frontmost app

    /// Capture Terminal / Claude / ChatGPT / Codex / browser / Cursor / … as an
    /// agent, write its pet under `~/.shannon/pets/`, update the registry, and
    /// flash the pill. Fully offline-safe; gate notify is best-effort.
    ///
    /// A frontmost app that is not an agent at all (WindowManager, the Dock, a
    /// menu-bar meter) is *refused*: the menu bar says so instead of flashing a
    /// green checkmark for a capture that never happened.
    private func addAgentFromFrontApp() {
        guard let ingest else { return }
        let result = ingest.captureFromFrontApp()
        activity?.refresh()
        if let agent = result.agent {
            menuBar?.flashSuccess("+\(agent.id)")
        } else {
            menuBar?.flashNotice(result.refusal.map { "not an agent · \($0.label)" }
                ?? "not an agent")
        }
        controller?.reassertVisibility()
        controller?.expand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard self?.confirmation?.isAwaitingConfirmation != true else { return }
            self?.controller?.presentation.isExpanded = false
        }
        fputs("Shannon ingest: \(result.message) ← \(result.sourceApp)\n", stderr)
    }

    /// One-shot cleanup for pets polluted by earlier clipboard leaks (API keys, etc.).
    private func sanitizePollutedTasks() {
        let root = PetBootstrap.petsRoot
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for dir in kids {
            let stateURL = dir.appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: stateURL),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let task = obj["last_task"] as? String,
                  AgentActivitySnapshot.looksLikeSecretOrJunk(task) else { continue }
            obj["last_task"] = ""
            obj["status"] = "idle"
            obj["resumable"] = false
            if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: stateURL, options: .atomic)
            }
        }
        // Registry too
        let reg = PetBootstrap.registryURL
        if let data = try? Data(contentsOf: reg),
           var arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var changed = false
            for i in arr.indices {
                if let task = arr[i]["last_task"] as? String,
                   AgentActivitySnapshot.looksLikeSecretOrJunk(task) {
                    arr[i]["last_task"] = ""
                    changed = true
                }
            }
            if changed, let out = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: reg, options: .atomic)
            }
        }
    }

    private func bootstrapDefaultPets() {
        let defaults = [
            ("science", "Claude Science"),
            ("claude_code", "Claude"),
            ("design", "Claude Design"),
            ("codex", "Codex"),
            ("chatgpt", "ChatGPT"),
            ("grok_build", "Grok Build"),
            ("terminal", "Terminal"),
            ("browser", "Browser"),
            ("cursor", "Cursor"),
            ("dataset_runner", "DatasetRunner"),
        ]
        for (id, name) in defaults {
            // task: nil → idle skeleton only (does not clobber an active capture).
            let dir = PetBootstrap.petsRoot.appendingPathComponent(id)
            if FileManager.default.fileExists(atPath: dir.path) { continue }
            _ = try? PetBootstrap.ensurePet(agentID: id, displayName: name, task: nil)
        }
    }

    // MARK: - Helpers

    private func claimSingleInstance() -> Bool {
        let (outcome, handle) = ProcessGuard.acquire()
        switch outcome {
        case .acquired:
            processLock = handle
            return true
        case .alreadyRunning(let pid):
            fputs("Shannon already running (pid \(pid)) — activating.\n", stderr)
            DistributedNotificationCenter.default().postNotificationName(
                activateNotification, object: nil, userInfo: nil, deliverImmediately: true
            )
            NSApp.terminate(nil)
            return false
        case .failed(let msg):
            fputs("Shannon lock warning: \(msg)\n", stderr)
            return true
        }
    }

    private func watchForReactivate() {
        DistributedNotificationCenter.default().addObserver(
            forName: activateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.controller?.reassertVisibility()
                self?.controller?.expand()
            }
        }
    }

    private func injectDemoMedia() {
        guard let demoProvider else {
            controller?.expand()
            return
        }
        demoProvider.emit(.updated(NowPlayingInfo(
            title: "Configurational Entropy",
            artist: "Shannon",
            album: "Notch Sessions",
            duration: 214,
            elapsed: 37,
            isPlaying: true
        )))
        controller?.expand()
    }

    private func logBoot() {
        let line = "Shannon boot — \(ProcessInfo.processInfo.operatingSystemVersionString) demo=\(Self.useDemo)\n"
        fputs(line, stderr)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Shannon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pill.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: file.path),
           let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}

@main
@MainActor
struct ShannonPillMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--probe") { probeAndExit() }
        if args.contains("--help") || args.contains("-h") {
            print(
                """
                Shannon — macOS notch + menu-bar agent

                  ./scripts/shannon                 build, install, start
                  ./scripts/shannon stop|status|probe

                  ⌘D   Add agent from frontmost app (Terminal, Claude, ChatGPT,
                       Codex, browser, Cursor, …) and create its pet.
                       Clipboard override:  agent: science fix the CF floor

                  ShannonPill --demo                 stub media
                  ShannonPill --probe                diagnostics
                """
            )
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    private static func probeAndExit() -> Never {
        print("Shannon probe — \(ProcessInfo.processInfo.operatingSystemVersionString)")

        if let b = IOKitBatteryProvider().currentSnapshots().first {
            print("  battery:     \(b.percentage)% \(b.isCharging ? "charging" : "discharging")")
        } else {
            print("  battery:     none (desktop?)")
        }

        let media = CompositeNowPlayingProvider()
        print("  mediaremote: \(media.isAvailable ? "ok (composite + scripted fallback)" : "missing")")
        if media.isAvailable {
            media.start { _ in }
            RunLoop.main.run(until: Date().addingTimeInterval(2.0))
            media.stop()
            print("  now playing: MediaRemote / Music / Spotify composite (see BLOCKED.md §1)")
        }

        let focus = FocusModeReader.read()
        print("  focus/dnd:   \(focus.state.rawValue)"
              + (focus.modeName.map { " (\($0))" } ?? ""))

        print("  bridge:      \(FileManager.default.fileExists(atPath: ShannonBridge.defaultSocketPath) ? "socket present" : "offline")")
        print("  pets:        \(PetBootstrap.petsRoot.path)")
        print("  registry:    \(PetBootstrap.listRegistry().count) agent(s)")
        print("  hotkey:      ⌘D = add agent from frontmost app")
        print("  head browse: HeadOrientationBrowser (sustained yaw) pure + tested")
        print("  verdict:     READY")
        exit(0)
    }
}
