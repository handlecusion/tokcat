import AppKit
import Carbon.HIToolbox

// Global hotkey via Carbon's RegisterEventHotKey — parity with the Tauri
// app's global-shortcut plugin (Ctrl+Cmd+T toggles the tray panel). Carbon
// is the only dependency-free way to get a system-wide hotkey; the modern
// alternatives either need Accessibility permission (CGEventTap) or an SPM
// package we don't want.
@MainActor
public final class HotKeyCenter {
    public var onHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    public init() {}

    /// Registers Ctrl+Cmd+T. Returns true when both the Carbon event
    /// handler install and RegisterEventHotKey came back noErr.
    @discardableResult
    public func registerToggleHotKey() -> Bool {
        guard hotKeyRef == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let center = Unmanaged<HotKeyCenter>
                    .fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers on the main thread, but the C callback is
                // nonisolated as far as Swift knows.
                Task { @MainActor in center.onHotKey?() }
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler
        )
        guard installStatus == noErr else {
            NSLog("Tokcat: InstallEventHandler failed (%d)", installStatus)
            return false
        }

        // 'TKCT'
        let hotKeyID = EventHotKeyID(signature: 0x544B_4354, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(controlKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus == noErr {
            NSLog("Tokcat: global hotkey Ctrl+Cmd+T registered (noErr)")
            return true
        }
        NSLog("Tokcat: RegisterEventHotKey failed (%d)", registerStatus)
        removeHandler()
        return false
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        removeHandler()
    }

    private func removeHandler() {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
