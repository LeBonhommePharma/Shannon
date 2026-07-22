import AppKit
import PillCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--demo` drives the pill from a stub media source so the UI can be shown
    /// without a live media session (and on systems where MediaRemote is gated).
    static var useDemo: Bool { CommandLine.arguments.contains("--demo") }

    private var controller: PillWindowController?
    private var nowPlaying: NowPlayingModel?
    private var battery: BatteryMonitor?
    private var bridge: ShannonBridge?
    private var demoProvider: StubNowPlayingProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement is set in Info.plist; assert it at runtime too so a bare
        // `swift run` still behaves like an agent app with no dock icon.
        NSApp.setActivationPolicy(.accessory)

        let mediaProvider: NowPlayingProviding
        if Self.useDemo {
            let stub = StubNowPlayingProvider()
            demoProvider = stub
            mediaProvider = stub
        } else {
            mediaProvider = MediaRemoteProvider()
        }

        let np = NowPlayingModel(provider: mediaProvider)
        let bat = BatteryMonitor(provider: IOKitBatteryProvider())
        let br = ShannonBridge()

        let controller = PillWindowController(nowPlaying: np, battery: bat, bridge: br)
        controller.show()

        np.start()
        bat.start()
        br.start()

        nowPlaying = np
        battery = bat
        bridge = br
        self.controller = controller

        demoProvider?.emit(.updated(NowPlayingInfo(
            title: "Configurational Entropy",
            artist: "Shannon",
            album: "Notch Sessions",
            duration: 214,
            elapsed: 37,
            isPlaying: true
        )))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
@MainActor
struct ShannonPillMain {
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            probeAndExit()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        // Keep the delegate alive for the process lifetime.
        withExtendedLifetime(delegate) {}
    }

    /// `--probe` reports which live-activity sources actually work on this
    /// machine, then exits. Useful on a new macOS release, where MediaRemote
    /// may resolve but return nothing (see BLOCKED.md).
    private static func probeAndExit() -> Never {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        print("Shannon Pill probe — \(os)")

        let battery = IOKitBatteryProvider().currentSnapshots()
        if let first = battery.first {
            print("  battery:     OK — \(first.percentage)% "
                  + "\(first.isCharging ? "charging" : "discharging"), \(first.timeLabel)")
        } else {
            print("  battery:     no power sources reported (desktop Mac?)")
        }

        let media = MediaRemoteProvider()
        print("  mediaremote: symbols \(media.isAvailable ? "resolved" : "NOT resolved")")
        if media.isAvailable {
            media.start { _ in }
            // Give the async callback a moment to land.
            RunLoop.main.run(until: Date().addingTimeInterval(2.0))
            media.stop()
            print("  now playing: \(media.hasDelivered ? "delivering data" : "no data (entitlement-gated, or nothing playing)")")
        }

        let bridgePath = ShannonBridge.defaultSocketPath
        let client = UnixSocketClient()
        do {
            try client.connect(to: bridgePath)
            let status = try client.request(BridgeRequest(command: "status"))
            client.close()
            print("  bridge:      OK at \(bridgePath) — \(status.pillLabel), backend \(status.backend)")
        } catch {
            print("  bridge:      not reachable at \(bridgePath) (agent offline)")
        }
        exit(0)
    }
}
