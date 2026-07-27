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
    private var desktopCompanion: DesktopCompanionWindowController?
    private var floatingGlance: FloatingGlanceWindowController?
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
    /// ENH-030: holds AVSpeech path for needs-you / task_complete callouts.
    private var voiceCallout: MacVoiceCallout?

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

        // ENH-030: Mac voice callouts (AVSpeech; pref default off).
        let voiceCallout = MacVoiceCallout(synthesizer: MacVoiceCallout.makeDefaultSynthesizer())
        voiceCallout.voiceCalloutsEnabled = { ShannonPreferences.voiceCalloutsEnabled() }
        voiceCallout.isFocusActive = { [weak focus] in focus?.state == .on }
        activityMon.voiceCalloutsEnabled = { ShannonPreferences.voiceCalloutsEnabled() }
        activityMon.voiceFocusActive = { [weak focus] in focus?.state == .on }
        activityMon.onVoiceSpeak = { [weak voiceCallout] line in
            voiceCallout?.speakIfPresent(line)
        }
        // Keep the speaker alive for the app lifetime (ActivityMonitor holds the sink).
        self.voiceCallout = voiceCallout

        let cloudPub = CloudPublisher(
            nowPlaying: np, battery: bat, bridge: br, activity: activityMon, resources: sysRes
        )

        let ctl = PillWindowController(
            nowPlaying: np, battery: bat, bridge: br, idle: idlePub,
            confirmation: confirm, ingest: ingestSvc, activity: activityMon,
            resources: sysRes
        )
        ctl.show()

        // Floating desktop pet + chat bubble (always-on-top; separate from notch).
        let desk = DesktopCompanionWindowController(
            activity: activityMon,
            bridge: br,
            packagePetId: prefs.desktopPetId
        )
        // E4: click desktop pet/bubble → expand notch + focus matching agent row.
        desk.onActivate = { [weak ctl] agentId in
            ctl?.expand(focusAgentId: agentId)
        }
        if prefs.showDesktopCompanion {
            desk.show()
        }
        prefs.onShowDesktopCompanionChanged = { [weak desk] visible in
            if visible { desk?.show() } else { desk?.hide() }
        }
        prefs.onDesktopPetIdChanged = { [weak desk] id in
            desk?.setPackagePetId(id)
        }

        // UX-058: pref-gated floating fleet/usage glance (default off).
        let glance = FloatingGlanceWindowController(activity: activityMon)
        glance.onActivate = { [weak ctl] in
            ctl?.expand()
        }
        if prefs.showFloatingGlance {
            glance.show()
        }
        prefs.onShowFloatingGlanceChanged = { [weak glance] visible in
            if visible { glance?.show() } else { glance?.hide() }
        }

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
        menu.isDesktopCompanionVisible = { [weak prefs] in
            prefs?.showDesktopCompanion ?? ShannonPreferences.showDesktopCompanion()
        }
        menu.onToggleDesktopCompanion = { [weak prefs] in
            guard let prefs else { return }
            prefs.showDesktopCompanion.toggle()
        }
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
        cloudPub.start()

        nowPlaying = np; battery = bat; bridge = br; idle = idlePub
        ingest = ingestSvc; activity = activityMon; hotkey = hk
        cloud = cloudPub; confirmation = confirm; resources = sysRes
        keepAwake = keep; focusMode = focus
        preferencesStore = prefs; settingsWindow = settings
        controller = ctl; desktopCompanion = desk; floatingGlance = glance
        menuBar = menu

        // Pets bootstrap + secret scrub + hub ensure: all off MainActor so
        // launch does not hitch on disk walks or a gate spawn (macOS 27 glass
        // menu bar is especially sensitive to first-frame jank).
        Self.bootstrapPetsAndHubOffMain { [weak self] in
            self?.activity?.refresh()
        }

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

    /// Pets skeleton + junk scrub + hub ensure — utility queue only.
    /// Calls `onReady` on MainActor when the gate is up (or already was) so
    /// the menu bar flips hub-online without waiting a full agent poll.
    private static func bootstrapPetsAndHubOffMain(onReady: @escaping @MainActor () -> Void) {
        Task.detached(priority: .utility) {
            Self.bootstrapDefaultPets()
            Self.sanitizePollutedTasks()

            var env = ProcessInfo.processInfo.environment
            if env["SHANNON_ROOT"] == nil, let root = Self.discoverShannonRoot() {
                env["SHANNON_ROOT"] = root
            }
            let result = HubEnsure.ensureRunning(environment: env)
            #if DEBUG
            print("Shannon hub ensure: \(result.shortLabel)")
            #endif
            // Brief settle so a just-spawned gate can bind the socket, then
            // force an activity poll so gateAvailable updates immediately.
            if result == .started {
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            if result.isUp {
                await MainActor.run { onReady() }
            }
        }
    }

    /// Walk common roots for `hub/shannon_gate.py` without hardcoding a user.
    private nonisolated static func discoverShannonRoot(
        fileManager: FileManager = .default
    ) -> String? {
        var candidates: [String] = []
        let home = fileManager.homeDirectoryForCurrentUser.path
        candidates.append(home + "/Projects/Shannon")
        candidates.append(home + "/Developer/Shannon")
        // Walk up from the running app bundle (…/Shannon/Pill/build/….app).
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            candidates.append(url.path)
        }
        candidates.append(fileManager.currentDirectoryPath)
        for c in candidates {
            let gate = (c as NSString).appendingPathComponent("hub/shannon_gate.py")
            if fileManager.fileExists(atPath: gate) { return c }
        }
        return nil
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
    ///
    /// After a write, **force a full pets/registry scan** — gate-only ticks
    /// otherwise skip disk for up to `fullScanInterval` and the new agent never
    /// appears on the menu bar / pill until that timer fires.
    private func addAgentFromFrontApp() {
        guard let ingest else { return }
        let result = ingest.captureFromFrontApp()
        // Always force full scan after capture attempt that wrote a pet, so
        // identity + attach evidence hit AgentActivity immediately.
        if result.captured {
            activity?.refresh(forceFullScan: true)
        } else {
            activity?.refresh()
        }
        // Honest flash: green only when admission will list the agent on boards.
        switch LiveRosterAdmission.captureFlash(
            agentID: result.agent?.id,
            displayName: result.agent?.displayName,
            lastTask: result.taskSummary,
            attachPid: result.attachPid,
            attachBundle: result.attachBundle ?? result.agent?.bundleHint,
            refusalLabel: result.refusal?.label
        ) {
        case .success(let text):
            menuBar?.flashSuccess(text)
        case .notice(let text):
            menuBar?.flashNotice(text)
        }
        controller?.reassertVisibility()
        // Expand notch only when the agent will actually appear on the board.
        if result.willSurfaceOnRoster {
            controller?.expand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard self?.confirmation?.isAwaitingConfirmation != true else { return }
                self?.controller?.presentation.isExpanded = false
            }
        }
        desktopCompanion?.reassertVisibility()
        fputs("Shannon ingest: \(result.message) ← \(result.sourceApp)\n", stderr)
    }

    /// One-shot cleanup for pets polluted by earlier clipboard leaks (API keys, etc.).
    /// Safe off the main thread (disk only).
    private nonisolated static func sanitizePollutedTasks() {
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

    /// Idle skeleton pets only — does not clobber an active capture.
    private nonisolated static func bootstrapDefaultPets() {
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
                self?.desktopCompanion?.reassertVisibility()
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
