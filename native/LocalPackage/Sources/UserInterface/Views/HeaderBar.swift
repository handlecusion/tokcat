import Model
import SwiftUI

// Port of HeaderBar.tsx: "<N> tokens used in <year>" headline plus the
// theme picker, refresh button, and settings gear.
struct HeaderBar: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var spinAngle: Double = 0

    private var mode: ThemeMode {
        Themes.theme(named: store.themeName).mode(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Formatters.humanizeTokens(store.overviewStats?.totalTokens ?? 0))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(mode.accent)
                Text("tokens used in")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Picker("", selection: $store.selectedYear) {
                    ForEach(store.years, id: \.self) { year in
                        Text(year).tag(year)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }

            Spacer(minLength: 8)

            Picker("", selection: $store.themeName) {
                ForEach(Themes.all) { theme in
                    Text(theme.name).tag(theme.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(spinAngle))
            }
            .buttonStyle(.borderless)
            .help("Refresh")
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
        }
    }
}
