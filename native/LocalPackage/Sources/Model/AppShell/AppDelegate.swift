import AppKit

// Menu actions the tray menu can emit. Handlers are wired by the app
// target (or stay stubs during the shell phase).
public enum MenuAction: String, Sendable {
    case openTokcat
    case settings
    case refreshNow
    case about
    case checkForUpdates
}

// App shell entry point. The app target creates this, injects the panel
// content factory (Model must not import UserInterface — the layering is
// UserInterface → Model → DataSource, one-way), and sets it as
// NSApp.delegate before run().
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    // Builds the panel's content view. The factory receives a sink the
    // content should feed its natural height into (from the SwiftUI
    // ContentHeightKey preference); the panel resizes to follow.
    public var makePanelContent: ((@escaping @MainActor (CGFloat) -> Void) -> NSView)?

    // Menu items are stubs for now: they only forward here.
    public var onMenuAction: ((MenuAction) -> Void)?

    // Fired just before the panel becomes visible (left click, reopen,
    // "Open Tokcat"). The app uses it to refresh stale data on show.
    public var onPanelWillShow: (() -> Void)?

    public private(set) var statusItemController: StatusItemController?
    public private(set) var panelController: TrayPanelController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let panel = TrayPanelController()
        if let makePanelContent {
            let content = makePanelContent { [weak panel] height in
                panel?.setContentHeight(height)
            }
            panel.setContent(content)
        }
        panelController = panel

        let statusItem = StatusItemController()
        statusItem.onLeftClick = { [weak self] in
            guard let self else { return }
            if self.panelController?.isVisible != true {
                self.onPanelWillShow?()
            }
            self.panelController?.toggle(under: self.statusItemController?.button)
        }
        statusItem.menuProvider = { [weak self] in
            self?.makeMenu() ?? NSMenu()
        }
        statusItemController = statusItem
    }

    public func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if panelController?.isVisible != true { onPanelWillShow?() }
        panelController?.show(under: statusItemController?.button)
        return false
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(makeItem("Open Tokcat", action: .openTokcat))
        menu.addItem(makeItem("Settings…", action: .settings, keyEquivalent: ","))
        menu.addItem(makeItem("Refresh Now", action: .refreshNow, keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(makeItem("About Tokcat", action: .about))
        menu.addItem(makeItem("Check for Updates…", action: .checkForUpdates))
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Tokcat",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    private func makeItem(
        _ title: String, action: MenuAction, keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(menuItemSelected(_:)),
            keyEquivalent: keyEquivalent
        )
        item.target = self
        item.representedObject = action.rawValue
        return item
    }

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = MenuAction(rawValue: raw)
        else { return }
        switch action {
        case .openTokcat:
            if panelController?.isVisible != true { onPanelWillShow?() }
            panelController?.show(under: statusItemController?.button)
        default:
            break
        }
        onMenuAction?(action)
    }
}
