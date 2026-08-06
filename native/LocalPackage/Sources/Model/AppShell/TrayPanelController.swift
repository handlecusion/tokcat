import AppKit

// The borderless vibrancy panel that drops down from the status item.
// Content is injected as an NSView (built by the app target from
// UserInterface's DashboardRootView) and the panel follows the content's
// natural height via setContentHeight.
@MainActor
public final class TrayPanelController: NSObject, NSWindowDelegate {
    public static let panelWidth: CGFloat = 640
    private static let minHeight: CGFloat = 420
    private static let maxHeight: CGFloat = 1200
    private static let gapBelowStatusItem: CGFloat = 6

    private let panel: TrayPanel
    private let effectView: NSVisualEffectView
    private weak var anchorButton: NSStatusBarButton?
    private var reportedContentHeight: CGFloat = TrayPanelController.minHeight
    private var shieldCount = 0

    // Hook for routing ⌘-key equivalents the panel doesn't handle itself
    // (Esc/⌘W hide, ⌘Q quits). Return true when the event was consumed.
    public var keyEquivalentRouter: ((NSEvent) -> Bool)?

    public var isVisible: Bool { panel.isVisible }

    public override init() {
        panel = TrayPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.panelWidth, height: Self.minHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        panel.contentView = effectView

        super.init()
        panel.delegate = self
        panel.onDismissKey = { [weak self] in self?.hide() }
        panel.keyEquivalentRouter = { [weak self] event in
            self?.keyEquivalentRouter?(event) ?? false
        }
    }

    // MARK: - Content

    public func setContent(_ view: NSView) {
        effectView.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            view.topAnchor.constraint(equalTo: effectView.topAnchor),
            view.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
    }

    // Fed from the SwiftUI ContentHeightKey preference. Keeps the top edge
    // anchored while the panel grows or shrinks.
    public func setContentHeight(_ height: CGFloat) {
        reportedContentHeight = height
        guard panel.isVisible else { return }
        applyFrame(topAnchoredAt: panel.frame.maxY)
    }

    // MARK: - Show / hide

    public func show(under button: NSStatusBarButton?) {
        if let button { anchorButton = button }
        guard let anchor = anchorButton, let anchorWindow = anchor.window else {
            // No anchor known yet: center on the main screen as a fallback.
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let buttonFrame = anchorWindow.convertToScreen(
            anchor.convert(anchor.bounds, to: nil)
        )
        let top = buttonFrame.minY - Self.gapBelowStatusItem
        let centerX = buttonFrame.midX
        applyFrame(topAnchoredAt: top, centerX: centerX)
        panel.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        panel.orderOut(nil)
    }

    public func toggle(under button: NSStatusBarButton?) {
        if panel.isVisible {
            hide()
        } else {
            show(under: button)
        }
    }

    // MARK: - Shield (keeps the panel open while a sheet/menu is up)

    public func pushShield() {
        shieldCount += 1
    }

    public func popShield() {
        shieldCount = max(0, shieldCount - 1)
    }

    // MARK: - NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        guard shieldCount == 0 else { return }
        hide()
    }

    // MARK: - Layout

    private func applyFrame(topAnchoredAt top: CGFloat, centerX: CGFloat? = nil) {
        let screen = anchorButton?.window?.screen
            ?? panel.screen
            ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var height = min(max(reportedContentHeight, Self.minHeight), Self.maxHeight)

        // A status-bar window mid-layout (e.g. right at launch) can report a
        // bogus origin; anchoring there would collapse the panel to a zero
        // or negative height. Treat such tops as unusable and drop the panel
        // from the top of the visible frame instead.
        var top = top
        if top - visible.minY < Self.minHeight {
            top = visible.maxY - Self.gapBelowStatusItem
        }
        height = min(height, top - visible.minY)

        var x = (centerX ?? panel.frame.midX) - Self.panelWidth / 2
        x = min(max(x, visible.minX), visible.maxX - Self.panelWidth)

        let frame = NSRect(x: x, y: top - height, width: Self.panelWidth, height: height)
        panel.setFrame(frame, display: true)
    }
}

// MARK: - Panel

private final class TrayPanel: NSPanel {
    var onDismissKey: (() -> Void)?
    var keyEquivalentRouter: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "w":
                onDismissKey?()
                return true
            case "q":
                NSApp.terminate(nil)
                return true
            default:
                if keyEquivalentRouter?(event) == true { return true }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            onDismissKey?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onDismissKey?()
    }
}
