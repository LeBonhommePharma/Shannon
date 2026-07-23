import AppKit
import Combine
import SwiftUI
import PillCore

/// Shared expand/collapse state between the SwiftUI view and the window.
@MainActor
final class PillPresentation: ObservableObject {
    @Published var isExpanded = false
}

/// Borderless, non-activating panel pinned to the notch / menu bar.
///
/// macOS 27 adaptations:
/// - Window level sits above the menu bar (`statusWindow + 2`) so Liquid Glass
///   menu-bar chrome does not composite the pill underneath and hide it.
/// - `collectionBehavior` joins all Spaces and survives full-screen apps.
/// - `alphaValue` forced to 1; some AppKit paths leave new panels at 0.
/// - `hidesOnDeactivate = false` so switching apps never vanishes the agent.
final class PillPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // statusWindow + 2: above menu bar and above typical HUD overlays on
        // macOS 15–27 without fighting screen recording / Keynote presenter.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        isMovable = false
        hidesOnDeactivate = false
        alphaValue = 1.0
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        // Do NOT use .transient — on macOS 15–27 it removes the panel from the
        // window list when another app activates, which made the notch pill
        // vanish and look dead.
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PillWindowController {
    private var panel: PillPanel?
    let presentation = PillPresentation()
    private var cancellables = Set<AnyCancellable>()
    private var reassertTimer: Timer?

    private let nowPlaying: NowPlayingModel
    private let battery: BatteryMonitor
    private let bridge: ShannonBridge
    private let idle: IdleTelemetryPublisher
    private let confirmation: ConfirmationController
    private let ingest: AgentIngestService
    private let activity: AgentActivityMonitor

    init(
        nowPlaying: NowPlayingModel,
        battery: BatteryMonitor,
        bridge: ShannonBridge,
        idle: IdleTelemetryPublisher,
        confirmation: ConfirmationController,
        ingest: AgentIngestService,
        activity: AgentActivityMonitor
    ) {
        self.nowPlaying = nowPlaying
        self.battery = battery
        self.bridge = bridge
        self.idle = idle
        self.confirmation = confirmation
        self.ingest = ingest
        self.activity = activity
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let screen = NotchGeometry.preferredScreen()
        let geometry = NotchGeometry(screen: screen)
        let frame = geometry.windowFrame(
            contentSize: CGSize(width: PillMetrics.expandedWidth,
                                height: PillMetrics.expandedHeight)
        )

        let panel: PillPanel
        if let existing = self.panel {
            panel = existing
            panel.setFrame(frame, display: true)
        } else {
            panel = PillPanel(contentRect: frame)
            let root = PillHost(
                presentation: presentation,
                nowPlaying: nowPlaying,
                battery: battery,
                bridge: bridge,
                idle: idle,
                confirmation: confirmation,
                ingest: ingest,
                activity: activity
            )
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: frame.size)
            panel.contentView = host
            self.panel = panel

            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in self?.reposition() }
                .store(in: &cancellables)

            // Active Space changes (Mission Control) can leave the panel behind.
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                .sink { [weak self] _ in self?.reassertVisibility() }
                .store(in: &cancellables)
        }

        reassertVisibility()
        // First 8 seconds: re-front every second in case launch services /
        // Stage Manager / fullscreen steal the first orderFront.
        reassertTimer?.invalidate()
        var ticks = 0
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                self?.reassertVisibility()
                ticks += 1
                if ticks >= 8 {
                    timer.invalidate()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        reassertTimer = t
    }

    /// Force the panel on-screen. Safe to call repeatedly (menu-bar action).
    func reassertVisibility() {
        guard let panel else {
            show()
            return
        }
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()
        // Also nudge content view layout — macOS 27 can leave hosting views
        // at zero intrinsic size until the next runloop turn.
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func reposition() {
        guard let panel else { return }
        let geometry = NotchGeometry(screen: NotchGeometry.preferredScreen())
        panel.setFrame(
            geometry.windowFrame(contentSize: CGSize(width: PillMetrics.expandedWidth,
                                                     height: PillMetrics.expandedHeight)),
            display: true
        )
        reassertVisibility()
    }

    func expand() {
        presentation.isExpanded = true
        reassertVisibility()
    }
}

/// Wraps `PillView` so the window can share expand state with SwiftUI.
/// The host is always the full expanded size with a transparent surround;
/// the pill itself is top-centred inside it, which avoids resizing the window
/// on every hover.
private struct PillHost: View {
    @ObservedObject var presentation: PillPresentation
    @ObservedObject var nowPlaying: NowPlayingModel
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var bridge: ShannonBridge
    @ObservedObject var idle: IdleTelemetryPublisher
    @ObservedObject var confirmation: ConfirmationController
    @ObservedObject var ingest: AgentIngestService
    @ObservedObject var activity: AgentActivityMonitor

    var body: some View {
        VStack {
            PillView(
                nowPlaying: nowPlaying,
                battery: battery,
                bridge: bridge,
                idle: idle,
                confirmation: confirmation,
                ingest: ingest,
                activity: activity,
                isExpanded: Binding(
                    get: { presentation.isExpanded },
                    set: { presentation.isExpanded = $0 }
                )
            )
            Spacer(minLength: 0)
        }
        .frame(width: PillMetrics.expandedWidth, height: PillMetrics.expandedHeight)
        // Transparent host must still accept hits on the pill only.
        .contentShape(Rectangle())
    }
}
