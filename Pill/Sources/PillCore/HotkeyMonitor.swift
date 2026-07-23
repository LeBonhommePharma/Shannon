import Foundation
#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox
#endif

/// Global ⌘D hotkey for "Add agent from frontmost app".
///
/// Uses Carbon `RegisterEventHotKey`, which works for LSUIElement agents
/// **without** Accessibility permission (unlike `NSEvent` global monitors).
/// Falls back to a local `NSEvent` monitor when Carbon is unavailable so the
/// key still works while Shannon is focused.
@MainActor
public final class HotkeyMonitor {
    public var onCmdD: (() -> Void)?

    #if canImport(AppKit)
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var localMonitor: Any?
    #endif

    public init() {}

    public func start() {
        #if canImport(AppKit)
        installCarbonHotKey()
        // Local monitor covers the case where Carbon is busy / already taken.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isCmdD(event) {
                self?.onCmdD?()
                return nil // swallow
            }
            return event
        }
        #endif
    }

    public func stop() {
        #if canImport(AppKit)
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        #endif
    }

    #if canImport(AppKit)
    private static func isCmdD(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.shift),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control) else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "d"
    }

    private func installCarbonHotKey() {
        // signature 'ShnD' + id 1
        var hotKeyID = EventHotKeyID(signature: OSType(0x53686E44), id: 1)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // Retain self via unmanaged — stop() tears it down.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                var hk = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hk
                )
                guard err == noErr, hk.id == 1 else { return noErr }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { monitor.onCmdD?() }
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        guard status == noErr else { return }

        // kVK_ANSI_D = 0x02, cmdKey = 256
        let keyCode = UInt32(kVK_ANSI_D)
        let modifiers = UInt32(cmdKey)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }
    #endif
}
