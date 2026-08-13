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
    // tray.rs constants: MENU_BAR_H / POPOVER_SCREEN_MARGIN.
    private static let menuBarHeight: CGFloat = 24
    private static let screenMargin: CGFloat = 8

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
        // Resize on the NEXT runloop turn, never inside the SwiftUI layout
        // pass that reported the height: resizing the window mid-pass leaves
        // the hosting view's scroll view sized from a stale height (it ends
        // up off by the height delta, applied twice), which is what clipped
        // the header and left an empty band after a tab switch.
        //
        // Resize on the screen the panel is actually on — after the
        // hidden-status-item fallback the anchor button's screen is
        // unrelated to where the panel was placed.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.applyFrame(topAnchoredAt: self.panel.frame.maxY, on: self.panel.screen)
            self.resetScrollToTop()
        }
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
        if let screen = Self.menuBarScreen(containing: buttonFrame) {
            let top = buttonFrame.minY - Self.gapBelowStatusItem
            applyFrame(topAnchoredAt: top, centerX: buttonFrame.midX, on: screen)
        } else {
            // Status item hidden or unresolvable — a crowded menu bar or
            // notch overflow parks its window off-screen (or at a bogus
            // origin like x≈0, which used to drop the panel at the LEFT
            // edge on notched MacBooks). Mirror tray.rs: dock at the main
            // display's menu-bar right corner so the panel is always
            // visible and menu-bar-anchored.
            let screen = NSScreen.screens.first ?? NSScreen.main
            let visible = screen?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            applyFrame(
                topAnchoredAt: visible.maxY - Self.gapBelowStatusItem,
                centerX: visible.maxX - Self.screenMargin - Self.panelWidth / 2,
                on: screen)
        }
        panel.makeKeyAndOrderFront(nil)
        resetScrollToTop()
    }

    /// Reopening the panel must not restore the scroll offset it had when it
    /// was dismissed: the panel is resized to the content while hidden, so a
    /// stale offset shows up as a missing header plus an empty band at the
    /// bottom. Runs on the next pass, after the content has laid out.
    private func resetScrollToTop() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let scrollView = Self.firstScrollView(in: self.effectView)
            else { return }
            let clip = scrollView.contentView
            let flipped = clip.documentView?.isFlipped ?? true
            let top = flipped
                ? 0
                : (clip.documentView?.frame.height ?? 0) - clip.bounds.height
            guard abs(clip.bounds.origin.y - top) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: top))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView { return scrollView }
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    /// The screen whose menu-bar band actually contains the status-item
    /// frame (port of tray.rs's tray_anchor resolution). A hidden or
    /// overflowed item reports coordinates outside every screen's band and
    /// yields nil. Ambiguities in overlapping layouts resolve to the screen
    /// where the frame sits closest to the top, like the Rust min_by.
    private static func menuBarScreen(containing rect: NSRect) -> NSScreen? {
        let frames = NSScreen.screens.map(\.frame)
        guard let idx = Self.menuBarScreenIndex(for: rect, screenFrames: frames)
        else { return nil }
        return NSScreen.screens[idx]
    }

    /// Pure core of the anchor resolution, separated for tests: returns the
    /// index of the screen frame whose menu-bar band contains the rect.
    static func menuBarScreenIndex(for rect: NSRect,
                                   screenFrames: [NSRect]) -> Int? {
        guard rect.width > 0.5 else { return nil }
        var best: (belowTop: CGFloat, index: Int)?
        for (index, f) in screenFrames.enumerated() {
            guard rect.midX >= f.minX, rect.midX < f.maxX else { continue }
            // Cocoa Y is bottom-up: distance below the screen's top edge.
            let belowTop = f.maxY - rect.maxY
            guard (-4.0...(Self.menuBarHeight * 2)).contains(belowTop) else { continue }
            if best == nil || belowTop < best!.belowTop {
                best = (belowTop, index)
            }
        }
        return best?.index
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

    private func applyFrame(topAnchoredAt top: CGFloat, centerX: CGFloat? = nil,
                            on resolvedScreen: NSScreen? = nil) {
        // The resolved anchor screen wins: a hidden status item's window
        // reports a screen that has nothing to do with where the panel
        // should appear.
        let screen = resolvedScreen
            ?? anchorButton?.window?.screen
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

// MARK: - Keyboard shortcut normalization

/// Resolves the character a ⌘-shortcut should match on, layout-aware:
/// - Latin layouts (QWERTY, Dvorak, AZERTY…): `charactersIgnoringModifiers`
///   follows the layout, so ⌘Q is whatever key produces "q" — matching raw
///   key codes there would bind ⌘-quit to the wrong physical key.
/// - Non-Latin input sources (Korean 2-set…): the same property returns the
///   IME character ("ㄱ" for the R key), so fall back to the ANSI key-code
///   table, which is what the OS layout maps those sources onto.
public enum KeyShortcut {
    private static let ansiKeyCodeChars: [UInt16: Character] = [
        12: "q", 13: "w", 15: "r", 5: "g", 32: "u", 43: ",",
        33: "[", 30: "]",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9",
    ]

    public static func normalizedChar(for event: NSEvent) -> Character? {
        if let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.isASCII {
            return Character(Unicode.Scalar(scalar.value)!)
        }
        return ansiKeyCodeChars[event.keyCode]
    }
}

// MARK: - Panel

private final class TrayPanel: NSPanel {
    var onDismissKey: (() -> Void)?
    var keyEquivalentRouter: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            // The router runs FIRST so the app layer can intercept keys the
            // panel would otherwise swallow — e.g. ⌘W closes the settings
            // overlay before it falls through to hide-the-panel.
            if keyEquivalentRouter?(event) == true { return true }
            switch KeyShortcut.normalizedChar(for: event) {
            case "w":
                onDismissKey?()
                return true
            case "q":
                NSApp.terminate(nil)
                return true
            default:
                break
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
