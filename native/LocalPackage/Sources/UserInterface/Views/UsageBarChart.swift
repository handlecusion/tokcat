import Charts
import Model
import SwiftUI

// Port of UsageBarGraph2D.tsx (2D view): last-30-days stacked bars, one
// color per client, with a hover tooltip showing date / totals / per-client
// rows. Hover uses chartOverlay + onContinuousHover — .chartXSelection is
// macOS 14+ and this app targets 13.
struct UsageBarChart: View {
    let title: String
    let subtitle: String
    let bars: [DayBar]
    let clientIds: [String]
    let stats: Stats

    @EnvironmentObject private var store: DashboardStore
    @ObservedObject private var keys = CmdHeldObserver.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverIndex: Int?

    private static let chartHeight: CGFloat = 200

    private var is3D: Bool { store.usageView == "3d" }

    private var maxTokens: Int64 {
        max(1, bars.map(\.totalTokens).max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    CardHeading(text: title)
                    // 3D shows the whole year, not the last-30-days window.
                    Text(is3D ? "Full year" : subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                viewToggle
                legend
            }

            StatsRow(stats: stats)

            if is3D {
                ContributionGraph3D(
                    grid: ContributionGrid.buildGrid(
                        year: store.selectedYear,
                        perDayMap: stats.perDayMap),
                    graphLight: theme.graphLight,
                    graphDark: theme.graphDark,
                    accent: theme.mode(for: colorScheme).accent)
                    .frame(height: Self.chartHeight + 24)
            } else {
                chart
                    .frame(height: Self.chartHeight)

                HStack {
                    axisLabel(bars.first?.date)
                    Spacer()
                    axisLabel(bars.last?.date)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var theme: ThemePalette { Themes.theme(named: store.themeName) }

    // Port of the .bar2d-viewtoggle 2D/3D button pair: a bordered pill of two
    // flat buttons where the active one fills with the theme accent (the
    // native segmented picker can only tint system-blue). The ⌘G pin floats
    // fully above the short control, right-aligned (.kbd-pin-toggle).
    private var viewToggle: some View {
        HStack(spacing: 2) {
            segButton("2D", tag: "2d")
            segButton("3D", tag: "3d")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .kbdPin("⌘G", visible: keys.cmdHeld, offset: CGSize(width: 0, height: -21))
    }

    private func segButton(_ label: String, tag: String) -> some View {
        let isActive = store.usageView == tag
        return Button {
            store.usageView = tag
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive
                              ? theme.mode(for: colorScheme).accent
                              : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(clientIds.prefix(5), id: \.self) { id in
                let style = ClientRegistry.style(for: id)
                HStack(spacing: 4) {
                    Circle().fill(style.color).frame(width: 7, height: 7)
                    Text(style.shortName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func axisLabel(_ date: String?) -> some View {
        Text(date.map(Formatters.formatMonthDay) ?? "")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }

    private var chart: some View {
        Chart {
            ForEach(bars) { bar in
                ForEach(bar.segments) { segment in
                    BarMark(
                        x: .value("Day", bar.date),
                        y: .value("Tokens", segment.tokens),
                        width: .ratio(0.82)
                    )
                    .foregroundStyle(by: .value("Client", segment.clientId))
                    .cornerRadius(2)
                    .opacity(hoverIndex == nil || bars[hoverIndex!].date == bar.date
                             ? 0.86 : 0.45)
                }
            }
        }
        .chartXScale(domain: bars.map(\.date))
        .chartYScale(domain: 0...maxTokens)
        .chartForegroundStyleScale(
            domain: clientIds,
            range: clientIds.map { ClientRegistry.style(for: $0).color })
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame = geo[proxy.plotAreaFrame]
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverIndex = index(at: location.x - plotFrame.minX,
                                               plotWidth: plotFrame.width)
                        case .ended:
                            hoverIndex = nil
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let i = hoverIndex {
                            tooltip(for: bars[i], index: i, plotFrame: plotFrame)
                        }
                    }
            }
        }
    }

    private func index(at x: CGFloat, plotWidth: CGFloat) -> Int? {
        guard !bars.isEmpty, plotWidth > 0, x >= 0, x < plotWidth else { return nil }
        let i = Int(x / plotWidth * CGFloat(bars.count))
        guard bars.indices.contains(i) else { return nil }
        let bar = bars[i]
        // Like the React hit rects: only days with data get a tooltip.
        return (bar.totalTokens > 0 || bar.totalCost > 0) ? i : nil
    }

    @ViewBuilder
    private func tooltip(for bar: DayBar, index: Int, plotFrame: CGRect) -> some View {
        let step = plotFrame.width / CGFloat(max(1, bars.count))
        let centerX = plotFrame.minX + (CGFloat(index) + 0.5) * step
        let barTop = plotFrame.maxY
            - plotFrame.height * CGFloat(bar.totalTokens) / CGFloat(maxTokens)

        VStack(alignment: .leading, spacing: 5) {
            Text(Formatters.formatMonthDay(bar.date))
                .font(.system(size: 11, weight: .semibold))
            HStack(spacing: 8) {
                Text("\(NumberText.exactTokens(bar.totalTokens)) tokens")
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(Formatters.formatCost(bar.totalCost))
                    .fixedSize()
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Divider()
            ForEach(bar.segments) { segment in
                let style = ClientRegistry.style(for: segment.clientId)
                HStack(spacing: 5) {
                    Circle().fill(style.color).frame(width: 6, height: 6)
                    Text(style.shortName)
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 8)
                    Text("\(NumberText.exactTokens(segment.tokens)) · "
                         + Formatters.formatCost(segment.cost))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(8)
        .frame(width: 190)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        // Keep the tooltip inside the plot horizontally and above the bar.
        .position(
            x: min(max(centerX, plotFrame.minX + 95), plotFrame.maxX - 95),
            y: max(52, barTop - 60))
        .allowsHitTesting(false)
    }
}
