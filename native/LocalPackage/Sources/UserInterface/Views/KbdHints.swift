import AppKit
import SwiftUI

// Port of the App.tsx cmdHeld tracking + .kbd-pin overlay: while the Cmd key
// is held, every actionable control shows a translucent shortcut-hint pin
// (⌘1…⌘9 on tabs, ⌘R / ⌘, in the header, ⌘G on the 2D/3D toggle).
//
// The web app listens for Meta keydown/keyup on window and force-resets on
// blur; natively a local .flagsChanged monitor covers both edges (it only
// fires while the app is key), and resign-key/resign-active notifications
// play the role of the blur reset so pins never stick after Cmd+Tab.
@MainActor
public final class CmdHeldObserver: ObservableObject {
    public static let shared = CmdHeldObserver()

    @Published public private(set) var cmdHeld = false

    private var monitor: Any?
    private var resetObservers: [any NSObjectProtocol] = []

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.cmdHeld = event.modifierFlags.contains(.command)
            return event
        }
        for name in [
            NSWindow.didResignKeyNotification,
            NSApplication.didResignActiveNotification,
        ] {
            resetObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cmdHeld = false }
                })
        }
    }

    /// Tears down the event monitor and notification observers. The shared
    /// instance lives for the process (a nonisolated deinit can't touch the
    /// main-actor monitor under Swift 6), so cleanup is an explicit call for
    /// any non-singleton use.
    public func invalidate() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        for observer in resetObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        resetObservers.removeAll()
    }
}

// Port of .kbd-pin: small translucent rounded chip with a monospace label.
struct KbdPin: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
            )
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}

extension View {
    /// Overlays a shortcut pin at the view's top-right corner while `visible`
    /// (.kbd-pin: top -7px, right -7px by default; tabs pass a zero offset to
    /// stay inside the scroll view's clip, like `.dash-tab .kbd-pin`).
    func kbdPin(
        _ label: String, visible: Bool,
        offset: CGSize = CGSize(width: 7, height: -7)
    ) -> some View {
        overlay(alignment: .topTrailing) {
            if visible {
                KbdPin(label: label)
                    .offset(x: offset.width, y: offset.height)
            }
        }
        .animation(.easeOut(duration: 0.12), value: visible)
    }
}
