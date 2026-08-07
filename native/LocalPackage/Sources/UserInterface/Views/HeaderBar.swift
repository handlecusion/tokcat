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
    @ObservedObject private var keys = CmdHeldObserver.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var spinAngle: Double = 0

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
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(spinAngle))
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .kbdPin("⌘R", visible: keys.cmdHeld)
            .onChange(of: store.isRefreshing) { refreshing in
                if refreshing {
                    withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                        spinAngle = 360
                    }
                } else {
                    withAnimation(.linear(duration: 0.2)) { spinAngle = 0 }
                }
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
    // dropdown chevron drawn by hand. The visible face is plain styled text —
    // a borderless Menu on macOS repaints its label as a popup button (system
    // text color, indicator moved leading), so the Menu sits on top as an
    // invisible click target instead (menuOverlay).
    private var yearSelect: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(store.selectedYear)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(mode.accent)
        .overlay(menuOverlay {
            Picker("", selection: $store.selectedYear) {
                ForEach(store.years, id: \.self) { year in
                    Text(year).tag(year)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        })
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
        .overlay(menuOverlay {
            Picker("", selection: $store.themeName) {
                ForEach(Themes.all) { theme in
                    Text(theme.name).tag(theme.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        })
    }

    /// A Menu stretched over the styled control face, drawing nothing itself.
    private func menuOverlay(@ViewBuilder items: @escaping () -> some View)
        -> some View
    {
        Menu(content: items) {
            Color.clear
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .opacity(0.02)  // fully transparent Menus can drop clicks on macOS 13
        .contentShape(Rectangle())
    }
}
