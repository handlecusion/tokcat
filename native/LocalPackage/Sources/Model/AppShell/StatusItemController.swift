import AppKit
import DataSource

// Owns the NSStatusItem. Left click toggles the tray panel (via closure),
// right click shows the context menu using the set-menu / performClick /
// clear-menu trick so the left click stays a plain action.
//
// The animated cat/parrot glyph is a RunnerLayer sublayer on the button's
// backing layer, drawn inside the image rect that a transparent placeholder
// NSImage reserves (mirrors src-tauri/src/native_tray.rs: setting a real
// image per tick runs the full AppKit redraw chain; a CALayer swap is
// compositor-only work).
@MainActor
public final class StatusItemController: NSObject {
    // Geometry mirrored from native_tray.rs: 18pt image box (matches the
    // icon height AppKit's status-bar button cell lays out) shifted 8pt
    // right so the glyph hugs the title.
    private static let iconPointSize: CGFloat = 18
    private static let iconXOffset: CGFloat = 8

    private let statusItem: NSStatusItem
    private let runner = RunnerLayer()
    private var currentStyle: AnimationStyle?
    private var appearanceObservation: NSKeyValueObservation?

    public var onLeftClick: (() -> Void)?
    public var menuProvider: (() -> NSMenu)?

    public var button: NSStatusBarButton? { statusItem.button }

    public override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        guard let button = statusItem.button else { return }
        // Transparent placeholder so the button cell reserves an image rect
        // (image-left, title-right). With no image at all the cell collapses
        // the image rect and centers the title under our layer.
        let placeholder = NSImage(size: NSSize(
            width: Self.iconPointSize, height: Self.iconPointSize))
        placeholder.isTemplate = true
        button.image = placeholder
        button.imagePosition = .imageLeft
        // Collapse the default image-title padding so the cat sits right
        // next to the title instead of leaving a gap.
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        installRunner(on: button)
    }

    deinit {
        // NSStatusBar APIs are main-thread only; the controller lives for
        // the app's lifetime so this is belt-and-braces.
        MainActor.assumeIsolated {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    // MARK: - Public API

    // Sets the text shown next to the animated glyph.
    public func setTitle(_ title: String) {
        statusItem.button?.title = title
    }

    /// Swap the cat/parrot frame set. No-op when the style is unchanged.
    public func setAnimationStyle(_ style: AnimationStyle) {
        guard style != currentStyle else { return }
        currentStyle = style
        runner.setFrames(TrayFrameAssets.frames(for: style))
    }

    /// animateTray setting: false freezes on the first frame.
    public func setAnimating(_ animating: Bool) {
        runner.setAnimating(animating)
    }

    /// Refresh in flight: freezes the spin and bobs the glyph.
    public func setRefreshing(_ refreshing: Bool) {
        runner.setRefreshing(refreshing)
    }

    /// Live token rate → animation speed (RunCat mapping). No live rate
    /// source is wired yet (the tailer isn't ported); callers may feed this
    /// once it lands and everything downstream already works.
    public func setRate(tokensPerMin: Double) {
        runner.setRate(tokensPerMin: tokensPerMin)
    }

    // MARK: - Runner layer

    private func installRunner(on button: NSStatusBarButton) {
        // The button is layer-backed on modern macOS; only request a layer
        // if it doesn't already have one (re-setting wantsLayer can swap the
        // layer instance and orphan our sublayer).
        if button.layer == nil {
            button.wantsLayer = true
        }
        guard let buttonLayer = button.layer else { return }

        let buttonHeight = button.bounds.height > 0
            ? button.bounds.height : NSStatusBar.system.thickness
        let baseY = max(0, (buttonHeight - Self.iconPointSize) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        runner.frame = CGRect(
            x: Self.iconXOffset, y: baseY,
            width: Self.iconPointSize, height: Self.iconPointSize)
        buttonLayer.insertSublayer(runner, at: 0)
        CATransaction.commit()

        setAnimationStyle(.cat)
        updateTint()

        // We can't subclass NSStatusBarButton (AppKit owns the instance), so
        // appearance changes are tracked via KVO on effectiveAppearance
        // instead of viewDidChangeEffectiveAppearance.
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateTint()
            }
        }
    }

    private func updateTint() {
        guard let button = statusItem.button else { return }
        // Resolve the label color under the button's effective appearance so
        // the glyph flips with the menubar (dark wallpaper, light mode, ...).
        var tint = NSColor.textColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = NSColor.textColor.cgColor
        }
        runner.setTint(tint)
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            onLeftClick?()
        }
    }

    private func showMenu() {
        guard let menu = menuProvider?() else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
