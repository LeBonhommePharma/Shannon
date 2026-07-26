import AppKit
import Combine
import SwiftUI
import PillCore
import QuartzCore

/// Shared expand/collapse state between the SwiftUI view and the window.
@MainActor
final class PillPresentation: ObservableObject {
    @Published var isExpanded = false
    /// Desktop-pet handoff (E4): agent row to highlight while expanded.
    @Published var focusedAgentId: String? = nil
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
    private let resources: SystemResourceMonitor
    /// Shared with menu-bar popover when provided; else local model for notch density.
    private let parity: ParityPanelModel

    init(
        nowPlaying: NowPlayingModel,
        battery: BatteryMonitor,
        bridge: ShannonBridge,
        idle: IdleTelemetryPublisher,
        confirmation: ConfirmationController,
        ingest: AgentIngestService,
        activity: AgentActivityMonitor,
        resources: SystemResourceMonitor,
        parity: ParityPanelModel? = nil
    ) {
        self.nowPlaying = nowPlaying
        self.battery = battery
        self.bridge = bridge
        self.idle = idle
        self.confirmation = confirmation
        self.ingest = ingest
        self.activity = activity
        self.resources = resources
        // Own a model when app does not share the menu-bar parity instance.
        self.parity = parity ?? ParityPanelModel()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let screen = NotchGeometry.preferredScreen()
        let geometry = NotchGeometry(screen: screen)
        let frame = geometry.windowFrame(
            contentSize: CGSize(width: PillMetrics.expandedWidth,
                                height: PillMetrics.expandedHeight),
            hangBelowMenuBar: hangBelowMenuBar
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
                confirmation: confirmation,
                ingest: ingest,
                activity: activity,
                resources: resources,
                parity: parity,
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

            // Expand/collapse: move board below the menu bar so "Shannon" is not
            // clipped by the physical notch / menu-bar glass.
            presentation.$isExpanded
                .removeDuplicates()
                .sink { [weak self] _ in
                    Task { @MainActor in self?.applyFrameForCurrentPresentation() }
                }
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

    /// Expanded board on a physical notch hangs fully below the menu-bar band.
    private var hangBelowMenuBar: Bool {
        presentation.isExpanded
            && NotchGeometry(screen: NotchGeometry.preferredScreen()).hasNotch
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
        applyFrameForCurrentPresentation(force: true)
        reassertVisibility()
    }

    /// Match the panel to the pill's laid-out height.
    ///
    /// Collapsed: top-anchored into the notch cutout.
    /// Expanded on physical notch: top sits on the **bottom** of the menu-bar
    /// band so the header ("Shannon") is never sliced by the camera hole.
    func resizeToContent(height: CGFloat) {
        guard let panel else { return }
        let geometry = NotchGeometry(screen: NotchGeometry.preferredScreen())
        let clamped = PillPanelHeight.onContentHeight(
            height,
            floor: PillMetrics.expandedHeight,
            screenHeight: geometry.screenFrame.height,
            maxFraction: PillMetrics.maxHeightFraction
        )
        let frame = geometry.windowFrame(
            contentSize: CGSize(width: PillMetrics.expandedWidth, height: clamped),
            hangBelowMenuBar: hangBelowMenuBar
        )
        // Also re-anchor when expand toggles even if height is unchanged.
        let originDelta = abs(frame.origin.x - panel.frame.origin.x)
            + abs(frame.origin.y - panel.frame.origin.y)
        let delta = abs(frame.height - panel.frame.height)
        // Higher hysteresis: telemetry text reflow must not micro-morph the panel.
        guard delta > 14.0 || originDelta > 4.0 else { return }
        if delta > 32 || originDelta > 16 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = ShannonMotion.panelMorphDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            // Silent snap — no Core Animation implicit actions on the frame.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(frame, display: false)
            CATransaction.commit()
            panel.contentView?.needsDisplay = true
        }
    }

    /// Apply height + hang-below-menu-bar origin for current expand state.
    func applyFrameForCurrentPresentation(force: Bool = false) {
        guard let panel else { return }
        let geometry = NotchGeometry(screen: NotchGeometry.preferredScreen())
        let height = PillPanelHeight.onScreenChange(
            currentHeight: max(panel.frame.height, PillMetrics.expandedHeight),
            floor: PillMetrics.expandedHeight,
            screenHeight: geometry.screenFrame.height,
            maxFraction: PillMetrics.maxHeightFraction
        )
        let frame = geometry.windowFrame(
            contentSize: CGSize(width: PillMetrics.expandedWidth, height: height),
            hangBelowMenuBar: hangBelowMenuBar
        )
        if !force {
            let same = abs(frame.height - panel.frame.height) < 1
                && abs(frame.origin.y - panel.frame.origin.y) < 1
                && abs(frame.origin.x - panel.frame.origin.x) < 1
            if same { return }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = ShannonMotion.panelMorphDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    func expand(focusAgentId: String? = nil) {
        presentation.isExpanded = true
        presentation.focusedAgentId = DesktopCompanionHandoff.focusAgentId(focusAgentId)
        applyFrameForCurrentPresentation(force: true)
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
    @ObservedObject var confirmation: ConfirmationController
    @ObservedObject var ingest: AgentIngestService
    @ObservedObject var activity: AgentActivityMonitor
    @ObservedObject var resources: SystemResourceMonitor
    @ObservedObject var parity: ParityPanelModel
    /// Called when the pill's laid-out height changes, so the panel can follow.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    @State private var hostHeight: CGFloat = PillMetrics.expandedHeight

    var body: some View {
        VStack {
            PillView(
                nowPlaying: nowPlaying,
                battery: battery,
                bridge: bridge,
                confirmation: confirmation,
                ingest: ingest,
                activity: activity,
                resources: resources,
                parity: parity,
                isExpanded: Binding(
                    get: { presentation.isExpanded },
                    set: { newValue in
                        presentation.isExpanded = newValue
                        if !newValue {
                            presentation.focusedAgentId = nil
                        }
                    }
                ),
                focusedAgentId: presentation.focusedAgentId
            )
            Spacer(minLength: 0)
        }
        .frame(width: PillMetrics.expandedWidth, height: hostHeight)
        .onPreferenceChange(PillContentSizeKey.self) { size in
            // Grow the host (and, via onContentHeight, the panel) to whatever the
            // pill actually laid out. Shrinking back below the floor is pointless
            // churn, so this only ever tracks the larger of the two.
            //
            // Hysteresis of 6 pt: live H/resource text reflow used to report
            // ±1–3 pt every sample and morph the notch window ("pop" on refresh).
            let wanted = max(PillMetrics.expandedHeight, size.height.rounded(.up))
            // 12 pt hysteresis — live H/resource text must not re-anchor the panel.
            guard abs(wanted - hostHeight) > 12 else { return }
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
