import Model
import SwiftUI

// Reports the dashboard's natural content height up to AppKit so the tray
// panel can size itself. Pushed by DashboardRootView, observed by the app
// target (which feeds it into TrayPanelController.setContentHeight).
public struct ContentHeightKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0

    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// The dashboard, ported from src/App.tsx: header, tabs, and the per-tab
// card stack, with the settings panel as an overlay inside the tray panel.
// Transparent background so the panel's vibrancy shows through.
public struct DashboardRootView: View {
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var liveTrace: LiveTraceStore
    @EnvironmentObject private var quotaStore: QuotaStore

    // Room the settings overlay needs when the dashboard itself is short
    // (e.g. still loading): card height + breathing space.
    private static let settingsMinHeight: CGFloat = 580

    public init() {}

    public var body: some View {
        ZStack {
            // The panel clamps to 1200pt; content taller than that scrolls.
            ScrollView(showsIndicators: false) {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ContentHeightKey.self,
                                value: max(
                                    proxy.size.height,
                                    store.isSettingsPresented
                                        ? Self.settingsMinHeight : 0)
                            )
                        }
                    )
                    // Tab switches (click, ⌘1-9, ⌘[/⌘]) and reopening the
                    // panel swap in content of a different natural height.
                    // The clip view keeps its old offset, which pushes the
                    // header out of view and leaves an empty band at the
                    // bottom. Match the web app — always land at the top.
                    .overlay(
                        ScrollTopAnchor(trigger: AnyHashable(store.activeTab))
                            .frame(width: 0, height: 0),
                        alignment: .top
                    )
            }

            if store.isSettingsPresented {
                SettingsSheet()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.isSettingsPresented)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        if let stats = store.overviewStats, store.payload != nil {
            VStack(alignment: .leading, spacing: 12) {
                HeaderBar()
                TabStrip()
                if store.activeTab == DashboardStore.overviewTab {
                    overviewStack(stats)
                } else if let activeStats = store.activeStats {
                    clientStack(store.activeTab, stats: activeStats)
                }
            }
        } else if store.isLoading {
            statusBox {
                ProgressView()
                    .controlSize(.small)
                Text("Collecting usage from local logs…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if let error = store.lastError {
            statusBox {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Error: \(error)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else {
            statusBox {
                Text("No usage data found yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var liveClientIds: Set<String> {
        TraceClients.liveClientIds(liveTrace.trace)
    }

    // Overview card order mirrors App.tsx:514-538: chart → limits → live
    // trace → streaks. Client tabs (App.tsx:539-563) have no trace card.
    private func overviewStack(_ stats: Stats) -> some View {
        VStack(spacing: 12) {
            UsageBarChart(
                title: "Token Usage",
                subtitle: "Stacked by agent",
                bars: store.overviewBars,
                clientIds: store.presentClients,
                stats: stats)
            AgentLimitsCard(
                clients: store.presentClients,
                agentUsage: store.visibleAgentUsage,
                liveClientIds: liveClientIds)
            UsageTraceCard(
                buckets: liveTrace.trace,
                windowSecs: LiveTraceStore.traceWindowSecs,
                detailed: store.settings.detailedTrace)
            StreaksCard(streaks: stats.streaks)
        }
    }

    private func clientStack(_ clientId: String, stats: Stats) -> some View {
        VStack(spacing: 12) {
            AgentLimitsCard(
                clients: [clientId],
                agentUsage: store.visibleAgentUsage,
                liveClientIds: liveClientIds,
                title: "\(ClientRegistry.style(for: clientId).displayName) limits",
                note: "Session / weekly / model limits",
                includeUnlistedAgents: false)
            UsageBarChart(
                title: "Token Usage",
                subtitle: "Local token history",
                bars: store.activeBars,
                clientIds: [clientId],
                stats: stats)
            StreaksCard(streaks: stats.streaks)
        }
    }

    private func statusBox(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 380)
    }
}
