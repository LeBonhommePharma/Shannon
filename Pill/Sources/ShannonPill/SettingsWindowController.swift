import AppKit
import SwiftUI
import PillCore

/// Single reusable Settings window — fixed size, no intrinsic thrash.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: ShannonPreferencesStore
    private let onOpenShannonHome: () -> Void
    private let onOpenHubLog: () -> Void

    init(
        store: ShannonPreferencesStore,
        onOpenShannonHome: @escaping () -> Void,
        onOpenHubLog: @escaping () -> Void
    ) {
        self.store = store
        self.onOpenShannonHome = onOpenShannonHome
        self.onOpenHubLog = onOpenHubLog
    }

    /// Show or re-focus Settings. Reuses one window for the process lifetime.
    func show() {
        store.reload()
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win: NSWindow
        if let existing = window {
            win = existing
        } else {
            let root = SettingsView(
                store: store,
                onOpenShannonHome: onOpenShannonHome,
                onOpenHubLog: onOpenHubLog,
                onDone: { [weak self] in self?.close() }
            )
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []
            host.preferredContentSize = NSSize(
                width: SettingsView.chromeWidth,
                height: SettingsView.chromeHeight
            )
            win = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0,
                    width: SettingsView.chromeWidth,
                    height: SettingsView.chromeHeight
                ),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "Shannon Settings"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isReleasedWhenClosed = false
            win.contentViewController = host
            win.appearance = NSAppearance(named: .darkAqua)
            win.backgroundColor = .clear
            win.setContentSize(host.preferredContentSize)
            win.center()
            // Accessory apps need this so Settings can become key.
            win.level = .normal
            win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            self.window = win
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
    }
}
