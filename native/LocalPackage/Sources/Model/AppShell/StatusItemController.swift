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

    // Where macOS stores the item's spot, and the copy of the value we last
    // wrote there ourselves (so a user drag is distinguishable from it).
    private static let positionKey = "NSStatusItem Preferred Position Item-0"
    private static let seededPositionKey = "TokcatSeededStatusItemPosition"
    private static let fallbackPosition = 200.0

    private var statusItem: NSStatusItem
    private let runner = RunnerLayer()
    private var currentStyle: AnimationStyle?
    private var currentTitle = ""
    private var appearanceObservation: NSKeyValueObservation?
    private var recoveryTimer: Timer?
    private var screenObserver: (any NSObjectProtocol)?
    private var hiddenChecks = 0
    private var lastRecoveryAt = Date.distantPast
    private var preservedUserPosition = false

    public var onLeftClick: (() -> Void)?
    public var menuProvider: (() -> NSMenu)?

    public var button: NSStatusBarButton? { statusItem.button }

    public override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureItem()
        startVisibilityWatch()

        // Diagnostics for the "icon vanishes on crowded menu bars" report:
        // TOKCAT_DIAG_STATUS=1 logs the item's visibility and geometry.
        if ProcessInfo.processInfo.environment["TOKCAT_DIAG_STATUS"] == "1" {
            diagTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.logDiagnostics() }
            }
        }
    }

    private func configureItem() {
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
        button.title = currentTitle

        installRunner(on: button)
    }

    // MARK: - Hidden-item recovery
    //
    // macOS persists each status item's preferred position ("NSStatusItem
    // Preferred Position Item-0"). After a display-layout change (undocking
    // a notched MacBook, narrower bar) that position can land inside the
    // app-menu zone or the notch — the item's window is then parked far
    // off-screen and macOS NEVER re-places it, even when space frees up,
    // while `isVisible` keeps reporting true. Reproduced deterministically
    // by seeding a large preferred position. A freshly created item with no
    // stored position always takes the first free slot on the right, so the
    // recovery is: detect the parked state, drop the stored position, and
    // rebuild the item (reusing the runner layer + stored title/state).

    // Parked means the item's window sits outside every screen. Occlusion is
    // NOT a usable signal here: the menu bar legitimately disappears in
    // fullscreen and under auto-hide, and treating that as parked rebuilt the
    // item during normal use — which reset the position the user had dragged
    // it to.
    private var isEffectivelyHidden: Bool {
        guard let window = statusItem.button?.window else { return true }
        if window.screen == nil { return true }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return true }
        return !NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    private func startVisibilityWatch() {
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.checkVisibility() }
        }
        timer.tolerance = 5
        recoveryTimer = timer
        // Dock/undock is the usual trigger — check shortly after any screen
        // reconfiguration instead of waiting for the next timer tick.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self?.checkVisibility()
            }
        }
    }

    private func checkVisibility() {
        guard isEffectivelyHidden else {
            hiddenChecks = 0
            return
        }
        hiddenChecks += 1
        // Two consecutive sightings (~30s) so a transient relayout doesn't
        // trigger a rebuild; 120s backoff so a genuinely full menu bar (or
        // a sleeping display) can't cause a rebuild storm.
        guard hiddenChecks >= 2,
              Date().timeIntervalSince(lastRecoveryAt) > 120 else { return }
        hiddenChecks = 0
        lastRecoveryAt = Date()
        recreateItem()
    }

    private func recreateItem() {
        NSLog("Tokcat: status item parked off-screen; rebuilding it")
        appearanceObservation = nil
        runner.removeFromSuperlayer()
        NSStatusBar.system.removeStatusItem(statusItem)
        reseatPositionIfNeeded()
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        configureItem()
    }

    // The fallback value is the distance from the RIGHT edge. Removing the
    // preference doesn't help: a brand-new item is inserted at the LEFT end of
    // the status area, which on a crowded bar is exactly the hidden zone it
    // just died in (verified empirically). A small offset lands it beside the
    // system items, in the always-visible region. See StatusItemPlacement for
    // when the stored position is left alone instead.
    private func reseatPositionIfNeeded() {
        let defaults = UserDefaults.standard
        let decision = StatusItemPlacement.decide(
            stored: defaults.object(forKey: Self.positionKey) as? Double,
            seeded: defaults.object(forKey: Self.seededPositionKey) as? Double,
            alreadyPreserved: preservedUserPosition,
            fallback: Self.fallbackPosition)
        preservedUserPosition = decision.preservedUserPosition
        guard let seatAt = decision.seatAt else { return }
        defaults.set(seatAt, forKey: Self.positionKey)
        defaults.set(seatAt, forKey: Self.seededPositionKey)
    }

    private var diagTimer: Timer?

    private func logDiagnostics() {
        let item = statusItem
        let btn = item.button
        let winFrame = btn?.window?.frame ?? .zero
        let screenDesc = btn?.window?.screen.map { "\($0.frame)" } ?? "nil"
        NSLog("TOKCAT-DIAG isVisible=%d length=%.1f buttonBounds=%@ window=%@ screen=%@ occl=%lu",
              item.isVisible ? 1 : 0,
              item.length,
              NSStringFromRect(btn?.bounds ?? .zero),
              NSStringFromRect(winFrame),
              screenDesc,
              btn?.window?.occlusionState.rawValue ?? 0)
    }

    deinit {
        // NSStatusBar APIs are main-thread only; the controller lives for
        // the app's lifetime so this is belt-and-braces.
        MainActor.assumeIsolated {
            recoveryTimer?.invalidate()
            if let screenObserver {
                NotificationCenter.default.removeObserver(screenObserver)
            }
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    // MARK: - Public API

    // Sets the text shown next to the animated glyph. Stored so a rebuilt
    // item (hidden-item recovery) comes back with the same title.
    public func setTitle(_ title: String) {
        currentTitle = title
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

        // Keep the current style across a hidden-item rebuild (the runner
        // layer already holds its frames; only a first install needs .cat).
        setAnimationStyle(currentStyle ?? .cat)
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
