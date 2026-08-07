import Model
import SwiftUI

// Port of DashboardTabs.tsx: Overview plus one tab per client in the union
// of graph clients and quota clients (App.tsx dashboardClients) — a client
// with only quota data (e.g. Cursor) still gets a tab. Client marks are the
// drawn brand glyphs (ClientIconView), falling back to the colored initial
// disc. While Cmd is held the first nine tabs show ⌘1…⌘9 pins (⌘0 is
// unbound), pinned inside the tab's corner because the scroll view clips.
struct TabStrip: View {
    @EnvironmentObject private var store: DashboardStore
    @ObservedObject private var keys = CmdHeldObserver.shared
    @Environment(\.colorScheme) private var colorScheme

    private var mode: ThemeMode {
        Themes.theme(named: store.themeName).mode(for: colorScheme)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tab(id: DashboardStore.overviewTab, label: "Overview", index: 0) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                let clients = store.dashboardClients
                ForEach(Array(clients.enumerated()), id: \.element) { i, id in
                    let style = ClientRegistry.style(for: id)
                    tab(id: id, label: style.shortName, index: i + 1) {
                        ClientIconView(style: style, size: 15)
                    }
                }
            }
        }
    }

    private func tab(
        id: String, label: String, index: Int,
        @ViewBuilder mark: () -> some View
    ) -> some View {
        let isActive = store.activeTab == id
        return Button {
            store.activeTab = id
        } label: {
            HStack(spacing: 6) {
                mark()
                Text(label)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? mode.chipColor : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isActive ? mode.chipBg : Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? mode.chipBorder : Color.primary.opacity(0.08),
                    lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .kbdPin("⌘\(index + 1)", visible: keys.cmdHeld && index < 9,
                offset: CGSize(width: -2, height: 2))
    }
}
