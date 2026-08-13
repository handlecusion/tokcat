import AppKit
import Model
import SwiftUI

/// Loads the app mark bundled with UserInterface (a copy of
/// public/tokcat-logo.png, the .brand-logo image in HeaderBar.tsx).
@MainActor
private enum BrandLogo {
    static let image: NSImage? = {
        guard let url = Bundle.module.url(
            forResource: "tokcat-logo", withExtension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }()
}

// Port of HeaderBar.tsx: logo + "<N> tokens used in <year>" headline plus the
// theme picker, refresh button, and settings gear. The year select is a
// borderless accent-colored control with a chevron (.year-select); the theme
// select is a subtle gray chip (.theme-select) — neither shows a native bezel.
struct HeaderBar: View {
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var quotaStore: QuotaStore
    @ObservedObject private var keys = CmdHeldObserver.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var spinStartedAt: Date?

    /// The button drives both stores, so it has to keep spinning until the
    /// slower one lands — quota is the slower one (upstream calls plus
    /// subprocess spawns) and is usually why the user pressed Refresh.
    private var isRefreshing: Bool {
        store.isRefreshing || quotaStore.isRefreshing
    }

    private var mode: ThemeMode {
        Themes.theme(named: store.themeName).mode(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let logo = BrandLogo.image {
                // .brand-logo: 38×38, border-radius 9px.
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Formatters.humanizeTokens(store.overviewStats?.totalTokens ?? 0))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(mode.accent)
                Text("tokens used in")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                yearSelect
            }

            Spacer(minLength: 8)

            themeSelect

            Button {
                store.refresh()
                // Quota too: an expired Claude token is only cleared by
                // running `claude`, and Refresh is how the user asks for
                // that to be picked up rather than waiting out the timer.
                quotaStore.refreshNow()
            } label: {
                // Time-driven continuous spin (like the CSS .refresh-spin
                // keyframes): a state-animated repeatForever spun up with a
                // visible stutter and unwound BACKWARD when the refresh
                // finished. TimelineView rotates linearly from the moment
                // the refresh started and snaps home when it ends, exactly
                // like removing a CSS animation class.
                if let startedAt = spinStartedAt {
                    TimelineView(.animation) { context in
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(
                                context.date.timeIntervalSince(startedAt)
                                    / 0.8 * 360))
                    }
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .kbdPin("⌘R", visible: keys.cmdHeld)
            .onChange(of: isRefreshing) { refreshing in
                spinStartedAt = refreshing ? Date() : nil
            }

            Button {
                store.isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .kbdPin("⌘,", visible: keys.cmdHeld)
        }
    }

    // .year-select: borderless, accent-colored, 18px semibold, with the
    // dropdown chevron drawn by hand. The visible face is plain styled text;
    // clicking pops a real NSMenu — SwiftUI Menu/Picker overlays don't open
    // reliably inside the nonactivating tray panel on macOS 13.
    private var yearSelect: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(store.selectedYear)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(mode.accent)
        .contentShape(Rectangle())
        .onTapGesture {
            AppKitMenu.present(
                items: store.years.map { .init(title: $0, checked: $0 == store.selectedYear) },
                onSelect: { store.selectedYear = $0 })
        }
    }

    // .theme-select: subtle gray chip — 13px text on --control-bg with a
    // hairline --control-border, radius 8.
    private var themeSelect: some View {
        HStack(spacing: 4) {
            Text(store.themeName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            AppKitMenu.present(
                items: Themes.all.map { theme in
                    .init(title: theme.name,
                          checked: theme.name == store.themeName,
                          dotColor: NSColor(theme.mode(for: colorScheme).accent))
                },
                onSelect: { store.themeName = $0 })
        }
    }
}

// Real AppKit menus for the header's styled selects. SwiftUI Menu (and a
// Picker-in-Menu overlay) fails to open inside the nonactivating tray
// panel on macOS 13; NSMenu's own tracking loop has no such problem and,
// unlike a popover, never steals key status from the panel (so blur-hide
// stays quiet).
@MainActor
enum AppKitMenu {
    struct Item {
        var title: String
        var checked: Bool
        var dotColor: NSColor?

        init(title: String, checked: Bool, dotColor: NSColor? = nil) {
            self.title = title
            self.checked = checked
            self.dotColor = dotColor
        }
    }

    private final class Handler: NSObject {
        let onSelect: (String) -> Void
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        @objc func pick(_ sender: NSMenuItem) {
            onSelect(sender.title)
        }
    }

    // Retains the handler for the lifetime of the menu tracking session.
    private static var activeHandler: Handler?

    static func present(items: [Item], onSelect: @escaping (String) -> Void) {
        let handler = Handler(onSelect: onSelect)
        activeHandler = handler

        let menu = NSMenu()
        for item in items {
            let mi = NSMenuItem(title: item.title, action: #selector(Handler.pick(_:)),
                                keyEquivalent: "")
            mi.target = handler
            mi.state = item.checked ? .on : .off
            if let color = item.dotColor {
                mi.image = swatch(color)
            }
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        activeHandler = nil
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        return image
    }
}
