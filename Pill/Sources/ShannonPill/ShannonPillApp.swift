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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimSingleInstance() else { return }

        NSApp.setActivationPolicy(.accessory)
        logBoot()
        watchForReactivate()
        FrontmostAppTracker.shared.start()

        // Core models
        let media: NowPlayingProviding = Self.useDemo
            ? { let s = StubNowPlayingProvider(); demoProvider = s; return s }()
            : MediaRemoteProvider()
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

        // UI
        let ctl = PillWindowController(
            nowPlaying: np, battery: bat, bridge: br, idle: idlePub,
            confirmation: confirm, ingest: ingestSvc, activity: activityMon
        )
        ctl.show()

        let menu = MenuBarController(
            bridge: br, idle: idlePub, battery: bat, ingest: ingestSvc, activity: activityMon
        )
        menu.onShowPill = { [weak ctl] in ctl?.reassertVisibility(); ctl?.expand() }
        menu.onReposition = { [weak ctl] in ctl?.reposition() }
        menu.onAddAgent = { [weak self] in self?.addAgentFromFrontApp() }
        menu.start()

        // Global ⌘D (Carbon) — works while you're in Terminal / Claude / browser.
        let hk = HotkeyMonitor()
        hk.onCmdD = { [weak self] in self?.addAgentFromFrontApp() }
        hk.start()

        // Services
        np.start(); bat.start(); br.start(); idlePub.start(); activityMon.start()
        bootstrapDefaultPets()
        sanitizePollutedTasks()
        let cloudPub = CloudPublisher(nowPlaying: np, battery: bat, bridge: br, activity: activityMon)
        cloudPub.start()

        nowPlaying = np; battery = bat; bridge = br; idle = idlePub
        ingest = ingestSvc; activity = activityMon; hotkey = hk
        cloud = cloudPub; confirmation = confirm
        controller = ctl; menuBar = menu

        if Self.useDemo {
            injectDemoMedia()
            confirm.ask(ConfirmationPrompt(question: "Dock this ligand?", detail: "1a4g · Astex Diverse")) {
                answer, source in print("demo: \(answer.rawValue) via \(source.rawValue)")
            }
        }

        // Hello flash so a first launch is obviously alive, then tuck into the notch.
        ctl.expand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak ctl, weak confirm] in
            guard confirm?.isAwaitingConfirmation != true else { return }
            ctl?.presentation.isExpanded = false
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
        cloud?.stop()
        FrontmostAppTracker.shared.stop()
        processLock = nil
    }

    // MARK: - ⌘D: add agent from frontmost app

    /// Capture Terminal / Claude / ChatGPT / Codex / browser / Cursor / … as an
    /// agent, write its pet under `~/.shannon/pets/`, update the registry, and
    /// flash the pill. Fully offline-safe; gate notify is best-effort.
    private func addAgentFromFrontApp() {
        guard let ingest else { return }
        let result = ingest.captureFromFrontApp()
        activity?.refresh()
        menuBar?.flashSuccess("+\(result.agent.id)")
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

        let media = MediaRemoteProvider()
        print("  mediaremote: \(media.isAvailable ? "ok" : "missing")")
        if media.isAvailable {
            media.start { _ in }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            media.stop()
            print("  now playing: \(media.hasDelivered ? "live" : "gated / idle")")
        }

        print("  bridge:      \(FileManager.default.fileExists(atPath: ShannonBridge.defaultSocketPath) ? "socket present" : "offline")")
        print("  pets:        \(PetBootstrap.petsRoot.path)")
        print("  registry:    \(PetBootstrap.listRegistry().count) agent(s)")
        print("  hotkey:      ⌘D = add agent from frontmost app")
        print("  verdict:     READY")
        exit(0)
    }
}
