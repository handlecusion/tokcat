import Model
import SwiftUI

// Port of DashboardTabs.tsx: Overview plus one tab per client present in
// the payload. Client marks are the drawn brand glyphs (ClientIconView),
// falling back to the colored initial disc.
struct TabStrip: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.colorScheme) private var colorScheme

    private var mode: ThemeMode {
        Themes.theme(named: store.themeName).mode(for: colorScheme)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tab(id: DashboardStore.overviewTab, label: "Overview") {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.presentClients, id: \.self) { id in
                    let style = ClientRegistry.style(for: id)
                    tab(id: id, label: style.shortName) {
                        ClientIconView(style: style, size: 15)
                    }
                }
            }
        }
    }

    private func tab(
        id: String, label: String, @ViewBuilder mark: () -> some View
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
    }
}
