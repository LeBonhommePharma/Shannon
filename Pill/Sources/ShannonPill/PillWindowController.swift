import AppKit
import Combine
import SwiftUI
import PillCore

/// Shared expand/collapse state between the SwiftUI view and the window.
@MainActor
final class PillPresentation: ObservableObject {
    @Published var isExpanded = false
}

/// Borderless, non-activating panel pinned to the notch.
///
/// `.nonactivatingPanel` keeps the pill from stealing focus from whatever the
/// user is typing in, and `.statusBar + 1` puts it above the menu bar so it
/// visually merges with the notch.
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
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
    }

    // A borderless panel refuses key status by default; the pill never needs it.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PillWindowController {
    private var panel: PillPanel?
    private let presentation = PillPresentation()
    private var cancellables = Set<AnyCancellable>()

    private let nowPlaying: NowPlayingModel
    private let battery: BatteryMonitor
    private let bridge: ShannonBridge
    private let confirmation: ConfirmationController

    init(
        nowPlaying: NowPlayingModel,
        battery: BatteryMonitor,
        bridge: ShannonBridge,
        confirmation: ConfirmationController
    ) {
        self.nowPlaying = nowPlaying
        self.battery = battery
        self.bridge = bridge
        self.confirmation = confirmation
    }

    func show() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.main else { return }

        let geometry = NotchGeometry(screen: screen)
        let frame = geometry.windowFrame(
            contentSize: CGSize(width: PillMetrics.expandedWidth,
                                height: PillMetrics.expandedHeight)
        )

        let panel = PillPanel(contentRect: frame)
        let root = PillHost(
            presentation: presentation,
            nowPlaying: nowPlaying,
            battery: battery,
            bridge: bridge,
            confirmation: confirmation
        )
        panel.contentView = NSHostingView(rootView: root)
        panel.orderFrontRegardless()
        self.panel = panel

        // Reposition when displays change (dock a monitor, change resolution).
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
    }

    private func reposition() {
        guard let panel,
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.main else { return }
        let geometry = NotchGeometry(screen: screen)
        panel.setFrame(
            geometry.windowFrame(contentSize: CGSize(width: PillMetrics.expandedWidth,
                                                     height: PillMetrics.expandedHeight)),
            display: true
        )
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

    var body: some View {
        VStack {
            PillView(
                nowPlaying: nowPlaying,
                battery: battery,
                bridge: bridge,
                confirmation: confirmation,
                isExpanded: Binding(
                    get: { presentation.isExpanded },
                    set: { presentation.isExpanded = $0 }
                )
            )
            Spacer(minLength: 0)
        }
        .frame(width: PillMetrics.expandedWidth, height: PillMetrics.expandedHeight)
    }
}
