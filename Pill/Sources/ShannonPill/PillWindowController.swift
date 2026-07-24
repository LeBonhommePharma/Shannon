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
            // Lock this window to dark mode so it stays correct even if the
            // user flips the system appearance while Shannon is running.
            panel.appearance = NSAppearance(named: .darkAqua)
            let root = PillHost(
                presentation: presentation,
                nowPlaying: nowPlaying,
                battery: battery,
                bridge: bridge,
                idle: idle,
                confirmation: confirmation,
                ingest: ingest,
                activity: activity,
                onContentHeight: { [weak self] height in
                    Task { @MainActor in self?.resizeToContent(height: height) }
                }
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
        // Keep whatever height the content has grown to. Recomputing from
        // PillMetrics.expandedHeight here would shrink the panel back to the
        // floor on every screen-parameter change — which fires on resolution
        // switches, exactly when the board needs to keep its room.
        let height = max(panel.frame.height, PillMetrics.expandedHeight)
        panel.setFrame(
            geometry.windowFrame(contentSize: CGSize(width: PillMetrics.expandedWidth,
                                                     height: height)),
            display: true
        )
        reassertVisibility()
    }

    /// Match the panel to the pill's laid-out height.
    ///
    /// The panel is top-anchored — its top edge sits on `screen.frame.maxY` — so
    /// a window shorter than its content does not scroll or clip gracefully: the
    /// surplus is drawn past the top of the display and lost, which is what
    /// sliced the header icon and the battery ring in half. Following the
    /// measured height keeps the whole board on-screen at every display mode
    /// (the usable menu-bar width either side of the notch ranges from ~117 pt
    /// to ~370 pt across the resolutions a 14" MacBook Pro offers), and the
    /// clamp stops a long agent list from growing the panel past the display.
    func resizeToContent(height: CGFloat) {
        guard let panel else { return }
        let geometry = NotchGeometry(screen: NotchGeometry.preferredScreen())
        let ceiling = geometry.screenFrame.height * PillMetrics.maxHeightFraction
        let clamped = min(max(height, PillMetrics.expandedHeight), ceiling)
        let frame = geometry.windowFrame(
            contentSize: CGSize(width: PillMetrics.expandedWidth, height: clamped)
        )
        // Sub-pixel churn would fight the content measurement in a feedback loop.
        guard abs(frame.height - panel.frame.height) > 0.5 else { return }
        panel.setFrame(frame, display: true)
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
    /// Called when the pill's laid-out height changes, so the panel can follow.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    @State private var hostHeight: CGFloat = PillMetrics.expandedHeight

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
        .frame(width: PillMetrics.expandedWidth, height: hostHeight)
        .onPreferenceChange(PillContentSizeKey.self) { size in
            // Grow the host (and, via onContentHeight, the panel) to whatever the
            // pill actually laid out. Shrinking back below the floor is pointless
            // churn, so this only ever tracks the larger of the two.
            let wanted = max(PillMetrics.expandedHeight, size.height.rounded(.up))
            guard abs(wanted - hostHeight) > 0.5 else { return }
            hostHeight = wanted
            onContentHeight(wanted)
        }
        // NO `.contentShape(Rectangle())` here.
        //
        // The panel is always the full expanded size (400 × 220) so hover does
        // not resize the window, but the *pill* is as small as 132 × 34 when
        // quiet. A content shape on this host made the entire 400 × 220 rect
        // hit-testable, so the pill silently swallowed every click in a large
        // transparent region below the notch — menu-bar items and window
        // titlebars under it became unclickable. PillView now declares its own
        // capsule content shape, and everything outside it hit-tests to nil and
        // falls through to whatever is behind.
        .preferredColorScheme(.dark)
    }
}
