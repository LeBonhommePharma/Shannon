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
            // Fixed chrome only — never adopt intrinsic size (would thrash height
            // and crop the Done footer the way the menu-bar popover used to).
            host.sizingOptions = []
            let chrome = NSSize(
                width: SettingsView.chromeWidth,
                height: SettingsView.chromeHeight
            )
            host.preferredContentSize = chrome
            win = NSWindow(
                contentRect: NSRect(origin: .zero, size: chrome),
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
            // Content size == SwiftUI chrome; fullSizeContentView draws under
            // the title bar while SettingsView ignores top safe area so Done
            // stays inside the 580 pt band.
            win.setContentSize(chrome)
            win.contentMinSize = chrome
            win.contentMaxSize = chrome
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
